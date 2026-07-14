import NucleusCompositorOverlayScene
import NucleusCompositorServer

/// The shell's conformer to the overlay runtime's publication host.
///
/// The overlay runtime (`NucleusCompositorOverlayScene`, below the shell in the area DAG)
/// calls back into the shell for the events it cannot resolve itself: a
/// notification closed from the overlay and a window-menu verb. The shell installs
/// this conformer into the overlay runtime at bring-up. Both ends are Swift, so the
/// calls land on `NotificationService` / the input host directly.
@MainActor
final class ShellOverlayPublicationHost: OverlayPublicationHost {
    func notificationClosed(id: UInt32, reason: UInt32) {
        NotificationService.shared.notificationClosedFromOverlay(id: id, reason: reason)
        SystemdBus.shared.notificationClosed(id: id, reason: reason)
    }

    func windowMenuSelected(windowID: UInt64, verb: Int32) {
        NucleusCompositorServer.shared.inputControl?.windowMenuSelected(windowID: windowID, verb: verb)
    }
}

/// Install the shell's overlay publication host into the overlay runtime. Returns
/// 0 if the overlay scene failed to construct. A fresh stateless conformer is
/// handed over per install (the `sending` boundary consumes it).
@MainActor public func nucleus_shell_overlay_publication_install() -> UInt8 {
    nucleus_compositor_overlay_runtime_install_host(ShellOverlayPublicationHost())
}

@MainActor public func nucleus_shell_overlay_publication_clear() {
    _ = nucleus_compositor_overlay_runtime_clear_host()
}
