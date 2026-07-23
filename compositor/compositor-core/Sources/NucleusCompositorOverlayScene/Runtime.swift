import Glibc
public import NucleusCompositorOverlay
public import NucleusCompositorOverlayTypes
public import NucleusCompositorServer
internal import struct NucleusCompositorServerTypes.WireLogicalRect
public import NucleusLayers
import NucleusRenderHost
public import NucleusUI
import Tracy

@MainActor
public protocol OverlayPublicationHost: AnyObject {
    func notificationClosed(id: UInt32, reason: UInt32)
    func accessibilitySceneDidPublish()
    func windowMenuSelected(windowID: UInt64, verb: Int32)
}

@MainActor
public protocol OverlaySceneHost: AnyObject {
    func frameUpdated(_ frame: FrameInfo)
    func notificationAdded(_ notification: ShellOverlayNotificationInfo)
    func notificationDismissed(id: UInt32, reason: UInt32)
    func hotkeyVisibilitySet(visible: Bool)
    func inputDispatched(_ event: InputEvent) -> InputResult
    func notificationFrameActive() -> Bool
    func notificationDeadlineNs() -> UInt64
    func showWindowMenu(windowID: UInt64, x: Double, y: Double, capabilities: UInt32)
    func dismissMenu()
    func menuVisible() -> Bool
    func wantsKeyboard() -> Bool
}

private enum ShellOverlayRuntimeError: Error {
    case unavailable
}

/// Runtime-owned overlay scene, input target, and publication callback graph.
/// `ShellServices` owns exactly one instance and releases it during compositor
/// teardown; no overlay authority is installed process-wide.
@MainActor
public final class OverlaySceneRuntime: OverlaySceneHost {
    private unowned let server: NucleusCompositorServer
    private weak var publicationHost: (any OverlayPublicationHost)?
    private var controller: ShellOverlayController?

    public init(server: NucleusCompositorServer) {
        self.server = server
    }

    public func installHost(
        _ publicationHost: sending any OverlayPublicationHost,
        commitSink: any CommitSink,
        services: UIHostServices,
        environment: UIEnvironment
    ) -> Bool {
        self.publicationHost = publicationHost
        guard controller == nil else { return true }
        do {
            controller = ShellOverlayController(
                scene: try ShellOverlayScene(
                    frame: nil,
                    notificationClosed: { [weak self] id, reason in
                        self?.publicationHost?.notificationClosed(id: id, reason: reason)
                    },
                    commitSink: commitSink,
                    services: services,
                    environment: environment),
                semanticPublisher: { [weak self] in
                    self?.publicationHost?.accessibilitySceneDidPublish()
                },
                scenePublisher: { publication in
                    Trace.zone("overlay.runtime.publish_to_host", color: Trace.Color.blue) {
                        Trace.plot(
                            "swift.overlay.runtime.publish_items",
                            UInt64(publication.scene.visualContent.count))
                    }
                })
            return true
        } catch {
            logShellOverlayRuntime("scene init failed: \(error)")
            controller = nil
            self.publicationHost = nil
            return false
        }
    }

    public func clearHost() {
        controller = nil
        publicationHost = nil
    }

    public func withScene<R>(
        _ body: (ShellOverlayScene) throws -> R
    ) throws -> R {
        guard let controller else { throw ShellOverlayRuntimeError.unavailable }
        return try body(controller.scene)
    }

    public func publishScene() {
        Trace.zone("overlay.runtime.publish", color: Trace.Color.blue) {
            controller?.publishScene()
        }
    }

    public func updateEnvironment(_ environment: UIEnvironment) {
        controller?.scene.updateEnvironment(environment)
    }

    public func frameUpdated(_ frame: FrameInfo) {
        submit(.frame(ShellOverlayFrameInfo(frame)))
    }

    public func notificationAdded(_ notification: ShellOverlayNotificationInfo) {
        submit(.notification(notification))
    }

    public func notificationDismissed(id: UInt32, reason: UInt32) {
        submit(.dismissNotification(id: id, reason: reason == 0 ? 2 : reason))
    }

    public func hotkeyVisibilitySet(visible: Bool) {
        submit(.hotkeyVisibility(visible))
    }

    public func inputDispatched(_ event: InputEvent) -> InputResult {
        guard let controller else { return ShellOverlayInputResult.passThrough.abiValue }
        return controller.dispatchInput(ShellOverlayInputEvent(event)).abiValue
    }

    public func notificationFrameActive() -> Bool {
        controller?.scene.notificationFrameActive ?? false
    }

    public func notificationDeadlineNs() -> UInt64 {
        controller?.scene.notificationPublicationDeadlineNs ?? 0
    }

    public func showWindowMenu(
        windowID: UInt64,
        x: Double,
        y: Double,
        capabilities: UInt32
    ) {
        guard let controller else {
            logShellOverlayRuntime(
                "dropping window menu for window=\(windowID); scene unavailable")
            return
        }
        let menu = makeWindowMenu(capabilities: capabilities) { [weak self] verb in
            self?.publicationHost?.windowMenuSelected(
                windowID: windowID,
                verb: Int32(verb.rawValue))
        }
        controller.showMenu(menu, at: Point(x: x, y: y))
    }

    public func dismissMenu() {
        controller?.dismissMenu()
    }

    public func menuVisible() -> Bool {
        controller?.scene.menuVisible ?? false
    }

    public func wantsKeyboard() -> Bool {
        controller?.scene.wantsKeyboard ?? false
    }

    public func primaryOutputSize() -> OutputSize {
        let outputID = server.spaces.overlayDisplayID(layout: server.layout)
        guard let display = server.layout.display(id: outputID) else {
            return .init(width: 0, height: 0, scale: 1)
        }
        return .init(
            width: UInt32(max(1, Int(display.logicalRect.width.rounded(.up)))),
            height: UInt32(max(1, Int(display.logicalRect.height.rounded(.up)))),
            scale: Float(display.fractionalScale))
    }

    private func submit(_ event: ShellOverlayEvent) {
        Trace.zone("overlay.runtime.submit_event", color: Trace.Color.blue) {
            Trace.plot("swift.overlay.runtime.event_kind", event.metricValue)
            guard let controller else {
                logShellOverlayRuntime("dropping overlay event; scene unavailable")
                return
            }
            controller.submit(event: event)
        }
    }
}

private extension ShellOverlayEvent {
    var metricValue: UInt64 {
        switch self {
        case .frame: 1
        case .notification: 2
        case .dismissNotification: 3
        case .hotkeyVisibility: 5
        }
    }
}

private func logShellOverlayRuntime(_ message: String) {
    let line = "shell-overlay-runtime: \(message)\n"
    line.withCString { pointer in
        _ = unsafe write(STDERR_FILENO, pointer, strlen(pointer))
    }
}
