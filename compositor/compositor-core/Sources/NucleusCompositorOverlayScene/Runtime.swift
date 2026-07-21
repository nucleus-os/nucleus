import NucleusCompositorOverlayTypes
import Glibc
import NucleusUI
import NucleusUIEmbedder
import NucleusRenderHost
import NucleusLayers
import NucleusCompositorOverlay
import NucleusCompositorServer
import NucleusCompositorWindowManager
import Tracy

/// Active per-WindowServer shell overlay controller. Production installs
/// it during WindowServer bootstrap with its complete initial environment.
/// `nucleus_compositor_overlay_runtime_clear_host` clears the single active
/// controller during teardown.
@MainActor
private var activeShellOverlayController: ShellOverlayController?

@MainActor
private var activePublicationHost: (any OverlayPublicationHost)?

private enum ShellOverlayRuntimeError: Error {
    case unavailable
}

@MainActor
public protocol OverlayPublicationHost: AnyObject {
    func notificationClosed(id: UInt32, reason: UInt32)
    func accessibilitySceneDidPublish()
    /// A window-menu row was activated: report the chosen verb tag for the window
    /// the menu was opened on back to the compositor, which runs the matching window
    /// verb. The mirror of `notificationClosed` — the overlay's only other callback
    /// into the host.
    func windowMenuSelected(windowID: UInt64, verb: Int32)
}

@MainActor
private func makeShellOverlayController(
    commitSink: any CommitSink,
    services: UIHostServices,
    environment: UIEnvironment
) -> ShellOverlayController? {
    do {
        return ShellOverlayController(
            scene: try ShellOverlayScene(
                frame: nil,
                notificationClosed: notifyHostNotificationClosed,
                commitSink: commitSink,
                services: services,
                environment: environment
            ),
            semanticPublisher: publishAccessibilityToHost,
            scenePublisher: publishSceneToHost
        )
    } catch {
        logShellOverlayRuntime("scene init failed: \(error)")
        return nil
    }
}

@MainActor public func nucleus_compositor_overlay_runtime_install_host(
    _ publicationHost: sending any OverlayPublicationHost,
    commitSink: any CommitSink,
    services: UIHostServices,
    environment: UIEnvironment
) -> UInt8 {
    activePublicationHost = publicationHost
    if activeShellOverlayController != nil {
        return 1
    }
    activeShellOverlayController = makeShellOverlayController(
        commitSink: commitSink,
        services: services,
        environment: environment)
    return activeShellOverlayController == nil ? 0 : 1
}

@MainActor
@discardableResult
private func ensureShellOverlayController() -> ShellOverlayController? {
    return activeShellOverlayController
}

@MainActor public func nucleus_compositor_overlay_runtime_clear_host() -> UInt8 {
    activeShellOverlayController = nil
    activePublicationHost = nil
    return 1
}

@MainActor
private func submitOverlayEvent(_ event: NucleusCompositorOverlayTypes.OverlayEvent) {
    Trace.zone("overlay.runtime.submit_event", color: Trace.Color.blue) {
        Trace.plot("swift.overlay.runtime.event_kind", UInt64(event.kind.rawValue))
        guard let shellOverlayController = ensureShellOverlayController() else {
            logShellOverlayRuntime("dropping event kind=\(event.kind); scene unavailable")
            return
        }
        shellOverlayController.submit(event: ShellOverlayEvent(event))
    }
}

@MainActor
public func withGlobalShellOverlayScene<R>(_ body: (ShellOverlayScene) throws -> R) throws -> R {
    guard let shellOverlayController = ensureShellOverlayController() else {
        throw ShellOverlayRuntimeError.unavailable
    }
    return try body(shellOverlayController.scene)
}

@MainActor
public func publishGlobalShellOverlayScene() {
    Trace.zone("overlay.runtime.publish_global", color: Trace.Color.blue) {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return
        }
        shellOverlayController.publishScene()
    }
}

