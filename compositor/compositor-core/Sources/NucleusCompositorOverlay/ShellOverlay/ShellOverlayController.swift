@_spi(NucleusCompositor) import NucleusUI
import Tracy

@MainActor
package final class ShellOverlayController: ~Sendable {
    package let scene: ShellOverlayScene
    private let scenePublisher: @MainActor (ShellOverlayPublication) -> Void
    private var lastPublication: ShellOverlayPublication?

    package init(
        scene: ShellOverlayScene,
        scenePublisher: @escaping @MainActor (ShellOverlayPublication) -> Void
    ) {
        self.scene = scene
        self.scenePublisher = scenePublisher
    }

    package func submit(event: ShellOverlayEvent) {
        Trace.zone("overlay.controller.submit", color: Trace.Color.blue) {
            if scene.submit(event: event) {
                publishScene()
            }
        }
    }

    package func dispatchInput(_ event: ShellOverlayInputEvent) -> ShellOverlayInputResult {
        let result = scene.dispatchInput(event)
        if result.wantsFrame {
            publishScene()
        }
        return result
    }

    package func beginFrame(_ frame: ShellOverlayFrameInfo) {
        Trace.zone("overlay.controller.begin_frame", color: Trace.Color.blue) {
            if scene.beginFrame(frame) {
                publishScene()
            }
        }
    }

    package func showNotification(_ notification: ShellOverlayNotificationInfo) {
        Trace.zone("overlay.notification.show", color: Trace.Color.green) {
            if scene.showNotification(notification) {
                publishScene()
            }
        }
    }

    package func dismissNotification(_ id: UInt32) {
        Trace.zone("overlay.notification.dismiss", color: Trace.Color.yellow) {
            if scene.dismissNotification(id) {
                publishScene()
            }
        }
    }

    package func setHotkeyVisible(_ visible: Bool) {
        if scene.setHotkeyVisible(visible) {
            publishScene()
        }
    }

    package func showMenu(
        _ menu: Menu,
        at anchor: Point,
        onSelect: @escaping @MainActor (Int) -> Void
    ) {
        if scene.showMenu(menu, at: anchor, onSelect: onSelect) {
            publishScene()
        }
    }

    package func dismissMenu() {
        if scene.dismissMenu() {
            publishScene()
        }
    }

    package func publishScene() {
        Trace.zone("overlay.controller.publish_scene", color: Trace.Color.blue) {
            guard let publication = scene.publishVisuals() else {
                return
            }
            guard publication != lastPublication else {
                Trace.plot("swift.overlay.publish.unchanged", UInt64(1))
                return
            }
            lastPublication = publication
            Trace.plot("swift.overlay.publish.visual_items", UInt64(publication.scene.visualContent.count))
            scenePublisher(publication)
        }
    }
}
