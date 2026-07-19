@_spi(NucleusCompositor) import NucleusReactRuntime
import NucleusUI
import NucleusUIEmbedder
import NucleusLayers
import NucleusRenderModel
import NucleusRenderHost
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellInput
import NucleusShellAuth
import NucleusShellDBus
import NucleusShellServices
import NucleusShellProduct
import NucleusShellRender
import NucleusShellSignalC
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

// The shell composition root. Wires the whole out-of-process pipeline:
//
//   Wayland client  ──connect──▶ compositor
//        │ binds layer-shell, foreign-toplevel, …
//        ▼
//   LayerSurface (the bar)  ──configure(size)──▶  ShellRenderEngine
//        │                                              │ VK_KHR_wayland_surface swapchain
//        ▼                                              ▼
//   NucleusReactRuntime.Host  ──attachSurface──▶  root render context (RenderCommitSink)
//        │ evaluates bar.hbc, runs "bar"                │ commits → RetainedTreeStore.shared
//        ▼                                              ▼
//   React <Bar/>  ──layer tree──────────────────▶  RenderCore.renderReady  ──present──▶ wl_surface
//
// The RN runtime boot reuses the same NucleusReactRuntime.Host facade the (now-deleted)
// compositor overlay used — the difference is only WHERE the surface attaches: a shell-owned
// root layer feeding this process's RenderCore, not the compositor's overlay scene.
@MainActor
public final class ShellHost {
    private let client: ShellWaylandClient
    private let engine: ShellRenderEngine
    private let bundleURL: String

    private var rnHost: NucleusReactRuntime.Host?
    fileprivate var barSurface: LayerSurface?
    private var barOutputID: UInt64?
    private var barSurfaceID: Int?

    // The root render context the RN surface attaches into. Its commit sink lowers the RN
    // layer tree into RetainedTreeStore.shared, which the render engine's RenderCore reads.
    // The bar's root View is what the RN surface mounts into (attachSurface); its backing
    // layer tree commits through the context's sink.
    private var renderContext: Context?
    private var barRootView: View?

    /// The seat and the scene its input is routed into.
    ///
    /// Constructed here so input exists for the whole process lifetime, but no
    /// window is registered by default: the bar is a React Native surface with
    /// its own touch handling, so routing NucleusUI events into it would mean two
    /// input paths over one tree. A native surface owner calls
    /// `inputRouter.register(window:forSurface:)` to opt in.
    private var seat: ShellSeat?
    public private(set) var inputScene: WindowScene?
    public private(set) var inputRouter: ShellInputRouter?

    /// Session lock. Nothing here locks on its own — no idle timer, no lid
    /// switch — and `lock()` refuses without an authenticator, because the
    /// compositor is deliberately fail-closed and a lock the shell cannot
    /// release would strand the session.
    public private(set) var lockController: ShellLockController?
    private var authenticator: PamAuthenticator?

    /// The system bus and the services on it. Opened lazily: a session with no
    /// bus is unusual but not fatal, and the shell renders either way.
    private var systemBus: DBusConnection?
    public private(set) var upower: UPowerService?
    /// Bar items driven by services. Held here because the runtime is what
    /// composes a service with a view — neither knows about the other.
    public let batteryWidget = BatteryWidget()

    fileprivate var toplevels: ForeignToplevelManager?
    private var running = false
    private let exitSignalFD: Int32

    /// JS→native taskbar commands, pushed on the JS thread and drained on the main actor.
    private let commandInbox = CommandInbox()

    /// Bar height in logical px (reserved as work area via the layer-shell exclusive zone).
    public var barHeight: UInt32 = 28

    public init?(bundleURL: String, socketName: String? = nil) {
        // Block process-exit signals before Vulkan/Wayland initialization can
        // create worker threads; they inherit the mask and signalfd remains the
        // sole delivery path.
        let exitSignalFD = nucleus_shell_create_exit_signal_fd()
        guard exitSignalFD >= 0 else { return nil }
        var closeLocalSignalFD = true
        defer { if closeLocalSignalFD { close(exitSignalFD) } }
        guard let client = ShellWaylandClient(socketName: socketName) else { return nil }
        guard let engine = ShellRenderEngine(display: client.display) else { return nil }
        self.exitSignalFD = exitSignalFD
        self.client = client
        self.engine = engine
        self.bundleURL = bundleURL
        closeLocalSignalFD = false
    }

    deinit {
        close(exitSignalFD)
    }

