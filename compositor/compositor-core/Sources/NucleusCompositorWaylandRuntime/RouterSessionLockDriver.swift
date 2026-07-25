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
// Generated request dispatch enters the main actor before the protocol object calls
// this typed policy seam.

import WaylandServerC

@MainActor
final class RouterSessionLockDriver {
    private unowned let gate: SessionLockGate

    init(gate: SessionLockGate) {
        self.gate = gate
    }
}

extension RouterSessionLockDriver: SessionLockDelegate {
    /// `lock`: arm the gate. The protocol object has already rejected a second
    /// concurrent lock (currentLock != nil), so arming always succeeds here; the
    /// gate is idempotent (re-arm is the lock-client recovery path).
    func sessionLockBegin() -> Bool {
        gate.begin()
        return true
    }

    /// `unlock_and_destroy` (or a pre-`locked` `destroy`): disarm the gate.
    func sessionLockEnd() {
        gate.end()
    }

    /// A lock surface mapped. The router owns the protocol surface and crosses
    /// only its wire id; the Swift gate resolves lock ownership through the
    /// router model, focuses the first lock surface, and schedules the locked
    /// frame.
    func sessionLockSurfaceMapped(_ surface: WlSurface, output _: WlOutput?) {
        let surfaceId = UInt64(surface.objectId)
        gate.surfaceMapped(surfaceID: surfaceId)
    }
}
