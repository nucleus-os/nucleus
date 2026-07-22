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

@MainActor
extension ShellHost {
    // MARK: - Render context

    func setupRenderContext(environment: UIEnvironment) {
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

    func setupEnvironment() -> UIEnvironment {
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

    func setupInput() {
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

    func waylandGlobalChanged(_ kind: WaylandGlobalKind) {
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

    func configurePasteboard(for seat: ShellSeat?) {
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

    func configureDragDrop(for seat: ShellSeat?) {
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

    func setupAccessibility(scene: WindowScene) {
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
}
