@_spi(NucleusCompositor) import NucleusReactRuntime
import NucleusUI
import NucleusTextBackend
import NucleusUIEmbedder
import NucleusLayers
import NucleusRenderModel
import NucleusRenderHost
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellPasteboard
import NucleusShellInput
import NucleusShellAuth
import NucleusLinuxDBus
import NucleusLinuxAccessibility
import NucleusShellServices
import NucleusLinuxEnvironment
import NucleusLinuxReactor
import NucleusShellProduct
import NucleusShellRender
import NucleusShellLoop
import NucleusRenderer
import NucleusShellSignalC
import Foundation
import Synchronization
import Tracy
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
//        │ evaluates bar.hbc, runs "bar"                │ commits → runtime-owned retained store
//        ▼                                              ▼
//   React <Bar/>  ──layer tree──────────────────▶  RenderCore.renderReady  ──present──▶ wl_surface
//
// The RN runtime boot reuses the same NucleusReactRuntime.Host facade the (now-deleted)
// compositor overlay used — the difference is only WHERE the surface attaches: a shell-owned
// root layer feeding this process's RenderCore, not the compositor's overlay scene.
@MainActor
public final class ShellHost {
    private enum ReactorKind: UInt64 {
        case display = 1
        case exitSignal
        case renderWake
        case authentication
        case systemBus
        case accessibility
        case environment
        case pasteboardTransfer
        case dragTransfer
    }

    private static let reactorKindShift: UInt64 = 56
    private static let reactorInstanceMask =
        (UInt64(1) << reactorKindShift) - 1

    private static func reactorToken(
        _ kind: ReactorKind,
        instance: UInt64 = 0
    ) -> UInt64 {
        precondition(
            instance <= reactorInstanceMask,
            "shell reactor instance space exhausted")
        return (kind.rawValue << reactorKindShift) | instance
    }

    private let client: ShellWaylandClient
    private let engine: ShellRenderEngine
    private let renderWake: ShellRenderWakeSink
    private let reactor: LinuxHostReactor
    private let bundleURL: String
    private let resourceHost: SwiftResourceHost
    private let retainedStore: RetainedTreeStore
    private let hostBundle: NucleusAppHostBundle
    private let iconSourceResolver = ShellIconSourceResolver()

    private var rnHost: NucleusReactRuntime.Host?
    fileprivate var barSurface: LayerSurface?
    private var barOutputID: UInt64?
    private var barSurfaceID: Int?

    // The root render context the RN surface attaches into. Its commit sink lowers the RN
    // layer tree into the runtime-owned store, which the render engine's RenderCore reads.
    // The bar's root View is what the RN surface mounts into (attachSurface); its backing
    // layer tree commits through the context's sink.
    private var renderContext: Context?
    private var nativePublicationContext: WindowScenePublicationContext?
    private var barRootView: View?

    /// The seat and the scene its input is routed into.
    ///
    /// Constructed here so input exists for the whole process lifetime, but no
    /// window is registered by default: the bar is a React Native surface with
    /// its own touch handling, so routing NucleusUI events into it would mean two
    /// input paths over one tree. A native surface owner calls
    /// `inputRouter.register(window:forSurface:)` to opt in.
    private var seat: ShellSeat?
    private var pasteboardAdapter: ShellWaylandPasteboardAdapter?
    private var dragDropAdapter: ShellWaylandDragDropAdapter?
    public private(set) var inputScene: WindowScene?
    public private(set) var inputRouter: ShellInputRouter?
    private var accessibilityAdapter: AtSPIService?
    private var accessibilityBridge: AtSPIBridge?
    private var environmentAdapter: PortalEnvironmentAdapter?

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
    private var renderWorkDue = true
    private var nativeSceneDirty = true
    private var animationDemand = false
    private var nextPresentationDeadlineNs: UInt64?

