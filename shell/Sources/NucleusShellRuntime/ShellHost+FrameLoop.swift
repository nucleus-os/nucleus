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
            guard flushDisplay(needsWrite: &displayNeedsWrite) else { break }
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
                writeErr("nucleus-shell: host reactor failed: \(error)")
                break
            }
            counters.record(batch)

            let outcome = dispatchReactorBatch(
                batch,
                nowNanoseconds: monotonicNowNs())
            if outcome.shouldStop { break }

            let hadHostEvent = processUnsignaledReactorSources(after: outcome)
            serviceExpiredTransfers()
            advanceInputDeadlines()
            guard drainHostWork(if: hadHostEvent) else { break }
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

    func drainHostWork(if hadHostEvent: Bool) -> Bool {
        guard hadHostEvent else { return true }
        if let host = rnHost {
            do {
                if try host.drainPendingJSCalls() > 0 {
                    requestRender()
                }
            } catch {
                writeErr("nucleus-shell: failed to drain JS runtime: \(error)")
                return false
            }
        }

        let commands = commandInbox.drain()
        for (command, argumentsJSON) in commands {
            applyCommand(command, argumentsJSON)
        }
        if !commands.isEmpty { requestRender() }
        return true
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
                _ = try inputScene?.publish()
                _ = accessibilityBridge?.publish()
            } catch {
                writeErr(
                    "nucleus-shell: native scene publication failed: \(error)")
            }
        }

        _ = engine.renderFrame(
            presentTimeNs: predictedPresentationNanoseconds)
        counters.recordRenderedFrame()
        nextPresentationDeadlineNs = ShellPresentationTiming.nextDeadline(
            previous: scheduledDeadline,
            now: nowNanoseconds,
            interval: interval)
    }

    func writeErr(_ message: String) {
        let message = message + "\n"
        _ = message.withCString { write(2, $0, strlen($0)) }
    }
}
