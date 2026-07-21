import NucleusCompositorOverlayScene
import NucleusCompositorServer
import NucleusUI

/// The shell's conformer to the overlay runtime's publication host.
///
/// The overlay runtime (`NucleusCompositorOverlayScene`, below the shell in the area DAG)
/// calls back into the shell for the events it cannot resolve itself: a
/// notification closed from the overlay and a window-menu verb. The shell installs
/// this conformer into the overlay runtime at bring-up. Both ends are Swift, so the
/// calls land on `NotificationService` / the input host directly.
@MainActor
final class ShellOverlayPublicationHost: OverlayPublicationHost {
    private unowned let services: ShellServices
    private unowned let notifications: NotificationService
    private unowned let server: NucleusCompositorServer

    init(
        services: ShellServices,
        notifications: NotificationService,
        server: NucleusCompositorServer
    ) {
        self.services = services
        self.notifications = notifications
        self.server = server
    }

    func notificationClosed(id: UInt32, reason: UInt32) {
        notifications.notificationClosedFromOverlay(id: id, reason: reason)
    }

    func accessibilitySceneDidPublish() {
        services.publishAccessibility()
    }

    func windowMenuSelected(windowID: UInt64, verb: Int32) {
        server.inputControl?.windowMenuSelected(windowID: windowID, verb: verb)
    }
}
