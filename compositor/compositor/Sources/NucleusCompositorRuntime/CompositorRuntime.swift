import NucleusCompositorServer
import NucleusCompositorShell
import NucleusCompositorRenderRuntime
import NucleusCompositorRenderSession
import NucleusCompositorRendererLinux
import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowScene
import NucleusCompositorWindowManager
import NucleusCompositorSignalC
import NucleusAppHostBundle
import NucleusRenderHost
import NucleusRenderModel
import NucleusLinuxDBus
import NucleusLinuxReactor
import NucleusLinuxSession
import Tracy
import Glibc

// The compositor runtime root. `CompositorRuntime` owns the awaitable Linux host
// reactor, brings the compositor up (CompositorBringup.swift),
// and tears it down. It is the single composition root: bring-up, the loop, dispatch,
// and teardown are all Swift, calling the platform-fd owners (DRM session + render
// runtime in NucleusCompositorRenderRuntime, the input / xwm / router hosts in
// NucleusCompositorWaylandRuntime, the shell sd-bus in NucleusCompositorShell) by direct Swift call.
//
// The runtime state stays main-actor isolated, while each wait suspends that actor.
// The shared reactor owns io_uring registration, cancellation, submission, stale
// completion rejection, and deadline/control eventfds. This type only describes
// live interests and routes readiness to the source that owns each descriptor.
@MainActor
final class CompositorRuntime {
    private static let loopKindShift: UInt64 = 56
    private static let instMask: UInt64 = (UInt64(1) << 56) - 1

    private enum LoopKind: UInt8 {
        case drm = 1
        case seat = 3
        case input = 4
        case udev = 9
        case xwaylandListen = 14
        case xwaylandReady = 15
        case xwaylandXwm = 16
        case appearancePortal = 18
        case waylandLoop = 21
        case exitSignal = 22
        case renderWake = 23
        case accessibility = 24
    }

    private let reactor: LinuxHostReactor
    private let exitSignalFD: Int32
    let drmSession = DrmSession()
    let renderWake: CompositorRenderWakeSink
    let resourceHost: SwiftResourceHost
    let retainedStore: RetainedTreeStore
    let hostBundle: NucleusAppHostBundle
    let windowSceneAuthor: WindowSceneAuthor
    let server: NucleusCompositorServer
    let windowManager: WindowManager
    let waylandRuntime: WaylandRuntime
    let renderRuntime: RenderRuntime
    let frameDemand: DisplayFrameDemand
    let shellServices: ShellServices
    var readinessReporter: SessionReadinessReporter?
    let configuration: SessionConfiguration
    private var exitRequested = false
    private var paused = false
    private var retirement = RendererRetirementCoordinator(
        retryDelayNanoseconds: 5_000_000,
        shutdownGraceNanoseconds: 1_000_000_000)
    var shutdownDisposition =
        RendererRetirementCoordinator.ShutdownDisposition.outputsDisabled
    // Frame pacing is deadline-driven off each output's DisplayLink (vblank-phased predicted
    // present, corrected by real page-flip timestamps); `frameIntervalNs` is only the fallback
    // wait before any output exists. There is no free-running frame clock.

    /// The cursor-image generation last uploaded to the hardware cursor planes; a bump
    /// in `CursorServer.generation` triggers a re-upload.
    private var lastCursorGeneration: UInt64 = 0

    private var loopTurns: UInt64 = 0
    private var idleWakeupWindowStartNs =
        CompositorRuntime.monotonicNowNs()
    private var idleWakeupsInWindow: UInt64 = 0

    /// Output fractional scale supplied by the immutable session configuration;
    /// the udev DRM-hotplug handler re-enumerates outputs at this scale.
    let outputScale: Double
    private(set) lazy var outputTopology = OutputTopologyReconciler(
        defaultScale: outputScale,
        server: server,
        windowManager: windowManager,
        renderRuntime: renderRuntime,
        frameDemand: frameDemand,
        waylandRuntime: waylandRuntime,
        overlayScene: shellServices.overlayScene)