    /// JS→native taskbar commands, pushed on the JS thread and drained on the main actor.
    private let commandInbox: CommandInbox

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
        guard let reactor = try? LinuxHostReactor(queueDepth: 256) else {
            return nil
        }
        let resourceHost = SwiftResourceHost()
        let retainedStore = RetainedTreeStore(resourceHost: resourceHost)
        let hostBundle = NucleusAppHostBundle(resourceHost: resourceHost)
        guard let renderWake = ShellRenderWakeSink(),
              let engine = ShellRenderEngine(
                display: client.display,
                store: retainedStore,
                resourceHost: resourceHost,
                asyncRenderWakeSink: renderWake)
        else { return nil }
        self.exitSignalFD = exitSignalFD
        self.client = client
        self.reactor = reactor
        self.engine = engine
        self.renderWake = renderWake
        self.commandInbox = CommandInbox(wakeSink: renderWake)
        self.bundleURL = bundleURL
        self.resourceHost = resourceHost
        self.retainedStore = retainedStore
        self.hostBundle = hostBundle
        closeLocalSignalFD = false
    }

    deinit {
        close(exitSignalFD)
    }

    /// Bring the shell up: install the host bundle, register native modules, create the bar
    /// surface, boot RN, and start the frame loop. Blocks in the loop until the compositor
    /// disconnects or a signal requests exit.
    public func run() async {
        client.onOutputsChanged = { [weak self] in
            self?.outputsChanged()
        }
        client.onGlobalChanged = { [weak self] kind in
            self?.waylandGlobalChanged(kind)
        }
        // 1. Acquire the initial desktop environment before the semantic
        //    context or any retained view exists.
        let initialEnvironment = setupEnvironment()

        // 2. The root render context the RN surface commits into.
        setupRenderContext(environment: initialEnvironment)

        // 4. The foreign-toplevel window model. Its snapshots flow to JS (native→JS) through
        //    the facade's emitDeviceEvent — no custom native module. (JS→native taskbar actions
        //    await the facade host-command seam; see pushWindowsToJS.)
        setupForeignToplevel()

        // 5. The seat: pointer and keyboard, translated into framework events.
        setupInput()

        // 6. System services. Each maps a bus peer onto a value type and hands
        //    it to a view; this is the only place the two meet.
        setupServices()

        // 7. The bar layer-shell surface. Its first configure builds the swapchain + boots RN.
        createBarSurface()

        // 8. The event loop: wl_display fd + a frame timer.
        running = true
        await loop()
    }

    // MARK: - Render context

    private func setupRenderContext(environment: UIEnvironment) {
        // The RN layer tree flows: Context.commitSink → RenderCommitSink → runtime-owned store.
        // RenderCommitSink defaults resourceHostHandle to the production host installed above.
        do {
            let commitSink = RenderCommitSink(
                store: retainedStore,
                resourceHost: resourceHost,
                runtimeHost: hostBundle.layersHost,
                requestFrame: { [weak self] in
                    self?.requestRender(nativeSceneChanged: true)
                })
            let context = try Context(commitSink: commitSink)
            let textSystem = TextSystem()
            SkiaTextLayoutBackend.install(in: textSystem)
            let services = UIHostServices(
                textSystem: textSystem,
                pasteboard: Pasteboard(
                    adapter: UnavailablePasteboardAdapter()),
                imageSourceResolver:
                    iconSourceResolver.imageSourceResolver,
                diagnosticSink: { [weak self] diagnostic in
                    self?.writeErr("shell UI service failure: \(diagnostic)")
                })
            let nativePublicationContext = try WindowScenePublicationContext(
                commitSink: commitSink,
                services: services,
                environment: environment
            )
            renderContext = context
            self.nativePublicationContext = nativePublicationContext
            nativePublicationContext.semanticContext
                .setAnimationFrameRequestHandler { [weak self] in
                    self?.animationFrameRequested()
                }
        } catch {
            writeErr("shell: failed to build render context: \(error)")
        }
    }

    private func setupEnvironment() -> UIEnvironment {
        let adapter = PortalEnvironmentAdapter()
        adapter.onChange = { [weak self] environment in
            guard let self, let nativePublicationContext else { return }
            nativePublicationContext.semanticContext.updateEnvironment(
                environment)
            requestRender(nativeSceneChanged: true)
        }
        let initial = adapter.start()
        environmentAdapter = adapter
        return initial
    }

    // MARK: - Input

    private func setupInput() {
        guard let nativePublicationContext else {
            writeErr("shell: native scene publication context is unavailable")
            return
        }
        let scene = nativePublicationContext.makeWindowScene(windows: [])
        let seat = ShellSeat(client: client)
        if seat == nil {
            // A seatless session (no input devices) is legitimate; the shell
            // still renders.
            writeErr("shell: no wl_seat available; running without input")
        }
        inputScene = scene
        self.seat = seat
        configurePasteboard(for: seat)
        // Where the two cursor vocabularies meet. NucleusUI decides *which*
        // cursor from the tracking areas under the pointer; the seat asks the
        // compositor for it. Neither layer knows the other's spelling.
        scene.onCursorChange = { [weak seat] cursor in
            seat?.setCursor(ShellHost.cursorShape(for: cursor))
        }
        let router = ShellInputRouter(scene: scene, seat: seat, client: client)
        router.onSurfaceWillUnregister = { [weak self] surfaceID in
            self?.dragDropAdapter?.surfaceWillClose(surfaceID)
        }
        inputRouter = router
        configureDragDrop(for: seat)
        setupAccessibility(scene: scene)
        // PAM runs in a helper process, never in this address space: a module
        // that crashes or calls `exit()` would otherwise take the locker with it,
        // and a dead locker leaves the session blank and locked for good.
        let authenticator = PamAuthenticator(
            pollSetDidChange: { [weak reactor] in reactor?.wake() })
        self.authenticator = authenticator
        let controller = ShellLockController(
            client: client,
            engine: engine,
            scene: scene,
            publicationContext: nativePublicationContext,
            inputRouter: router
        )
        controller.authenticator = authenticator
        lockController = controller
    }

    private func waylandGlobalChanged(_ kind: WaylandGlobalKind) {
        switch kind {
        case .dataControl:
            configurePasteboard(for: seat)
        case .dataDeviceManager:
            configureDragDrop(for: seat)
        case .seat:
            dragDropAdapter?.shutdown()
            dragDropAdapter = nil
            let replacement = ShellSeat(client: client)
            seat = replacement
            inputRouter?.replaceSeat(replacement, client: client)
            inputScene?.onCursorChange = { [weak replacement] cursor in
                replacement?.setCursor(ShellHost.cursorShape(for: cursor))
            }
            configurePasteboard(for: replacement)
            configureDragDrop(for: replacement)
        default:
            break
        }
    }

    private func configurePasteboard(for seat: ShellSeat?) {
        guard let nativePublicationContext else { return }
        let pasteboard = nativePublicationContext.semanticContext
            .services.pasteboard
        guard let seat,
              let adapter = ShellWaylandPasteboardAdapter(
                client: client,
                seat: seat,
                pollSetDidChange: { [weak reactor] in reactor?.wake() },
                diagnosticHandler: { [weak pasteboard] operation, failure in
                    pasteboard?.reportAdapterFailure(
                        failure,
                        operation: operation)
                })
        else {
            pasteboard.replaceAdapter(UnavailablePasteboardAdapter())
            pasteboardAdapter = nil
            return
        }
        pasteboard.replaceAdapter(adapter)
        pasteboardAdapter = adapter
    }

    private func configureDragDrop(for seat: ShellSeat?) {
        dragDropAdapter?.shutdown()
        dragDropAdapter = nil
        guard let seat, let router = inputRouter else { return }
        dragDropAdapter = ShellWaylandDragDropAdapter(
            client: client,
            seat: seat,
            destinationResolver: { [weak router] surfaceID, location in
                router?.dragDestination(
                    forSurface: surfaceID,
                    location: location)
            },
            pollSetDidChange: { [weak reactor] in reactor?.wake() },
            diagnosticHandler: { [weak self] operation, message in
                self?.writeErr(
                    "shell: drag \(operation) failed: \(message)")
            })
    }

    private func setupAccessibility(scene: WindowScene) {
        let adapter = AtSPIService(applicationName: "Nucleus Shell")
        adapter.diagnosticHandler = { [weak self] failure, generation in
            self?.writeErr(
                "shell: AT-SPI generation \(generation) "
                    + "\(failure.operation) failed (\(failure.code))")
        }
        let bridge = AtSPIBridge(scene: scene, service: adapter)
        adapter.onAction = { [weak self, weak bridge] request in
            let handled = bridge?.perform(request) ?? false
            if handled {
                self?.requestRender(nativeSceneChanged: true)
            }
            return handled
        }
        accessibilityAdapter = adapter
        accessibilityBridge = bridge
        _ = bridge.publish()
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
            self?.requestRender(nativeSceneChanged: true)
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
        guard let surface = barSurface, let renderContext else {
            writeErr("shell: bar configured without a render context")
            return
        }

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
        } else if let id = engine.addSurface(
            waylandSurface: surface.wlSurface,
            width: width,
            height: height,
            scale: scale,
            presentationContextID: renderContext.id.rawValue,
            refreshMillihertz:
                surface.output?.refreshMillihertz
                ?? client.outputs.values.first?.refreshMillihertz
                ?? 0
        ) {
            barOutputID = id
            bootReactBar(width: Double(width) / scale, height: Double(height) / scale, scale: scale)
        }
    }

    private func outputsChanged() {
        if let barOutputID {
            let refresh = barSurface?.output?.refreshMillihertz
                ?? client.outputs.values.first?.refreshMillihertz
                ?? 0
            engine.setRefreshMillihertz(refresh, forSurface: barOutputID)
        }
        lockController?.updateOutputRefreshRates()
        requestRender(nativeSceneChanged: true)
    }

    // MARK: - React boot (the NucleusReactRuntime.Host facade)

    private func bootReactBar(width: Double, height: Double, scale: Double) {
        guard let renderContext, let nativePublicationContext else { return }
        do {
            let rootView = nativePublicationContext.withSemanticContext {
                View()
            }
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
                visualContext: renderContext,
                backingScaleFactor: BackingScaleFactor(Float(scale)), at: 0)
            // JS→native taskbar actions: NucleusHostCommand.invoke(command, argsJson) fires
            // on the JS thread → push onto the thread-safe inbox the frame loop drains onto
            // the main actor (the Wayland client is single-threaded / @MainActor).
            let inbox = commandInbox
            try host.setCommandHandler { command, argsJson in inbox.push(command, argsJson) }
            let renderWake = self.renderWake
            try host.setJSWorkWakeHandler {
                renderWake.signalRenderWork()
            }
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

    private func animationFrameRequested() {
        animationDemand = true
        requestRender(nativeSceneChanged: true)
        renderWake.signalRenderWork()
    }

    private func requestRender(nativeSceneChanged: Bool = false) {
        renderWorkDue = true
        if nativeSceneChanged { nativeSceneDirty = true }
    }

    // MARK: - Frame loop

    private func loop() async {
        let displayFd = client.fd
        var displayNeedsWrite = false
        var pollWakeCount: UInt64 = 0
        var pollTimeoutCount: UInt64 = 0
        var completionBudgetExhaustionCount: UInt64 = 0
        var idlePollWakeCount: UInt64 = 0
        var renderedFrameCount: UInt64 = 0

        while running {
            let flushResult = client.flush()
            let flushError = errno
            let flushDisposition = ShellFlushDisposition.classify(
                result: flushResult,
                error: flushError)
            switch flushDisposition {
            case .flushed:
                displayNeedsWrite = false
            case .needsWrite:
                displayNeedsWrite = true
            case .disconnected(let error):
                    writeErr(
                        "nucleus-shell: Wayland flush failed: "
                            + String(cString: strerror(error)))
                    break
            }
            if case .disconnected = flushDisposition { break }
            let nowNs = monotonicNowNs()
            if renderWorkDue, nextPresentationDeadlineNs == nil {
                nextPresentationDeadlineNs = nowNs
            }
            var deadlines = ShellDeadlineSet()
            deadlines.add(relativeNanoseconds:
                inputRouter?.nanosecondsUntilNextRepeat(nowNs: nowNs))
            deadlines.add(relativeNanoseconds:
                inputScene?.nanosecondsUntilToolTip(atNanoseconds: nowNs))
            if renderWorkDue, let presentationDeadline = nextPresentationDeadlineNs {
                deadlines.add(relativeNanoseconds:
                    presentationDeadline > nowNs
                        ? presentationDeadline - nowNs
                        : 0)
            }

            // An authentication attempt in flight adds its pipe to the wait, so
            // the verdict arrives as soon as the helper answers rather than at
            // a presentation deadline.
            let authFD = authenticator?.pendingFD
            let busFD = systemBus?.fileDescriptor ?? -1
            let pasteboardDescriptors =
                pasteboardAdapter?.pollDescriptors ?? []
            let dragDescriptors =
                dragDropAdapter?.pollDescriptors ?? []
            var interests: [LinuxReactorInterest] = []
            interests.reserveCapacity(
                7 + pasteboardDescriptors.count
                    + dragDescriptors.count)
            interests.append(LinuxReactorInterest(
                token: Self.reactorToken(.display),
                fileDescriptor: displayFd,
                events: Int16(POLLIN)
                    | (displayNeedsWrite ? Int16(POLLOUT) : 0),
                mode: .multishot))
            interests.append(LinuxReactorInterest(
                token: Self.reactorToken(.exitSignal),
                fileDescriptor: exitSignalFD,
                events: Int16(POLLIN),
                mode: .multishot))
            interests.append(LinuxReactorInterest(
                token: Self.reactorToken(.renderWake),
                fileDescriptor: renderWake.fileDescriptor,
                events: Int16(POLLIN),
                mode: .multishot))
            if let authFD {
                interests.append(LinuxReactorInterest(
                    token: Self.reactorToken(.authentication),
                    fileDescriptor: authFD,
                    events: Int16(POLLIN)))
            }
            if busFD >= 0, let systemBus {
                interests.append(LinuxReactorInterest(
                    token: Self.reactorToken(.systemBus),
                    fileDescriptor: busFD,
                    events: systemBus.pollEvents))
                deadlines.add(relativeMicroseconds:
                    systemBus.timeoutMicroseconds())
            }
            appendLinuxReactorInterest(
                accessibilityAdapter,
                token: Self.reactorToken(.accessibility),
                interests: &interests,
                deadlines: &deadlines)
            appendLinuxReactorInterest(
                environmentAdapter,
                token: Self.reactorToken(.environment),
                interests: &interests,
                deadlines: &deadlines)
            for descriptor in pasteboardDescriptors {
                interests.append(LinuxReactorInterest(
                    token: Self.reactorToken(
                        .pasteboardTransfer,
                        instance: descriptor.token),
                    fileDescriptor: descriptor.fileDescriptor,
                    events: descriptor.events))
            }
            for descriptor in dragDescriptors {
                interests.append(LinuxReactorInterest(
                    token: Self.reactorToken(
                        .dragTransfer,
                        instance: descriptor.token),
                    fileDescriptor: descriptor.fileDescriptor,
                    events: descriptor.events))
            }
            deadlines.add(relativeNanoseconds:
                pasteboardAdapter?.nanosecondsUntilTransferDeadline(
                    nowNanoseconds: nowNs))
            deadlines.add(relativeNanoseconds:
                dragDropAdapter?.nanosecondsUntilTransferDeadline(
                    nowNanoseconds: nowNs))

            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(
                    interests: interests,
                    timeoutNanoseconds: deadlines.earliestNanoseconds)
            } catch {
                writeErr("nucleus-shell: host reactor failed: \(error)")
                break
            }
            pollWakeCount &+= 1
            if batch.didReachDeadline {
                pollTimeoutCount &+= 1
            }
            if batch.didExhaustCompletionBudget {
                completionBudgetExhaustionCount &+= 1
            }
            Trace.plot(
                "swift.shell.loop.poll_wakes",
                pollWakeCount)
            Trace.plot(
                "swift.shell.loop.poll_timeouts",
                pollTimeoutCount)
            Trace.plot(
                "swift.shell.loop.completion_budget_exhaustions",
                completionBudgetExhaustionCount)
            if let latency = batch.executorResumeLatencyNanoseconds {
                Trace.plot(
                    "swift.shell.loop.main_actor_resume_ms",
                    Double(latency) / 1_000_000.0)
            }

            var hadHostEvent = false
            var shouldStop = false
            var processedSystemBus = false
            var processedAccessibility = false
            var processedEnvironment = false
            let eventNowNanoseconds = monotonicNowNs()

            for event in batch.events {
                guard let kind = ReactorKind(
                    rawValue: event.token >> Self.reactorKindShift)
                else { continue }
                let instance = event.token & Self.reactorInstanceMask
                let result = ShellPollResult(
                    revents: event.failureCode == nil
                        ? event.returnedEvents
                        : Int16(POLLERR))
                switch kind {
                case .display:
                    if result.isTerminal {
                        writeErr(
                            "nucleus-shell: Wayland compositor disconnected")
                        shouldStop = true
                    } else {
                        if result.isReadable {
                            if client.dispatch() < 0 {
                                writeErr(
                                    "nucleus-shell: Wayland dispatch failed")
                                shouldStop = true
                            } else {
                                hadHostEvent = true
                                requestRender(nativeSceneChanged: true)
                            }
                        }
                        if result.isWritable { hadHostEvent = true }
                    }
                case .exitSignal:
                    if result.isTerminal || result.isReadable {
                        _ = nucleus_shell_consume_exit_signal(
                            exitSignalFD)
                        shouldStop = true
                    }
                case .renderWake:
                    if result.isTerminal {
                        writeErr(
                            "nucleus-shell: renderer wake source failed")
                        shouldStop = true
                    } else if result.isReadable, renderWake.drain() {
                        hadHostEvent = true
                        requestRender()
                    }
                case .authentication:
                    if result.isInvalid || result.hasError {
                        authenticator?.failPendingAttempt(
                            "Authentication helper descriptor failed")
                        hadHostEvent = true
                        requestRender(nativeSceneChanged: true)
                    } else if result.isReadable || result.isHungUp {
                        authenticator?.drainPendingAttempt()
                        hadHostEvent = true
                        requestRender(nativeSceneChanged: true)
                    }
                case .systemBus:
                    processedSystemBus = true
                    if result.isTerminal {
                        closeSystemBusIntegration(
                            reason: "system bus descriptor closed")
                    } else if let systemBus {
                        do {
                            if try systemBus.process() {
                                requestRender(nativeSceneChanged: true)
                            }
                            hadHostEvent = true
                        } catch {
                            closeSystemBusIntegration(
                                reason: "system bus error: \(error)")
                        }
                    }
                case .accessibility:
                    processedAccessibility = true
                    hadHostEvent = processLinuxReactorSource(
                        accessibilityAdapter,
                        result: result,
                        failureOperation:
                            "accessibility bus descriptor closed")
                        || hadHostEvent
                case .environment:
                    processedEnvironment = true
                    hadHostEvent = processLinuxReactorSource(
                        environmentAdapter,
                        result: result,
                        failureOperation:
                            "desktop settings portal descriptor closed")
                        || hadHostEvent
                case .pasteboardTransfer:
                    pasteboardAdapter?.processPollResult(
                        token: instance,
                        result: result,
                        nowNanoseconds: eventNowNanoseconds)
                    hadHostEvent = true
                case .dragTransfer:
                    dragDropAdapter?.processPollResult(
                        token: instance,
                        result: result,
                        nowNanoseconds: eventNowNanoseconds)
                    hadHostEvent = true
                }
                if shouldStop { break }
            }
            if shouldStop { break }

            if !processedSystemBus,
               let systemBus,
               systemBus.timeoutMicroseconds() == 0
            {
                do {
                    if try systemBus.process() {
                        requestRender(nativeSceneChanged: true)
                    }
                    hadHostEvent = true
                } catch {
                    closeSystemBusIntegration(
                        reason: "system bus error: \(error)")
                }
            }
            if !processedAccessibility {
                hadHostEvent = processLinuxReactorSource(
                    accessibilityAdapter,
                    result: nil,
                    failureOperation:
                        "accessibility bus descriptor closed")
                    || hadHostEvent
            }
            if !processedEnvironment {
                hadHostEvent = processLinuxReactorSource(
                    environmentAdapter,
                    result: nil,
                    failureOperation:
                        "desktop settings portal descriptor closed")
                    || hadHostEvent
            }

            let pasteboardPollNs = monotonicNowNs()
            pasteboardAdapter?.expireTransfers(
                nowNanoseconds: pasteboardPollNs)
            dragDropAdapter?.expireTransfers(
                nowNanoseconds: pasteboardPollNs)

            let afterPollNs = monotonicNowNs()
            if inputRouter?.nanosecondsUntilNextRepeat(
                nowNs: afterPollNs) == 0
            {
                inputRouter?.advanceKeyRepeat(nowNs: afterPollNs)
                requestRender(nativeSceneChanged: true)
            }
            if inputScene?.nanosecondsUntilToolTip(
                atNanoseconds: afterPollNs) == 0
            {
                inputScene?.updateToolTip(atNanoseconds: afterPollNs)
                requestRender(nativeSceneChanged: true)
            }

            // Cross-thread JS work owns the renderer-wake eventfd. Other host
            // events may synchronously enqueue JS too, so both paths drain.
            if hadHostEvent, let host = rnHost {
                do {
                    if try host.drainPendingJSCalls() > 0 {
                        requestRender()
                    }
                } catch {
                    writeErr("nucleus-shell: failed to drain JS runtime: \(error)")
                    break
                }
            }

            if hadHostEvent {
                let commands = commandInbox.drain()
                for (command, argsJson) in commands {
                    applyCommand(command, argsJson)
                }
                if !commands.isEmpty { requestRender() }
            }

            let frameDecisionNs = monotonicNowNs()
            if renderWorkDue, nextPresentationDeadlineNs == nil {
                nextPresentationDeadlineNs = frameDecisionNs
            }
            guard let scheduledDeadline = nextPresentationDeadlineNs,
                  ShellFrameDecision.shouldRender(
                    workPending: renderWorkDue,
                    deadline: scheduledDeadline,
                    now: frameDecisionNs)
            else {
                idlePollWakeCount &+= 1
                Trace.plot(
                    "swift.shell.loop.idle_poll_wakes",
                    idlePollWakeCount)
                continue
            }

            renderWorkDue = false
            let interval = engine.presentationIntervalNanoseconds
            let predictedPresentationNs = clampedAdd(
                frameDecisionNs, interval)

            if animationDemand {
                animationDemand = false
                let remainsActive = nativePublicationContext?
                    .semanticContext
                    .advanceAnimations(
                        predictedPresentationNanoseconds:
                            predictedPresentationNs)
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
                presentTimeNs: predictedPresentationNs
            )
            renderedFrameCount &+= 1
            Trace.plot(
                "swift.shell.loop.rendered_frames",
                renderedFrameCount)
            nextPresentationDeadlineNs =
                ShellPresentationTiming.nextDeadline(
                    previous: scheduledDeadline,
                    now: frameDecisionNs,
                    interval: interval)
        }
        shutdown()
    }

    private func closeSystemBusIntegration(reason: String) {
        writeErr("nucleus-shell: \(reason)")
        upower?.stop()
        upower = nil
        systemBus?.close()
        systemBus = nil
    }

    private func appendLinuxReactorInterest<Source: LinuxReactorSource>(
        _ source: Source?,
        token: UInt64,
        interests: inout [LinuxReactorInterest],
        deadlines: inout ShellDeadlineSet
    ) {
        guard let source else { return }
        deadlines.add(relativeMicroseconds: source.timeoutMicroseconds())
        guard source.fileDescriptor >= 0, source.pollEvents != 0 else {
            return
        }
        interests.append(LinuxReactorInterest(
            token: token,
            fileDescriptor: source.fileDescriptor,
            events: source.pollEvents))
    }

    private func processLinuxReactorSource<Source: LinuxReactorSource>(
        _ source: Source?,
        result: ShellPollResult?,
        failureOperation: String
    ) -> Bool {
        guard let source else { return false }
        if result?.isTerminal == true {
            source.transportDidFail(operation: failureOperation)
            return true
        }
        guard (result?.revents ?? 0) != 0
                || source.timeoutMicroseconds() == 0
        else { return false }
        if source.process() {
            requestRender(nativeSceneChanged: true)
        }
        return true
    }

    private func closeAccessibilityIntegration(reason: String) {
        writeErr("nucleus-shell: \(reason)")
        accessibilityAdapter?.close()
        accessibilityBridge = nil
        accessibilityAdapter = nil
    }

    private func shutdown() {
        reactor.shutdown()
        environmentAdapter?.stop()
        environmentAdapter = nil
        dragDropAdapter?.shutdown()
        dragDropAdapter = nil
        if let host = rnHost, let sid = barSurfaceID {
            do {
                try host.stopSurface(id: sid)
            } catch {
                writeErr("nucleus-shell: failed to stop RN surface \(sid): \(error)")
            }
        }
        barSurface?.destroy()
        accessibilityAdapter?.close()
        accessibilityBridge = nil
        accessibilityAdapter = nil
        nativePublicationContext?.semanticContext
            .setAnimationFrameRequestHandler(nil)
        nativePublicationContext?.semanticContext.services.pasteboard.shutdown()
        barRootView = nil
        inputScene = nil
        inputRouter = nil
        renderContext = nil
        nativePublicationContext = nil
        pasteboardAdapter = nil
        engine.shutdown()
        hostBundle.invalidate()
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
    private let wakeSink: any AsyncRenderWakeSink

    init(wakeSink: any AsyncRenderWakeSink) {
        self.wakeSink = wakeSink
    }

    func push(_ command: String, _ argsJson: String) {
        let shouldWake = pending.withLock {
            let wasEmpty = $0.isEmpty
            $0.append((command, argsJson))
            return wasEmpty
        }
        if shouldWake { wakeSink.signalRenderWork() }
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

func clampedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}