    /// Bring the shell up: install the host bundle, register native modules, create the bar
    /// surface, boot RN, and start the frame loop. Blocks in the loop until the compositor
    /// disconnects or a signal requests exit.
    public func run() {
        // 1. Swift resource/runtime host conformers — so the RN surface's paint/image/context
        //    registrations resolve into this process's retained tree.
        _ = nucleus_app_host_bundle_install_production()

        // 2. The root render context the RN surface commits into (→ RetainedTreeStore.shared).
        setupRenderContext()

        // 3. The foreign-toplevel window model. Its snapshots flow to JS (native→JS) through
        //    the facade's emitDeviceEvent — no custom native module. (JS→native taskbar actions
        //    await the facade host-command seam; see pushWindowsToJS.)
        setupForeignToplevel()

        // 4. The seat: pointer and keyboard, translated into framework events.
        setupInput()

        // 5. System services. Each maps a bus peer onto a value type and hands
        //    it to a view; this is the only place the two meet.
        setupServices()

        // 6. The bar layer-shell surface. Its first configure builds the swapchain + boots RN.
        createBarSurface()

        // 7. The event loop: wl_display fd + a frame timer.
        running = true
        loop()
    }

    // MARK: - Render context

    private func setupRenderContext() {
        // The RN layer tree flows: Context.commitSink → RenderCommitSink → RetainedTreeStore.shared.
        // RenderCommitSink defaults resourceHostHandle to the production host installed above.
        do {
            let context = try Context(commitSink: RenderCommitSink(store: .shared))
            // Make it the current context for the shell's lifetime, so Views (the bar root)
            // mint their backing layers into it and commit through its sink.
            EmbedderApplication.pushContext(context)
            renderContext = context
        } catch {
            writeErr("shell: failed to build render context: \(error)")
        }
    }

    // MARK: - Input

    private func setupInput() {
        let scene = WindowScene(windows: [])
        let seat = ShellSeat(client: client)
        if seat == nil {
            // A seatless session (no input devices) is legitimate; the shell
            // still renders.
            writeErr("shell: no wl_seat available; running without input")
        }
        inputScene = scene
        self.seat = seat
        // Where the two cursor vocabularies meet. NucleusUI decides *which*
        // cursor from the tracking areas under the pointer; the seat asks the
        // compositor for it. Neither layer knows the other's spelling.
        scene.onCursorChange = { [weak seat] cursor in
            seat?.setCursor(ShellHost.cursorShape(for: cursor))
        }
        let router = ShellInputRouter(scene: scene, seat: seat)
        inputRouter = router
        // PAM runs in a helper process, never in this address space: a module
        // that crashes or calls `exit()` would otherwise take the locker with it,
        // and a dead locker leaves the session blank and locked for good.
        let authenticator = PamAuthenticator()
        self.authenticator = authenticator
        let controller = ShellLockController(
            client: client, engine: engine, scene: scene, inputRouter: router)
        controller.authenticator = authenticator
        lockController = controller
    }

    /// NucleusUI's cursor vocabulary onto the protocol's.
    ///
    /// Total rather than optional: every `Cursor` NucleusUI can resolve has a
    /// `wp_cursor_shape_device_v1` counterpart, so there is no "unmappable"
    /// case to decide a fallback for.
    static func cursorShape(for cursor: Cursor) -> ShellCursorShape {
        switch cursor {
        case .arrow: return .default_
        case .pointingHand: return .pointer
        case .text: return .text
        case .crosshair: return .crosshair
        case .notAllowed: return .notAllowed
        case .grab: return .grab
        case .grabbing: return .grabbing
        case .resizeLeftRight: return .ewResize
        case .resizeUpDown: return .nsResize
        case .resizeNorthWestSouthEast: return .nwseResize
        case .resizeNorthEastSouthWest: return .neswResize
        case .wait: return .wait
        case .help: return .help
        }
    }

    // MARK: - Services

    private func setupServices() {
        guard let bus = try? DBusConnection(.system) else {
            writeErr("shell: no system bus; running without system services")
            return
        }
        systemBus = bus

        let upower = UPowerService(connection: bus)
        upower.onChange = { [weak self] reading in
            self?.batteryWidget.update(BatteryLevel(
                fraction: reading.percentage / 100,
                isCharging: reading.state.isPluggedIn,
                isPresent: reading.isPresent,
                secondsRemaining: reading.secondsRemaining))
        }
        do {
            try upower.start()
        } catch {
            writeErr("shell: UPower unavailable: \(error)")
        }
        self.upower = upower
    }

    // MARK: - Bar surface

    private func createBarSurface() {
        let config = LayerSurfaceConfig.topBar(height: barHeight)
        // Anchor to the first output (compositor picks if nil).
        let output = client.outputs.values.first
        guard let surface = LayerSurface(client: client, config: config, output: output) else {
            writeErr("shell: failed to create bar layer surface")
            return
        }
        surface.onConfigure = { [weak self] w, h in
            self?.onBarConfigured(width: Int32(w == 0 ? 1920 : w), height: Int32(h))
        }
        surface.onClosed = { [weak self] in self?.running = false }
        barSurface = surface
        client.flush()
    }