    init?(
        configuration: SessionConfiguration = .defaults,
        readinessReporter: SessionReadinessReporter? = nil
    ) {
        let exitSignalFD = nucleus_compositor_create_exit_signal_fd()
        guard exitSignalFD >= 0 else { return nil }
        guard let reactor = try? LinuxHostReactor(queueDepth: 256) else {
            close(exitSignalFD)
            return nil
        }
        guard let renderWake = CompositorRenderWakeSink() else {
            close(exitSignalFD)
            return nil
        }
        self.reactor = reactor
        self.exitSignalFD = exitSignalFD
        self.renderWake = renderWake
        self.configuration = configuration
        self.readinessReporter = readinessReporter
        let resourceHost = SwiftResourceHost()
        self.resourceHost = resourceHost
        let retainedStore = RetainedTreeStore(resourceHost: resourceHost)
        let hostBundle = NucleusAppHostBundle(resourceHost: resourceHost)
        self.retainedStore = retainedStore
        self.hostBundle = hostBundle
        let server = NucleusCompositorServer()
        let windowManager = WindowManager(server: server)
        let waylandRuntime = WaylandRuntime(
            server: server,
            windowManager: windowManager,
            diagnostics: WaylandRuntimeDiagnostics(
                traceProtocolEffects: configuration.traceProtocol))
        let renderRuntime = RenderRuntime(server: server)
        let shellServices = ShellServices(
            server: server,
            windowManager: windowManager)
        let frameDemand = DisplayFrameDemand(
            server: server,
            renderRuntime: renderRuntime,
            shellServices: shellServices)
        self.server = server
        self.windowManager = windowManager
        self.waylandRuntime = waylandRuntime
        self.renderRuntime = renderRuntime
        self.shellServices = shellServices
        self.frameDemand = frameDemand
        self.windowSceneAuthor = WindowSceneAuthor {
            RenderCommitSink(
                store: retainedStore,
                resourceHost: resourceHost,
                runtimeHost: hostBundle.layersHost,
                requestFrame: { frameDemand.requestFrame() })
        }
        self.outputScale = configuration.outputScale
    }

    func makeRenderCommitSink() -> RenderCommitSink {
        RenderCommitSink(
            store: retainedStore,
            resourceHost: resourceHost,
            runtimeHost: hostBundle.layersHost,
            requestFrame: { [frameDemand] in frameDemand.requestFrame() })
    }

    deinit {
        close(exitSignalFD)
    }

    func requestExit() {
        exitRequested = true
        reactor.wake()
    }

    func reportCompositorReadyAfterPresentation() {
        guard let readinessReporter else { return }
        do {
            try readinessReporter.report(.compositorReady)
            self.readinessReporter = nil
            logRuntime(
                "session: compositor ready after first physical presentation")
        } catch {
            self.readinessReporter = nil
            logRuntime("session supervisor readiness failed: \(error)")
            requestExit()
        }
    }

    func stopReactor() async {
        await reactor.shutdown()
        renderWake.shutdown()
    }

    func sessionResume() -> Bool {
        let resumed = renderRuntime.resumeSession()
            && outputTopology.reconcile(forceReattach: true)
        retirement.noteResume(succeeded: resumed)
        guard resumed else {
            paused = true
            logRuntime("session: DRM recovery failed; remaining suspended")
            return false
        }
        for display in server.layout.displays {
            display.resumeRedraws()
        }
        paused = false
        return true
    }

    func sessionPause() -> Bool {
        paused = true
        outputTopology.cancelPendingReconcile()
        for display in server.layout.displays {
            display.suspendRedraws()
        }
        switch retirement.applyPauseResult(
            renderRuntime.pauseSession(),
            nowNanoseconds: Self.monotonicNowNs())
        {
        case .acknowledge(let cleanlyRetired):
            if !cleanlyRetired {
                logRuntime("session: failed to retire DRM state cleanly")
            }
            return true
        case .waiting:
            return false
        }
    }

