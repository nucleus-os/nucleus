import Glibc
import NucleusLinuxReactor
import NucleusShellLoop

@MainActor
extension ShellHost {
    func animationFrameRequested() {
        animationDemand = true
        requestRender(nativeSceneChanged: true)
        renderWake.signalRenderWork()
    }

    func requestRender(nativeSceneChanged: Bool = false) {
        renderWorkDue = true
        if nativeSceneChanged { nativeSceneDirty = true }
    }

    func loop() async {
        let displayFileDescriptor = client.fd
        var displayNeedsWrite = false
        var counters = ShellLoopCounters()

        while running {
            guard let preparation = client.prepareRead() else {
                writeErr("nucleus-shell: Wayland read preparation failed")
                break
            }
            if preparation.dispatchedEventCount > 0 {
                requestRender(nativeSceneChanged: true)
            }
            guard flushDisplay(needsWrite: &displayNeedsWrite) else {
                preparation.read.cancel()
                break
            }
            let waitPlan = makeReactorWaitPlan(
                displayFileDescriptor: displayFileDescriptor,
                displayNeedsWrite: displayNeedsWrite,
                nowNanoseconds: monotonicNowNs())

            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(
                    interests: waitPlan.interests,
                    timeoutNanoseconds: waitPlan.timeoutNanoseconds)
            } catch {
                preparation.read.cancel()
                writeErr("nucleus-shell: host reactor failed: \(error)")
                break
            }
            counters.record(batch)

            let outcome = dispatchReactorBatch(
                batch,
                preparedDisplayRead: preparation.read,
                nowNanoseconds: monotonicNowNs())
            if outcome.shouldStop { break }

            _ = processUnsignaledReactorSources(after: outcome)
            serviceExpiredTransfers()
            advanceInputDeadlines()
            refreshClock(nowNanoseconds: monotonicNowNs())
            renderFrameIfDue(counters: &counters)
        }
        await shutdown()
    }

    func flushDisplay(needsWrite: inout Bool) -> Bool {
        let result = client.flush()
        let disposition = ShellFlushDisposition.classify(
            result: result,
            error: errno)
        switch disposition {
        case .flushed:
            needsWrite = false
            return true
        case .needsWrite:
            needsWrite = true
            return true
        case .disconnected(let error):
            writeErr(
                "nucleus-shell: Wayland flush failed: "
                    + String(cString: strerror(error)))
            return false
        }
    }

    func serviceExpiredTransfers() {
        let nowNanoseconds = monotonicNowNs()
        pasteboardAdapter?.expireTransfers(nowNanoseconds: nowNanoseconds)
        dragDropAdapter?.expireTransfers(nowNanoseconds: nowNanoseconds)
    }

    func advanceInputDeadlines() {
        let nowNanoseconds = monotonicNowNs()
        if inputRouter?.nanosecondsUntilNextRepeat(nowNs: nowNanoseconds) == 0 {
            inputRouter?.advanceKeyRepeat(nowNs: nowNanoseconds)
            requestRender(nativeSceneChanged: true)
        }
        if inputScene?.nanosecondsUntilToolTip(
            atNanoseconds: nowNanoseconds) == 0
        {
            inputScene?.updateToolTip(atNanoseconds: nowNanoseconds)
            requestRender(nativeSceneChanged: true)
        }
    }

    func renderFrameIfDue(counters: inout ShellLoopCounters) {
        let nowNanoseconds = monotonicNowNs()
        if renderWorkDue, nextPresentationDeadlineNs == nil {
            nextPresentationDeadlineNs = nowNanoseconds
        }
        guard let scheduledDeadline = nextPresentationDeadlineNs,
              ShellFrameDecision.shouldRender(
                workPending: renderWorkDue,
                deadline: scheduledDeadline,
                now: nowNanoseconds)
        else {
            counters.recordIdleWake()
            return
        }

        renderWorkDue = false
        let interval = engine.presentationIntervalNanoseconds
        let predictedPresentationNanoseconds = clampedAdd(
            nowNanoseconds,
            interval)

        if animationDemand {
            animationDemand = false
            let remainsActive = nativePublicationContext?
                .semanticContext
                .advanceAnimations(
                    predictedPresentationNanoseconds:
                        predictedPresentationNanoseconds)
                ?? false
            animationDemand = remainsActive
            nativeSceneDirty = true
            if remainsActive { renderWorkDue = true }
        }

        if nativeSceneDirty {
            nativeSceneDirty = false
            do {
                let published = try inputScene?.publish()
                if let published {
                    surfaceRegistry?.updatePublishedScene(published)
                }
                _ = accessibilityBridge?.publish()
                if startupFrameDiagnosticsRemaining > 0 {
                    writeErr(
                        "nucleus-shell: scene published windows="
                            + "\(inputScene?.windows.count ?? 0) "
                            + "roots=\(published?.visualContent.count ?? 0)")
                }
            } catch {
                writeErr(
                    "nucleus-shell: native scene publication failed: \(error)")
            }
        }

        let postedOutputIDs = engine.renderFrame(
            presentTimeNs: predictedPresentationNanoseconds)
        noteStartupPresentations(postedOutputIDs)
        if startupFrameDiagnosticsRemaining > 0 {
            startupFrameDiagnosticsRemaining -= 1
            writeErr(
                "nucleus-shell: render turn posted_outputs="
                    + "\(postedOutputIDs.sorted()) "
                    + "interval_ns=\(interval)")
        }
        counters.recordRenderedFrame()
        nextPresentationDeadlineNs = ShellPresentationTiming.nextDeadline(
            previous: scheduledDeadline,
            now: nowNanoseconds,
            interval: interval)
    }

    private func noteStartupPresentations(
        _ postedOutputIDs: Set<UInt64>
    ) {
        guard readinessReporter != nil, !postedOutputIDs.isEmpty,
              let surfaceRegistry
        else { return }

        let liveOutputIDs = Set(client.outputs.keys)
        let wallpapers = wallpaperSurfaces.values.map { record in
            ShellStartupSurface(
                outputID: record.outputID,
                surfaceID: UInt64(record.surfaceID),
                renderOutputID: surfaceRegistry.renderOutputID(
                    for: record.surfaceID),
                contentReady: record.product.imageView.image.map {
                    engine.imageResidency(for: $0.id) == .resident
                } ?? false)
        }
        let bars = barSurfaces.values.map { record in
            ShellStartupSurface(
                outputID: record.outputID,
                surfaceID: UInt64(record.surfaceID),
                renderOutputID: surfaceRegistry.renderOutputID(
                    for: record.surfaceID),
                contentReady: true)
        }
        guard startupReadiness.observe(
            postedRenderOutputIDs: postedOutputIDs,
            liveOutputIDs: liveOutputIDs,
            wallpapers: wallpapers,
            bars: bars),
              let reporter = readinessReporter
        else { return }

        do {
            try reporter.report(.shellReady)
            readinessReporter = nil
            writeErr(
                "nucleus-shell: rendered shell ready outputs="
                    + "\(liveOutputIDs.count)")
        } catch {
            writeErr(
                "nucleus-shell: session supervisor readiness failed: \(error)")
            readinessReporter = nil
            running = false
        }
    }

    func writeErr(_ message: String) {
        let message = message + "\n"
        _ = message.withCString { write(2, $0, strlen($0)) }
    }
}