    private func onBarConfigured(width: Int32, height: Int32) {
        let scale = Double(client.outputs.values.first?.scale ?? 1)
        guard let surface = barSurface else { return }

        // Popovers place themselves inside the display, so the scene needs the
        // output's logical size. The bar's own configure is the first point at
        // which it is known; a popover opened before this would resolve inside a
        // zero rect.
        if let output = client.outputs.values.first, output.logicalWidth > 0 {
            inputScene?.displayBounds = Rect(
                x: 0, y: 0,
                width: Double(output.logicalWidth),
                height: Double(output.logicalHeight))
        }
        if let id = barOutputID {
            engine.resizeSurface(id, width: width, height: height, scale: scale)
        } else if let id = engine.addSurface(waylandSurface: surface.wlSurface,
                                              width: width, height: height, scale: scale) {
            barOutputID = id
            bootReactBar(width: Double(width) / scale, height: Double(height) / scale, scale: scale)
        }
    }

    // MARK: - React boot (the NucleusReactRuntime.Host facade)

    private func bootReactBar(width: Double, height: Double, scale: Double) {
        guard renderContext != nil else { return }
        do {
            // The bar's root View (minted into the pushed render context); the RN surface
            // mounts into it, and its backing-layer tree commits through the context's sink.
            let rootView = View()
            let host = try NucleusReactRuntime.Host()
            try host.installFabricRuntime()
            let surfaceID = 1
            try host.registerSurface(id: surfaceID)
            try host.configureSurface(id: surfaceID, width: width, height: height)
            try host.setDisplayMetrics(width: width, height: height, scale: scale, fontScale: 1.0)
            try host.evaluateBundle(at: bundleURL)
            try host.runApplication(surfaceID: surfaceID, appKey: "bar")
            _ = try host.attachSurface(
                rootView: rootView, surfaceID: surfaceID,
                backingScaleFactor: BackingScaleFactor(Float(scale)), at: 0)
            // JS→native taskbar actions: NucleusHostCommand.invoke(command, argsJson) fires
            // on the JS thread → push onto the thread-safe inbox the frame loop drains onto
            // the main actor (the Wayland client is single-threaded / @MainActor).
            let inbox = commandInbox
            try host.setCommandHandler { command, argsJson in inbox.push(command, argsJson) }
            rnHost = host
            barRootView = rootView
            barSurfaceID = surfaceID
        } catch {
            writeErr("shell: RN boot failed: \(error)")
        }
    }

    // MARK: - Foreign-toplevel → taskbar

    private func setupForeignToplevel() {
        guard let manager = ForeignToplevelManager(client: client) else { return }
        manager.onChanged = { [weak self] in self?.pushWindowsToJS() }
        toplevels = manager
    }

    private func pushWindowsToJS() {
        guard let windows = toplevels?.windows, let host = rnHost else { return }
        // Serialize the window snapshot and push it to JS via the facade (native→JS). The bar's
        // taskbar subscribes with DeviceEventEmitter.addListener("nucleusShellWindows", …).
        let snapshot: [[String: Any]] = windows.map { window in
            [
                // A 64-bit handle exceeds JS's precise integer range.
                "id": String(window.id),
                "title": window.title,
                "appId": window.appID,
                "activated": window.activated,
                "minimized": window.minimized,
            ]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            guard let json = String(data: data, encoding: .utf8) else {
                writeErr("nucleus-shell: window snapshot was not UTF-8")
                return
            }
            try host.emitDeviceEvent(name: "nucleusShellWindows", payloadJson: json)
        } catch {
            writeErr("nucleus-shell: failed to publish window snapshot: \(error)")
        }
    }

    /// Route a JS→native taskbar command (drained from the inbox on the main actor) to the
    /// foreign-toplevel client. `argsJson` is `{"id": <n|"n">, …}`; ids may be strings to
    /// survive JS's 2^53 number precision (a toplevel id is a 64-bit handle).
    private func applyCommand(_ command: String, _ argsJson: String) {
        guard let data = argsJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let id: UInt64
        if let n = obj["id"] as? NSNumber { id = n.uint64Value }
        else if let s = obj["id"] as? String, let v = UInt64(s) { id = v }
        else { return }
        switch command {
        case "activate": toplevels?.activate(id: id)
        case "close": toplevels?.close(id: id)
        case "setMinimized": toplevels?.setMinimized(id: id, (obj["minimized"] as? Bool) ?? false)
        default: break
        }
    }

    // MARK: - Frame loop

