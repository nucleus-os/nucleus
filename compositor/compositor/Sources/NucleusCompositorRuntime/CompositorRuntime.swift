import NucleusCompositorLoop
import SystemPackage
import CSystem
import NucleusCompositorServer
import NucleusCompositorShell
import NucleusCompositorRenderRuntime
import NucleusCompositorRenderSession
import NucleusCompositorRendererLinux
import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowManager
import NucleusCompositorSignalC
import Tracy
import Glibc

// The compositor runtime root. `CompositorRuntime` owns the io_uring event loop
// (a Swift-owned `SystemPackage.IORing`), brings the compositor up (CompositorBringup.swift),
// and tears it down. It is the single composition root: bring-up, the loop, dispatch,
// and teardown are all Swift, calling the platform-fd owners (DRM session + render
// runtime in NucleusCompositorRenderRuntime, the input / xwm / router hosts in
// NucleusCompositorWaylandRuntime, the shell sd-bus in NucleusCompositorShell) by direct Swift call.
//
// The compositor runs on the process's main thread, the `@MainActor` executor, so
// the whole type is `@MainActor`: the loop body and every Swift service it owns
// run synchronously on the main actor with no per-call `assumeIsolated`.
// `nucleus_runtime_main` establishes that isolation once (see Runtime.swift).
//
// Ownership: Swift owns the ring and every platform-fd registration. Each fd uses
// an explicit one-shot poll, rearmed after its handler drains the source. This does
// not depend on IORING_CQE_F_MORE and bounds each source to one CQE per loop turn.
// The loop drains completions itself
// (error-preserving) and routes by token kind (`nucleus_loop_kind_of`, the
// NucleusCompositorLoop.h contract) to the owning Swift handler, inline. Frame
// pacing is the wait deadline: each turn the loop blocks up to the next frame
// boundary, and renders when it elapses.
@MainActor
final class CompositorRuntime {
    private static weak var active: CompositorRuntime?

    private static let loopKindShift: UInt64 = 56
    private static let instMask: UInt64 = (UInt64(1) << 56) - 1

    private var ring: IORing
    private let exitSignalFD: Int32
    private var exitRequested = false
    private var paused = false
    // Frame pacing is deadline-driven off each output's DisplayLink (vblank-phased predicted
    // present, corrected by real page-flip timestamps); `frameIntervalNs` is only the fallback
    // wait before any output exists. There is no free-running frame clock.

    /// The DRM session generation the primary-fd multishot poll is registered
    /// under; a device re-open bumps it, so the poll is cancelled + re-armed and
    /// stale completions (carrying the old generation in their token) are rejected
    /// by `nucleus_loop_handle_drm`.
    /// The cursor-image generation last uploaded to the hardware cursor planes; a bump
    /// in `CursorServer.generation` triggers a re-upload.
    private var lastCursorGeneration: UInt64 = 0

    private var drmGeneration: UInt64 = 0
    /// The xwayland ready/xwm fds currently polled (-1 = none); these appear after
    /// Xwayland spawns, so they are registered lazily once seen.
    private var polledReadyFd: Int32 = -1
    private var polledXwmFd: Int32 = -1
    private var loopTurns: UInt64 = 0
    private var idleWakeupWindowStartNs =
        CompositorRuntime.monotonicNowNs()
    private var idleWakeupsInWindow: UInt64 = 0

    /// Output fractional scale (from `NUCLEUS_SCALE`); the udev DRM-hotplug
    /// handler re-enumerates outputs at this scale.
    let outputScale: Double
    private(set) lazy var outputTopology = OutputTopologyReconciler(
        defaultScale: outputScale)

    init?() {
        let exitSignalFD = nucleus_compositor_create_exit_signal_fd()
        guard exitSignalFD >= 0 else { return nil }
        guard let ring = try? IORing(queueDepth: 256) else {
            close(exitSignalFD)
            return nil
        }
        self.ring = ring
        self.exitSignalFD = exitSignalFD
        if let raw = getenv("NUCLEUS_SCALE"), let value = Double(String(cString: raw)), value > 0 {
            self.outputScale = value
        } else {
            self.outputScale = 1.0
        }
        Self.active = self
    }