private func emptyFrameInfo() -> NucleusCompositorOverlayTypes.FrameInfo {
    .init(
        outputWidth: 0,
        outputHeight: 0,
        devicePixelRatio: 1,
        overlayRegionX: 0,
        overlayRegionY: 0,
        overlayRegionW: 0,
        overlayRegionH: 0
    )
}

private func emptyStringView() -> NucleusCompositorOverlayTypes.StringView {
    .init(ptr: nil, len: 0)
}

private func emptyNotificationInfo() -> NucleusCompositorOverlayTypes.NotificationInfo {
    .init(
        id: 0,
        appName: emptyStringView(),
        summary: emptyStringView(),
        body: emptyStringView(),
        thumbnailHandle: 0,
        showThumbnail: false,
        expireTimeoutMs: 0
    )
}

private func overlayEvent(kind: UInt32) -> NucleusCompositorOverlayTypes.OverlayEvent {
    .init(
        kind: NucleusCompositorOverlayTypes.EventKind(rawValue: kind) ?? .frame,
        reserved: 0,
        frame: emptyFrameInfo(),
        notification: emptyNotificationInfo(),
        notificationId: 0,
        closeReason: 0,
        visible: false
    )
}

@MainActor
public protocol OverlaySceneHost: AnyObject {
    func frameUpdated(_ frame: NucleusCompositorOverlayTypes.FrameInfo)
    func notificationAdded(_ notification: NucleusCompositorOverlayTypes.NotificationInfo)
    func notificationDismissed(id: UInt32, reason: UInt32)
    func hotkeyVisibilitySet(visible: Bool)
    func inputDispatched(_ event: NucleusCompositorOverlayTypes.InputEvent) -> NucleusCompositorOverlayTypes.InputResult
    func notificationFrameActive() -> Bool
    func notificationDeadlineNs() -> UInt64
    func showWindowMenu(windowID: UInt64, x: Double, y: Double, capabilities: UInt32)
    func dismissMenu()
    func menuVisible() -> Bool
    func wantsKeyboard() -> Bool
}

@MainActor
private final class OverlaySceneRuntimeHost: OverlaySceneHost {
    func frameUpdated(_ frame: NucleusCompositorOverlayTypes.FrameInfo) {
        var event = overlayEvent(kind: ShellOverlayEventKind.frame.rawValue)
        event.frame = frame
        submitOverlayEvent(event)
    }

    func notificationAdded(_ notification: NucleusCompositorOverlayTypes.NotificationInfo) {
        var event = overlayEvent(kind: ShellOverlayEventKind.notification.rawValue)
        event.notification = notification
        submitOverlayEvent(event)
    }

    func notificationDismissed(id: UInt32, reason: UInt32) {
        var event = overlayEvent(kind: ShellOverlayEventKind.dismissNotification.rawValue)
        event.notificationId = id
        event.closeReason = reason
        submitOverlayEvent(event)
    }

    func hotkeyVisibilitySet(visible: Bool) {
        var event = overlayEvent(kind: ShellOverlayEventKind.hotkeyVisibility.rawValue)
        event.visible = visible
        submitOverlayEvent(event)
    }