    private func loop() {
        let displayFd = client.fd
        var pollfds = [
            pollfd(fd: displayFd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: exitSignalFD, events: Int16(POLLIN), revents: 0),
        ]
        while running {
            client.flush()
            // Wake on Wayland events or the frame deadline (~16.6ms for 60Hz
            // pacing), or sooner if a key repeat is due before then — repeats
            // must not be quantized to the frame rate.
            let nowNs = monotonicNowNs()
            var timeoutMs: Int32 = 16
            if let untilRepeatNs = inputRouter?.nanosecondsUntilNextRepeat(nowNs: nowNs) {
                timeoutMs = min(timeoutMs, Int32(untilRepeatNs / 1_000_000))
            }

            // An authentication attempt in flight adds its pipe to the wait, so
            // the verdict arrives as soon as the helper answers rather than at
            // the next frame — and the lock screen keeps drawing meanwhile.
            let authFD = authenticator?.pendingFD
            let busFD = systemBus?.fileDescriptor ?? -1
            pollfds.removeSubrange(2...)
            if let authFD {
                pollfds.append(pollfd(fd: authFD, events: Int16(POLLIN), revents: 0))
            }
            if busFD >= 0, let systemBus {
                pollfds.append(pollfd(
                    fd: busFD, events: systemBus.pollEvents, revents: 0))
                // sd-bus has deadlines of its own — a pending call's timeout —
                // so the loop must not sleep past them.
                if let untilBusUs = systemBus.timeoutMicroseconds() {
                    timeoutMs = min(timeoutMs, Int32(clamping: untilBusUs / 1000))
                }
            }

            let ready = poll(&pollfds, nfds_t(pollfds.count), timeoutMs)
            if ready < 0 {
                if errno == EINTR { continue }
                writeErr("nucleus-shell: poll failed: \(String(cString: strerror(errno)))")
                break
            }
            if ready > 0 && (pollfds[0].revents & Int16(POLLIN)) != 0 {
                if client.dispatch() < 0 { break }  // compositor disconnected
            }
            if ready > 0 && (pollfds[1].revents & Int16(POLLIN)) != 0 {
                _ = nucleus_shell_consume_exit_signal(exitSignalFD)
                break
            }
            if ready > 0, authFD != nil, pollfds.count > 2,
               pollfds[2].revents & Int16(POLLIN | POLLHUP) != 0 {
                authenticator?.drainPendingAttempt()
            }

            if busFD >= 0 {
                // Timeouts fire without the descriptor becoming readable, so the
                // bus is processed on a bare wakeup too.
                do {
                    try systemBus?.process()
                } catch {
                    writeErr("nucleus-shell: system bus error: \(error)")
                }
            }

            // Emit any key repeats that came due while polling.
            inputRouter?.advanceKeyRepeat(nowNs: monotonicNowNs())

            // A tooltip appears while the pointer is *still*, so it cannot be
            // driven by events — the frame loop is what notices the pointer has
            // rested long enough.
            inputScene?.updateToolTip(atNanoseconds: monotonicNowNs())

            // Drain the RN JS queue so mounted mutations land before rendering.
            if let host = rnHost {
                do {
                    _ = try host.drainPendingJSCalls()
                } catch {
                    writeErr("nucleus-shell: failed to drain JS runtime: \(error)")
                    break
                }
            }
            // Apply any JS→native taskbar commands pushed since the last frame.
            for (command, argsJson) in commandInbox.drain() {
                applyCommand(command, argsJson)
            }
            // Render every dirty shell surface for this frame.
            _ = engine.renderFrame(presentTimeNs: monotonicNowNs() &+ 16_666_666)
        }
        shutdown()
    }

    private func shutdown() {
        if let host = rnHost, let sid = barSurfaceID {
            do {
                try host.stopSurface(id: sid)
            } catch {
                writeErr("nucleus-shell: failed to stop RN surface \(sid): \(error)")
            }
        }
        barSurface?.destroy()
        engine.shutdown()
    }

    private func writeErr(_ s: String) {
        let msg = s + "\n"
        _ = msg.withCString { write(2, $0, strlen($0)) }
    }
}

/// Thread-safe hand-off from the JS thread (the facade's command callback) to the main-actor
/// frame loop. The Wayland client is single-threaded, so commands are queued here and applied
/// on the loop rather than touched from the JS thread.
final class CommandInbox: Sendable {
    private let pending = Mutex<[(String, String)]>([])
    func push(_ command: String, _ argsJson: String) {
        pending.withLock { $0.append((command, argsJson)) }
    }
    func drain() -> [(String, String)] {
        pending.withLock {
            let output = $0
            $0.removeAll(keepingCapacity: true)
            return output
        }
    }
}

func monotonicNowNs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}
