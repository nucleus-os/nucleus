// The ext-session-lock security-gate driver: bridges the protocol object to the
// Swift compositor gate (`SessionLockGate`).
//
// The gate itself — the `active` flag, the per-output "has a locked frame been
// presented" tracking that times the `locked` event, and the presentation/input
// block predicates the renderer and input dispatch read — is compositor-core
// security state, not protocol state, and a bug there is a lock-screen bypass.
// The driver only arms/disarms it as the protocol object reports lock/unlock; the
// protocol object owns whether a lock is granted (it rejects a second concurrent
// lock before calling begin).
//
// Isolation: the protocol object invokes these from nonisolated @convention(c)
// request handlers on the compositor's single (main-actor) thread, so each method
// is nonisolated and re-enters the actor with MainActor.assumeIsolated.

import WaylandServerC

@MainActor
final class RouterSessionLockDriver {
    init() {}
}

extension RouterSessionLockDriver: SessionLockDelegate {
    /// `lock`: arm the gate. The protocol object has already rejected a second
    /// concurrent lock (currentLock != nil), so arming always succeeds here; the
    /// gate is idempotent (re-arm is the lock-client recovery path).
    nonisolated func sessionLockBegin() -> Bool {
        MainActor.assumeIsolated { SessionLockGate.begin() }
        return true
    }

    /// `unlock_and_destroy` (or a pre-`locked` `destroy`): disarm the gate.
    nonisolated func sessionLockEnd() {
        MainActor.assumeIsolated { SessionLockGate.end() }
    }

    /// A lock surface mapped. The router owns the protocol surface and crosses
    /// only its wire id; the Swift gate resolves lock ownership through the
    /// router model, focuses the first lock surface, and schedules the locked
    /// frame.
    nonisolated func sessionLockSurfaceMapped(_ surface: WlSurface, output _: WlOutput?) {
        let surfaceId = UInt64(surface.objectId)
        MainActor.assumeIsolated { SessionLockGate.surfaceMapped(surfaceID: surfaceId) }
    }
}