    deinit {
        close(exitSignalFD)
    }

    static func requestExit() {
        active?.exitRequested = true
    }

    static func sessionResume() -> Bool {
        guard let runtime = active else { return false }
        guard RenderRuntime.resumeSession(),
            runtime.outputTopology.reconcile(forceReattach: true)
        else {
            runtime.paused = true
            logRuntime("session: DRM recovery failed; remaining suspended")
            return false
        }
        for display in NucleusCompositorServer.shared.layout.displays {
            display.resumeRedraws()
        }
        runtime.paused = false
        return true
    }

    static func sessionPause() {
        guard let runtime = active else { return }
        runtime.paused = true
        for display in NucleusCompositorServer.shared.layout.displays {
            display.suspendRedraws()
        }
        if !RenderRuntime.pauseSession() {
            logRuntime("session: failed to retire DRM state cleanly")
        }
    }

    // ── Token encoding (shared with loop_tokens.token / NucleusCompositorLoop.h) ──
    private static func token(_ kind: NucleusLoopKind, _ inst: UInt64) -> UInt64 {
        (UInt64(kind.rawValue) << loopKindShift) | (inst & instMask)
    }

    @discardableResult
    private func registerPoll(_ kind: NucleusLoopKind, fd: Int32, inst: UInt64) -> Bool {
        guard fd >= 0 else { return false }
        let prepared = ring.prepare(request: .pollAdd(
            FileDescriptor(rawValue: fd),
            pollEvents: .pollIn,
            isMultiShot: false,
            context: Self.token(kind, inst)))
        if !prepared {
            logRuntime("ioring poll prepare failed kind=\(kind.rawValue) fd=\(fd)")
        }
        return prepared
    }