    func inputDispatched(_ event: NucleusCompositorOverlayTypes.InputEvent) -> NucleusCompositorOverlayTypes.InputResult {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return ShellOverlayInputResult.passThrough.abiValue
        }
        return shellOverlayController.dispatchInput(ShellOverlayInputEvent(event)).abiValue
    }

    func notificationFrameActive() -> Bool {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return false
        }
        return shellOverlayController.scene.notificationFrameActive
    }

    func notificationDeadlineNs() -> UInt64 {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return 0
        }
        return shellOverlayController.scene.notificationPublicationDeadlineNs ?? 0
    }

    func showWindowMenu(windowID: UInt64, x: Double, y: Double, capabilities: UInt32) {
        guard let shellOverlayController = ensureShellOverlayController() else {
            logShellOverlayRuntime("dropping window menu for window=\(windowID); scene unavailable")
            return
        }
        let menu = makeWindowMenu(capabilities: capabilities) { verb in
            notifyHostWindowMenuSelected(
                windowID: windowID,
                verb: Int32(verb.rawValue))
        }
        shellOverlayController.showMenu(menu, at: Point(x: x, y: y))
    }

    func dismissMenu() {
        ensureShellOverlayController()?.dismissMenu()
    }

    func menuVisible() -> Bool {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return false
        }
        return shellOverlayController.scene.menuVisible
    }

    func wantsKeyboard() -> Bool {
        guard let shellOverlayController = ensureShellOverlayController() else {
            return false
        }
        return shellOverlayController.scene.wantsKeyboard
    }
}

/// The process-wide overlay-scene runtime host. The reactor boundary installs this
/// same instance as its `OverlaySceneHost` existential; in-process shell
/// services author the overlay scene by calling it directly through the
/// (already ergonomic) protocol surface.
@MainActor
private let overlaySceneRuntimeHost = OverlaySceneRuntimeHost()

/// The process-wide overlay-scene runtime host. The reactor boundary installs this
/// same instance as its `OverlaySceneHost` existential; in-process shell
/// services author the overlay scene by calling it directly through the
/// (already ergonomic) protocol surface.
public enum OverlaySceneRuntime {
    @MainActor public static var shared: any OverlaySceneHost { overlaySceneRuntimeHost }
}

@MainActor public func nucleus_compositor_overlay_scene_menu_visible() -> Bool {
    overlaySceneRuntimeHost.menuVisible()
}

@MainActor public func nucleus_compositor_overlay_scene_wants_keyboard() -> Bool {
    overlaySceneRuntimeHost.wantsKeyboard()
}

@MainActor
public func nucleus_compositor_overlay_scene_update_environment(
    _ environment: UIEnvironment
) {
    ensureShellOverlayController()?.scene.updateEnvironment(environment)
}

@MainActor public func nucleus_compositor_overlay_scene_show_window_menu(
    _ windowID: UInt64,
    _ x: Double,
    _ y: Double,
    _ capabilities: UInt32
) {
    overlaySceneRuntimeHost.showWindowMenu(
        windowID: windowID, x: x, y: y, capabilities: capabilities)
}

@MainActor
private func publishSceneToHost(_ publication: ShellOverlayPublication) {
    Trace.zone("overlay.runtime.publish_to_host", color: Trace.Color.blue) {
        Trace.plot("swift.overlay.runtime.publish_items", UInt64(publication.scene.visualContent.count))
    }
}

@MainActor
private func publishAccessibilityToHost() {
    activePublicationHost?.accessibilitySceneDidPublish()
}

@MainActor
private func notifyHostNotificationClosed(id: UInt32, reason: UInt32) {
    activePublicationHost?.notificationClosed(id: id, reason: reason)
}

@MainActor
private func notifyHostWindowMenuSelected(windowID: UInt64, verb: Int32) {
    activePublicationHost?.windowMenuSelected(windowID: windowID, verb: verb)
}

@MainActor
public func primaryOverlayOutputSize() -> NucleusCompositorOverlayTypes.OutputSize {
    let server = NucleusCompositorServer.shared
    let outputID = server.spaces.overlayDisplayID(layout: server.layout)
    guard let display = server.layout.display(id: outputID) else {
        return .init(width: 0, height: 0, scale: 1)
    }
    return .init(
        width: UInt32(max(1, Int(display.logicalRect.width.rounded(.up)))),
        height: UInt32(max(1, Int(display.logicalRect.height.rounded(.up)))),
        scale: Float(display.fractionalScale)
    )
}

private func logShellOverlayRuntime(_ message: String) {
    let line = "shell-overlay-runtime: \(message)\n"
    line.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }
}