    private func continuePendingSessionPause() {
        let now = Self.monotonicNowNs()
        guard retirement.pauseRetryIsDue(at: now) else { return }
        switch retirement.applyPauseResult(
            renderRuntime.pauseSession(), nowNanoseconds: now)
        {
        case .waiting:
            return
        case .acknowledge(let cleanlyRetired):
            if !cleanlyRetired {
                logRuntime("session: deferred DRM retirement failed")
            }
            waylandRuntime.completeSessionPause()
        }
    }

    private static func token(_ kind: LoopKind, _ inst: UInt64) -> UInt64 {
        (UInt64(kind.rawValue) << loopKindShift) | (inst & instMask)
    }

    private func instOf(_ fd: Int32) -> UInt64 { UInt64(UInt32(bitPattern: fd)) }

    private func appendInterest(
        _ kind: LoopKind,
        fileDescriptor: Int32,
        instance: UInt64 = 0,
        events: Int16 = Int16(POLLIN),
        mode: LinuxReactorPollMode = .oneShot,
        to interests: inout [LinuxReactorInterest]
    ) {
        guard fileDescriptor >= 0, events != 0 else { return }
        interests.append(LinuxReactorInterest(
            token: Self.token(kind, instance),
            fileDescriptor: fileDescriptor,
            events: events,
            mode: mode))
    }

    private func appendLinuxSource<Source: LinuxReactorSource>(
        _ kind: LoopKind,
        source: Source?,
        to interests: inout [LinuxReactorInterest]
    ) {
        guard let source else { return }
        appendInterest(
            kind,
            fileDescriptor: source.fileDescriptor,
            events: source.pollEvents,
            to: &interests)
    }

    /// Rebuild the desired descriptor set from live owners each turn. The
    /// reactor diffs this keyed snapshot, cancels replaced registrations, and
    /// rejects completions from their old kernel contexts.
    private func currentInterests() -> [LinuxReactorInterest] {
        var interests: [LinuxReactorInterest] = []
        interests.reserveCapacity(14)
        appendInterest(
            .drm,
            fileDescriptor: drmSession.fd,
            instance: drmSession.generation,
            mode: .multishot,
            to: &interests)
        let abstractFD = waylandRuntime.xwaylandAbstractFileDescriptor
        appendInterest(
            .xwaylandListen,
            fileDescriptor: abstractFD,
            instance: instOf(abstractFD),
            mode: .multishot,
            to: &interests)
        let fileSystemFD = waylandRuntime.xwaylandFilesystemFileDescriptor
        appendInterest(
            .xwaylandListen,
            fileDescriptor: fileSystemFD,
            instance: instOf(fileSystemFD),
            mode: .multishot,
            to: &interests)
        let readyFD = waylandRuntime.xwaylandReadyFileDescriptor
        appendInterest(
            .xwaylandReady,
            fileDescriptor: readyFD,
            instance: instOf(readyFD),
            to: &interests)
        let xwmFD = waylandRuntime.xwaylandWindowManagerFileDescriptor
        appendInterest(
            .xwaylandXwm,
            fileDescriptor: xwmFD,
            instance: instOf(xwmFD),
            to: &interests)
        appendInterest(
            .seat,
            fileDescriptor: waylandRuntime.seatFileDescriptor,
            mode: .multishot,
            to: &interests)
        appendInterest(
            .input,
            fileDescriptor: waylandRuntime.libinputFileDescriptor,
            mode: .multishot,
            to: &interests)
        appendLinuxSource(
            .appearancePortal,
            source: Optional(shellServices.environmentReactorSource),
            to: &interests)
        appendLinuxSource(
            .accessibility,
            source: shellServices.accessibilityReactorSource,
            to: &interests)
        appendInterest(
            .udev,
            fileDescriptor: waylandRuntime.drmHotplugFileDescriptor,
            mode: .multishot,
            to: &interests)
        appendInterest(
            .waylandLoop,
            fileDescriptor: waylandRuntime.eventLoopFd(),
            mode: .multishot,
            to: &interests)
        appendInterest(
            .exitSignal,
            fileDescriptor: exitSignalFD,
            mode: .multishot,
            to: &interests)
        appendInterest(
            .renderWake,
            fileDescriptor: renderWake.fileDescriptor,
            mode: .multishot,
            to: &interests)
        return interests
    }