    /// Register every platform event source once. The fd values are owned by their
    /// Swift hosts; the loop borrows them for the poll. xwayland listen fds are
    /// keyed by fd (the handler reads the fd back out of the token).
    private func registerSources() {
        drmGeneration = DrmSession.generation
        registerPoll(NUCLEUS_LOOP_KIND_DRM, fd: DrmSession.fd, inst: drmGeneration)

        let abstractFd = nucleus_xwm_host_abstract_fd()
        registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN, fd: abstractFd, inst: instOf(abstractFd))
        let fsFd = nucleus_xwm_host_fs_fd()
        registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN, fd: fsFd, inst: instOf(fsFd))

        registerPoll(NUCLEUS_LOOP_KIND_SEAT, fd: nucleus_input_host_seat_fd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_INPUT, fd: nucleus_input_host_libinput_fd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_DBUS, fd: nucleus_shell_dbus_notification_fd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_APPEARANCE_PORTAL, fd: nucleus_shell_dbus_appearance_fd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_UDEV, fd: nucleus_input_host_drm_hotplug_fd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_WAYLAND_LOOP, fd: WaylandRuntime.eventLoopFd(), inst: 0)
        registerPoll(NUCLEUS_LOOP_KIND_EXIT_SIGNAL, fd: exitSignalFD, inst: 0)
        submit()
    }

    private func instOf(_ fd: Int32) -> UInt64 { UInt64(UInt32(bitPattern: fd)) }

    private func submit() {
        do { try ring.submitPreparedRequests() } catch {
            logRuntime("ioring submit failed: \(error)")
        }
    }

    // Drive the loop until exit. Returns when the compositor should exit, at which
    // point `nucleus_runtime_main` tears the context down.
    func run() {
        registerSources()
        Trace.setThreadName("Nucleus compositor main")

        while !exitRequested {
            loopTurns &+= 1
            Trace.plot("swift.runtime.loop.turn", loopTurns)
            let renderZone = Trace.beginZone("runtime.render_turn", color: Trace.Color.green)
            if !paused {
                let nowNs = Self.monotonicNowNs()
                let dueDisplays = NucleusCompositorServer.shared.layout.displays
                    .filter { display in
                        guard case .queued = display.redrawState else {
                            return false
                        }
                        return (display.displayLink.targetPresentNs()
                            ?? display.displayLink.predictedPresentNs(0)) <= nowNs
                    }
                let dueOutputIDs = Set(dueDisplays.map(\.id))
                for display in dueDisplays {
                    _ = display.beginRedraw(frameBuildID: loopTurns)
                    display.noteSceneAuthorPass()
                    if WaylandRuntime.authorSceneFrame(
                        outputId: display.id,
                        predictedPresentNs: display.displayLink.predictedPresentNs(0)) {
                        display.requestRedraw(.animation)
                    }
                }
                if !dueDisplays.isEmpty {
                    RenderRuntime.setLockComposition(
                        WaylandRuntime.sessionLockComposition())
                    RenderRuntime.setScanoutCandidates(scanoutCandidates())
                    let cursorModel = NucleusCompositorServer.shared.cursor
                    if cursorModel.generation != lastCursorGeneration {
                        lastCursorGeneration = cursorModel.generation
                        RenderRuntime.setCursorImage(
                            pixels: cursorModel.pixels,
                            width: cursorModel.width,
                            height: cursorModel.height,
                            hotspotX: cursorModel.hotSpotX,
                            hotspotY: cursorModel.hotSpotY)
                    }
                    let events = NucleusCompositorServer.shared.events
                    RenderRuntime.setCursorPosition(
                        x: events.cursorX, y: events.cursorY)
                    _ = RenderRuntime.renderOutputs(dueOutputIDs)
                    for display in dueDisplays {
                        display.redrawDidNotSubmit()
                    }
                }
            }
            renderZone.end()

            // Block up to the earliest per-output vblank deadline. A real event — a page-flip
            // completion, a client request, input — arrives on its fd and preempts this bound, so
            // it is a ceiling, not a fixed cadence.
            let timeout: Duration? = paused ? nil : earliestDeadlineTimeout()
            let waitZone = Trace.beginZone("runtime.ioring_wait", color: Trace.Color.blue)
            do {
                try ring.waitForCompletions(timeout: timeout)
            } catch {
                logRuntime("ioring wait failed: \(error)")
            }
            waitZone.end()

            let dispatchZone = Trace.beginZone("runtime.completion_drain", color: Trace.Color.yellow)
            var needsPollSubmit = false
            var completionCount: UInt64 = 0
            while let completion = ring.tryConsumeCompletion() {
                completionCount &+= 1
                if dispatch(completion) { needsPollSubmit = true }
            }
            if needsPollSubmit { submit() }
            dispatchZone.value(completionCount)
            dispatchZone.end()
            Trace.plot("swift.runtime.loop.completions", completionCount)
            recordIdleWakeupRate()

            maintainDrmGeneration()
            maintainXwayland()
            WaylandRuntime.idleTick(nowNs: Self.monotonicNowNs())

            // post-drain: always drain libseat — a VT-switch signal arrives as a
            // delivered EINTR with no CQE, and the io_uring wait returns on it —
            // then re-collect frame demand for the turn.
            nucleus_input_host_seat_dispatch()
            DisplayFrameDemand.sync()
        }
    }

    private func recordIdleWakeupRate() {
        let now = Self.monotonicNowNs()
        let displays =
            NucleusCompositorServer.shared.layout.displays
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
    /// operation deadline). `.zero` renders immediately when a deadline has already passed. Before any
    /// output is queued. Idle and in-flight outputs contribute no timeout.
    private func earliestDeadlineTimeout() -> Duration? {
        let now = Self.monotonicNowNs()
        var earliest: UInt64 = .max
        if let idleDeadline = WaylandRuntime.nextIdleDeadlineNs() {
            earliest = min(earliest, idleDeadline)
        }
        for display in NucleusCompositorServer.shared.layout.displays {
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
        if now >= earliest { return .zero }
        return .nanoseconds(Int(earliest &- now))
    }

    // Route one drained completion to its Swift owner. A cancelled poll's terminal
    // CQE (-ECANCELED, from a DRM device re-open) carries no owner work and is
    // dropped; the cancel op's own ack carries token 0 (no kind) → `default`.
    // On error (result < 0, non-cancel) the source is logged and skipped.
    /// Dispatch one one-shot poll completion, then stage its replacement poll when
    /// the source is still live. Returns true when a replacement was prepared.
    private func dispatch(_ completion: borrowing IORing.Completion) -> Bool {
        let token = completion.context
        let result = completion.result
        Trace.plot("swift.runtime.loop.last_completion_kind", UInt64(nucleus_loop_kind_of(token)))
        if result == -ECANCELED { return false }
        let ready = result >= 0
        func fail(_ name: String) { if !ready { logRuntime("\(name) completion failed: \(result)") } }

        switch nucleus_loop_kind_of(token) {
        case UInt8(NUCLEUS_LOOP_KIND_DRM.rawValue):
            // Reject a completion from a prior DRM session generation: the token's
            // instance is the generation it was registered under, so a device
            // re-open makes the old fd's in-flight completions stale.
            guard (token & Self.instMask) == DrmSession.generation else { return false }
            if ready { RenderRuntime.handleDrmEvents() } else { fail("drm") }
        case UInt8(NUCLEUS_LOOP_KIND_SEAT.rawValue):
            if ready { nucleus_input_host_seat_dispatch() } else { fail("seat") }
        case UInt8(NUCLEUS_LOOP_KIND_INPUT.rawValue):
            if ready { nucleus_input_host_drain_libinput() } else { fail("input") }
        case UInt8(NUCLEUS_LOOP_KIND_DBUS.rawValue):
            // Pump the notification bus, then re-collect frame demand (which
            // observes any bezel/notification frame request and arms the overlay).
            if ready { nucleus_shell_dbus_pump_notifications(); DisplayFrameDemand.sync() } else { fail("dbus") }
        case UInt8(NUCLEUS_LOOP_KIND_APPEARANCE_PORTAL.rawValue):
            if ready { nucleus_shell_dbus_pump_appearance(); DisplayFrameDemand.requestFrame() } else { fail("appearance_portal") }
        case UInt8(NUCLEUS_LOOP_KIND_UDEV.rawValue):
            // DRM connector hotplug: one root transaction reconciles renderer,
            // server, shell policy, and Wayland protocol ownership.
            if ready {
                if nucleus_input_host_drain_drm_hotplug() {
                    _ = outputTopology.reconcile()
                }
            } else {
                fail("udev")
            }
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN.rawValue):
            // The listen fd is the token instance; the xwm host accepts on it.
            if ready { _ = nucleus_xwm_host_display_readable(Int32(bitPattern: UInt32(truncatingIfNeeded: token & Self.instMask))) } else { fail("xwayland_listen") }
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_READY.rawValue):
            if ready { nucleus_xwm_host_ready_readable() } else { fail("xwayland_ready") }
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_XWM.rawValue):
            if ready { _ = nucleus_xwm_host_dispatch() } else { fail("xwayland_xwm") }
        case UInt8(NUCLEUS_LOOP_KIND_WAYLAND_LOOP.rawValue):
            if ready { WaylandRuntime.dispatch() } else { fail("wayland_loop") }
        case UInt8(NUCLEUS_LOOP_KIND_EXIT_SIGNAL.rawValue):
            if ready {
                _ = nucleus_compositor_consume_exit_signal(exitSignalFD)
                exitRequested = true
            } else {
                fail("exit_signal")
            }
        default: break
        }
        return ready && rearmPoll(for: token)
    }

    /// Rearm the source represented by `token` using its current live fd. Dynamic
    /// sources are validated against the token instance so a completion from a
    /// closed/replaced descriptor cannot register the stale integer again.
    private func rearmPoll(for token: UInt64) -> Bool {
        let kind = nucleus_loop_kind_of(token)
        let inst = token & Self.instMask
        switch kind {
        case UInt8(NUCLEUS_LOOP_KIND_DRM.rawValue):
            guard inst == DrmSession.generation else { return false }
            return registerPoll(NUCLEUS_LOOP_KIND_DRM, fd: DrmSession.fd, inst: inst)
        case UInt8(NUCLEUS_LOOP_KIND_SEAT.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_SEAT, fd: nucleus_input_host_seat_fd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_INPUT.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_INPUT, fd: nucleus_input_host_libinput_fd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_DBUS.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_DBUS, fd: nucleus_shell_dbus_notification_fd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_APPEARANCE_PORTAL.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_APPEARANCE_PORTAL, fd: nucleus_shell_dbus_appearance_fd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_UDEV.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_UDEV, fd: nucleus_input_host_drm_hotplug_fd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_WAYLAND_LOOP.rawValue):
            return registerPoll(NUCLEUS_LOOP_KIND_WAYLAND_LOOP, fd: WaylandRuntime.eventLoopFd(), inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_EXIT_SIGNAL.rawValue):
            guard !exitRequested else { return false }
            return registerPoll(NUCLEUS_LOOP_KIND_EXIT_SIGNAL, fd: exitSignalFD, inst: 0)
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN.rawValue):
            let fd = Int32(bitPattern: UInt32(truncatingIfNeeded: inst))
            return registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN, fd: fd, inst: inst)
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_READY.rawValue):
            let fd = nucleus_xwm_host_ready_fd()
            guard inst == instOf(fd) else { return false }
            return registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_READY, fd: fd, inst: inst)
        case UInt8(NUCLEUS_LOOP_KIND_XWAYLAND_XWM.rawValue):
            let fd = nucleus_xwm_host_xwm_fd()
            guard inst == instOf(fd) else { return false }
            return registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_XWM, fd: fd, inst: inst)
        default:
            return false
        }
    }

    /// On a DRM device re-open the session generation bumps: cancel the one-shot
    /// poll on the old (now-closed) primary fd and arm the new fd under a
    /// fresh generation-keyed token.
    private func maintainDrmGeneration() {
        let live = DrmSession.generation
        guard live != drmGeneration else { return }
        _ = ring.prepare(request: .cancel(.first, matchingContext: Self.token(NUCLEUS_LOOP_KIND_DRM, drmGeneration)))
        drmGeneration = live
        registerPoll(NUCLEUS_LOOP_KIND_DRM, fd: DrmSession.fd, inst: live)
        submit()
    }

    /// Xwayland's readiness pipe + XWM connection fds appear after it spawns;
    /// register each once it shows up (keyed by fd so the handler recovers it).
    private func maintainXwayland() {
        let readyFd = nucleus_xwm_host_ready_fd()
        if readyFd >= 0 && polledReadyFd != readyFd {
            registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_READY, fd: readyFd, inst: instOf(readyFd))
            submit()
            polledReadyFd = readyFd
        }
        let xwmFd = nucleus_xwm_host_xwm_fd()
        if xwmFd >= 0 {
            if polledXwmFd != xwmFd {
                registerPoll(NUCLEUS_LOOP_KIND_XWAYLAND_XWM, fd: xwmFd, inst: instOf(xwmFd))
                submit()
                polledXwmFd = xwmFd
            }
        } else {
            polledXwmFd = -1
        }
    }

    /// Build this frame's per-output direct-scanout candidates (M2) by combining the
    /// live window-model facts (`WaylandRuntime.scanoutFacts`) with each output's
    /// geometry from the display layout. An output with no fullscreen root gets a
    /// candidate with a nil surface (the evaluator blocks it); the whole map is empty
    /// until the router is activated.
    private func scanoutCandidates() -> [UInt64: ScanoutCandidate] {
        let facts = WaylandRuntime.scanoutFacts()
        guard !facts.isEmpty else { return [:] }
        // The native overlay (notifications / hotkey display) renders on the shell
        // output only; when it has content that output must composite over any
        // fullscreen client. The overlay scene lives in the shell module, reachable
        // here but not from the facts gather, so fold it in as the notification input.
        let overlayActive = nucleus_compositor_shell_overlay_active()
        var result: [UInt64: ScanoutCandidate] = [:]
        for display in NucleusCompositorServer.shared.layout.displays {
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
// `NucleusCompositorServer.shared.sessionControl`, installed at bring-up.
extension CompositorRuntime: CompositorSessionControl {
    func sessionResume() -> Bool { Self.sessionResume() }
    func sessionPause() { Self.sessionPause() }
    func requestExit() { Self.requestExit() }
}