    // Drive the loop until exit. Waiting suspends the main actor, allowing
    // process callbacks, UI tasks, and transfer continuations to run promptly.
    func run() async {
        Trace.setThreadName("Nucleus compositor main")

        runtimeLoop: while true {
            if retirement.pauseRetryIsDue(
                at: Self.monotonicNowNs())
            {
                continuePendingSessionPause()
            }
            if exitRequested {
                paused = true
                outputTopology.cancelPendingReconcile()
                let now = Self.monotonicNowNs()
                if !retirement.hasStartedShutdown {
                    for display in server.layout.displays {
                        display.suspendRedraws()
                    }
                }
                switch retirement.applyShutdownResult(
                    renderRuntime.prepareShutdown(),
                    nowNanoseconds: now)
                {
                case .readyToExit(let disposition):
                    shutdownDisposition = disposition
                    if disposition == .drmDeviceCloseRequired {
                        logRuntime(
                            "shutdown: atomic retirement did not complete; DRM device close will terminate kernel scanout ownership")
                    }
                    break runtimeLoop
                case .waiting:
                    // The normal DRM interest remains armed below. A completion
                    // or the next bounded loop turn retries the retained disable.
                    break
                }
            }
            loopTurns &+= 1
            Trace.plot("swift.runtime.loop.turn", loopTurns)
            let renderZone = Trace.beginZone("runtime.render_turn", color: Trace.Color.green)
            if !paused {
                let nowNs = Self.monotonicNowNs()
                let dueDisplays = server.layout.displays
                    .filter { display in
                        guard case .queued = display.redrawState else {
                            return false
                        }
                        return (display.displayLink.targetPresentNs()
                            ?? display.displayLink.predictedPresentNs(0)) <= nowNs
                    }
                let dueOutputIDs = Set(dueDisplays.map(\.id))
                if configuration.traceDrmDemand, !dueDisplays.isEmpty {
                    let demand = dueDisplays.map { display -> String in
                        if case .queued(let reasons) = display.redrawState {
                            return "\(display.id):0x\(String(reasons.rawValue, radix: 16))"
                        }
                        return "\(display.id):state-changed"
                    }.joined(separator: ",")
                    logRuntime("frame-demand: due=[\(demand)]")
                }
                for display in dueDisplays {
                    _ = display.beginRedraw(frameBuildID: loopTurns)
                    display.noteSceneAuthorPass()
                    if waylandRuntime.authorSceneFrame(
                        outputId: display.id,
                        predictedPresentNs: display.displayLink.predictedPresentNs(0)) {
                        display.requestRedraw(.animation)
                    }
                }
                if !dueDisplays.isEmpty {
                    renderRuntime.setLockComposition(
                        waylandRuntime.sessionLockComposition())
                    renderRuntime.setScanoutCandidates(scanoutCandidates())
                    let cursorModel = server.cursor
                    if cursorModel.generation != lastCursorGeneration {
                        lastCursorGeneration = cursorModel.generation
                        renderRuntime.setCursorImage(
                            pixels: cursorModel.pixels,
                            width: cursorModel.width,
                            height: cursorModel.height,
                            hotspotX: cursorModel.hotSpotX,
                            hotspotY: cursorModel.hotSpotY)
                    }
                    let events = server.events
                    renderRuntime.setCursorPosition(
                        x: events.cursorX, y: events.cursorY)
                    let submitted = renderRuntime.renderOutputs(dueOutputIDs)
                    if configuration.traceDrmDemand {
                        logRuntime(
                            "frame-demand: outputs=\(dueOutputIDs.sorted()) "
                                + "submitted=\(submitted)")
                    }
                    for display in dueDisplays {
                        display.redrawDidNotSubmit()
                    }
                }
            }
            renderZone.end()

            // Block up to the earliest per-output vblank deadline. A real event — a page-flip
            // completion, a client request, input — arrives on its fd and preempts this bound, so
            // it is a ceiling, not a fixed cadence.
            let timeout: UInt64?
            if exitRequested,
               let deadline = retirement.shutdownRetryDeadlineNanoseconds
            {
                let now = Self.monotonicNowNs()
                timeout = now >= deadline ? 0 : deadline - now
            } else if let retry = retirement.pauseRetryDeadlineNanoseconds
            {
                let now = Self.monotonicNowNs()
                timeout = now >= retry ? 0 : retry - now
            } else {
                timeout = paused ? nil : earliestDeadlineNanoseconds()
            }
            let waitZone = Trace.beginZone("runtime.ioring_wait", color: Trace.Color.blue)
            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(
                    interests: currentInterests(),
                    timeoutNanoseconds: timeout)
            } catch {
                logRuntime("host reactor failed: \(error)")
                exitRequested = true
                waitZone.end()
                break
            }
            waitZone.end()

            let dispatchZone = Trace.beginZone("runtime.completion_drain", color: Trace.Color.yellow)
            for event in batch.events {
                dispatch(event)
            }
            let completionCount = UInt64(batch.events.count)
            dispatchZone.value(completionCount)
            dispatchZone.end()
            Trace.plot("swift.runtime.loop.completions", completionCount)
            Trace.plot(
                "swift.runtime.loop.completion_budget_exhausted",
                UInt64(batch.didExhaustCompletionBudget ? 1 : 0))
            if let latency = batch.executorResumeLatencyNanoseconds {
                Trace.plot(
                    "swift.runtime.loop.main_actor_resume_ms",
                    Double(latency) / 1_000_000.0)
            }
            recordIdleWakeupRate()

            waylandRuntime.idleTick(nowNs: Self.monotonicNowNs())
            if let renderService =
                server.renderService
            {
                renderService.pollCaptureWork()
                if renderService.captureWorkStalled {
                    logRuntime(
                        "capture: GPU completion made no progress; shutting down renderer safely")
                    exitRequested = true
                }
            }
            waylandRuntime.flushClients()
            processDueLinuxReactorSources()

            // post-drain: always drain libseat — a VT-switch signal arrives as a
            // delivered EINTR with no CQE, and the io_uring wait returns on it —
            // then re-collect frame demand for the turn.
            waylandRuntime.dispatchSeat()
            frameDemand.sync()
        }
    }

    private func recordIdleWakeupRate() {
        let now = Self.monotonicNowNs()
        let displays =
            server.layout.displays
        if !displays.isEmpty,
            displays.allSatisfy({
                if case .idle = $0.redrawState {
                    return true
                }
                return false
            })
        {
            idleWakeupsInWindow &+= 1
        }
        let elapsed =
            now &- idleWakeupWindowStartNs
        guard elapsed >= 1_000_000_000 else {
            return
        }
        Trace.plot(
            "swift.runtime.idle_wakeups_per_second",
            Double(idleWakeupsInWindow)
                * 1_000_000_000.0
                / Double(elapsed))
        idleWakeupsInWindow = 0
        idleWakeupWindowStartNs = now
    }

    /// The wait ceiling until the next frame is due: the earliest predicted-present deadline across
    /// all outputs (each output's DisplayLink blends its vblank-phase prediction with any pending
    /// operation deadline). Zero renders immediately when a deadline has already passed. Before any
    /// output is queued. Idle and in-flight outputs contribute no timeout.
    private func earliestDeadlineNanoseconds() -> UInt64? {
        let now = Self.monotonicNowNs()
        var earliest: UInt64 = .max
        if let idleDeadline = waylandRuntime.nextIdleDeadlineNs() {
            earliest = min(earliest, idleDeadline)
        }
        if let captureDelay =
            server.renderService?.capturePollDelay
        {
            let capturePoll = now.addingReportingOverflow(captureDelay)
            earliest = min(
                earliest,
                capturePoll.overflow ? UInt64.max : capturePoll.partialValue)
        }
        addLinuxReactorDeadline(
            source: Optional(shellServices.environmentReactorSource),
            nowNanoseconds: now,
            earliest: &earliest)
        addLinuxReactorDeadline(
            source: shellServices.accessibilityReactorSource,
            nowNanoseconds: now,
            earliest: &earliest)
        for display in server.layout.displays {
            switch display.redrawState {
            case .queued:
                earliest = min(
                    earliest,
                    display.displayLink.targetPresentNs()
                        ?? display.displayLink.predictedPresentNs(0))
            case .deferredUntil(let deadline, _):
                earliest = min(earliest, deadline)
            case .idle, .rendering, .awaitingPresentation, .suspended:
                break
            }
        }
        guard earliest != .max else { return nil }
        if now >= earliest { return 0 }
        return earliest - now
    }

    private func dispatch(_ event: LinuxReactorEvent) {
        let token = event.token
        guard let kind = LoopKind(rawValue: UInt8(
            truncatingIfNeeded: token >> Self.loopKindShift))
        else { return }
        Trace.plot(
            "swift.runtime.loop.last_completion_kind",
            UInt64(kind.rawValue))

        if let failure = event.failureCode {
            descriptorFailure(kind: kind, result: failure)
            return
        }
        let result = LinuxPollResult(returnedEvents: event.returnedEvents)

        switch kind {
        case .drm:
            guard (token & Self.instMask) == drmSession.generation else {
                return
            }
            if result.isReadable {
                renderRuntime.handleDrmEvents()
                if !paused && !exitRequested {
                    _ = outputTopology.continuePendingReconcile()
                }
                continuePendingSessionPause()
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        case .seat:
            if result.isReadable {
                waylandRuntime.dispatchSeat()
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        case .input:
            if result.isReadable {
                waylandRuntime.drainLibinput()
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        case .appearancePortal:
            processLinuxSource(
                shellServices.environmentReactorSource,
                pollResult: result,
                failureOperation: "desktop settings portal descriptor closed")
        case .accessibility:
            processLinuxSource(
                shellServices.accessibilityReactorSource,
                pollResult: result,
                failureOperation: "accessibility bus descriptor closed")
        case .udev:
            if result.isReadable {
                if waylandRuntime.drainDrmHotplug(),
                   !paused, !exitRequested
                {
                    _ = outputTopology.reconcile()
                }
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        case .xwaylandListen:
            if result.isReadable {
                let descriptor = Int32(bitPattern: UInt32(
                    truncatingIfNeeded: token & Self.instMask))
                _ = waylandRuntime.xwaylandDisplayReadable(descriptor)
            } else if result.isTerminal {
                logRuntime("Xwayland listen descriptor closed")
            }
        case .xwaylandReady:
            if result.isReadable || result.isHungUp {
                waylandRuntime.xwaylandReadyReadable()
            } else if result.isTerminal {
                logRuntime("Xwayland readiness descriptor failed")
            }
        case .xwaylandXwm:
            if result.isReadable || result.isHungUp {
                _ = waylandRuntime.dispatchXwaylandWindowManager()
            } else if result.isTerminal {
                logRuntime("Xwayland window-manager descriptor failed")
            }
        case .waylandLoop:
            if result.isReadable {
                waylandRuntime.dispatch()
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        case .exitSignal:
            if result.isReadable || result.isTerminal {
                _ = nucleus_compositor_consume_exit_signal(exitSignalFD)
                exitRequested = true
            }
        case .renderWake:
            if result.isReadable {
                if renderWake.drain() {
                    frameDemand.requestFrame()
                }
            } else if result.isTerminal {
                descriptorFailure(kind: kind, result: event.result)
            }
        }
    }

    private func descriptorFailure(kind: LoopKind, result: Int32) {
        logRuntime(
            "required descriptor kind=\(kind.rawValue) failed: \(result)")
        exitRequested = true
    }

    private func addLinuxReactorDeadline<Source: LinuxReactorSource>(
        source: Source?,
        nowNanoseconds: UInt64,
        earliest: inout UInt64
    ) {
        guard let microseconds = source?.timeoutMicroseconds() else { return }
        let delta = microseconds.multipliedReportingOverflow(by: 1_000)
        guard !delta.overflow else { return }
        let addition = nowNanoseconds.addingReportingOverflow(
            delta.partialValue)
        earliest = min(
            earliest,
            addition.overflow ? UInt64.max : addition.partialValue)
    }

    private func processLinuxSource<Source: LinuxReactorSource>(
        _ source: Source?,
        pollResult: LinuxPollResult,
        failureOperation: String
    ) {
        guard let source else { return }
        if pollResult.isTerminal {
            source.transportDidFail(operation: failureOperation)
            return
        }
        if pollResult.returnedEvents != 0, source.process() {
            frameDemand.requestFrame()
        }
    }

    private func processDueLinuxSource<Source: LinuxReactorSource>(
        _ source: Source?
    ) {
        guard let source else { return }
        if source.timeoutMicroseconds() == 0, source.process() {
            frameDemand.requestFrame()
        }
    }

    private func processDueLinuxReactorSources() {
        processDueLinuxSource(shellServices.environmentReactorSource)
        processDueLinuxSource(shellServices.accessibilityReactorSource)
    }

    /// Build this frame's per-output direct-scanout candidates (M2) by combining the
    /// live window-model facts (`WaylandRuntime.scanoutFacts`) with each output's
    /// geometry from the display layout. An output with no fullscreen root gets a
    /// candidate with a nil surface (the evaluator blocks it); the whole map is empty
    /// until the router is activated.
    private func scanoutCandidates() -> [UInt64: ScanoutCandidate] {
        let facts = waylandRuntime.scanoutFacts()
        guard !facts.isEmpty else { return [:] }
        // The native overlay (notifications / hotkey display) renders on the shell
        // output only; when it has content that output must composite over any
        // fullscreen client. The overlay scene lives in the shell module, reachable
        // here but not from the facts gather, so fold it in as the notification input.
        let overlayActive = shellServices.shellPolicy.overlayActive()
        var result: [UInt64: ScanoutCandidate] = [:]
        for display in server.layout.displays {
            guard let f = facts[display.id] else { continue }
            let logical = display.logicalRect
            let pixels = display.pixelSize
            let root = f.fullscreenRoot
            let candidate = FullscreenCandidate(
                outputLogicalX: logical.x, outputLogicalY: logical.y,
                outputLogicalWidth: logical.width, outputLogicalHeight: logical.height,
                outputWidth: pixels.width, outputHeight: pixels.height,
                layoutX: root?.layoutX ?? 0, layoutY: root?.layoutY ?? 0,
                layoutWidth: root?.layoutWidth ?? 0, layoutHeight: root?.layoutHeight ?? 0,
                animatedX: root?.animatedX ?? 0, animatedY: root?.animatedY ?? 0)
            let inputs = ScanoutInputs(
                sessionLocked: f.sessionLocked,
                screenshotCaptureActive: f.screenshotCaptureActive,
                notificationCount: overlayActive ? 1 : 0,
                hotkeyHasContent: f.hotkeyHasContent,
                layerShellActiveOnOutput: f.layerShellActiveOnOutput,
                toplevelAnimationActiveOnOutput: f.toplevelAnimationActiveOnOutput,
                isShellOutput: f.isShellOutput)
            let surface: ScanoutSurfaceInfo? = root.map { r in
                ScanoutSurfaceInfo(
                    hasViewportTransform: r.hasViewportTransform,
                    currentWidth: r.currentWidth, currentHeight: r.currentHeight,
                    dmabuf: r.dmabuf.map {
                        ScanoutDmabufInfo(format: $0.format, modifier: $0.modifier,
                                          width: $0.width, height: $0.height)
                    })
            }
            result[display.id] = ScanoutCandidate(
                inputs: inputs, candidate: candidate, surface: surface,
                rootIOSurfaceID: root?.rootIOSurfaceID ?? 0)
        }
        return result
    }

    private static func monotonicNowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }
}

func logRuntime(_ message: String) {
    let bytes = Array(("compositor-runtime: " + message + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}

// The composition root's conformer to the inverted session-control seam. The input
// host (`.nucleus_compositor_substrate`) drives VT resume/pause + exit through
// the server's `sessionControl`, installed at bring-up.
extension CompositorRuntime: CompositorSessionControl {
}
