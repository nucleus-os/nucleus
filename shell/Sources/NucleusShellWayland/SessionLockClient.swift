// The ext-session-lock client — the lock-screen role. Skeleton for the bar vertical slice:
// the shape (bind the manager, lock, per-output lock surfaces, unlock) is complete; the
// per-output surface creation reuses the same wl_surface + render-backend path as the bar,
// so fleshing it out is additive when the lock UI lands.
//
// Security note: the compositor is the fail-closed authority (an unresponsive locker keeps
// the session blocked); this client merely presents the lock UI and requests unlock.

import WaylandClientC
import WaylandClientDispatch

@MainActor
public final class SessionLockClient {
    private let manager: OpaquePointer
    private weak var client: ShellWaylandClient?
    private var lock: OpaquePointer?

    /// Fired when the compositor confirms the session is locked (all outputs blanked). The
    /// host then creates a lock surface per output and presents the lock UI.
    public var onLocked: (() -> Void)?
    /// Fired if the lock request is refused (another client already holds the lock).
    public var onFinished: (() -> Void)?

    public init?(client: ShellWaylandClient) {
        guard let manager = client.proxy(.sessionLock) else { return nil }
        self.manager = manager
        self.client = client
    }

    /// Request the session lock. On `onLocked`, present per-output lock surfaces.
    public func lockSession() {
        guard let lock = ext_session_lock_manager_v1_lock(manager) else { return }
        self.lock = lock
        ExtSessionLockV1Client.addListener(lock, owner: self)
    }

    /// Create the lock surface for one output (assigns the lock role to a fresh wl_surface).
    /// Returns the wl_surface for the render backend to present onto. Skeleton: the caller
    /// wires the returned surface into the render backend exactly like a LayerSurface.
    public func lockSurface(for output: WaylandOutput) -> OpaquePointer? {
        guard let lock, let surface = client?.createSurface() else { return nil }
        return ext_session_lock_v1_get_lock_surface(lock, surface, output.proxy)
    }

    /// Release the lock (after successful authentication).
    public func unlockAndDestroy() {
        guard let lock else { return }
        ext_session_lock_v1_unlock_and_destroy(lock)
        self.lock = nil
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland callback); the shell
// pumps wl_display on its main-thread event loop, so each handler reasserts the main actor.
extension SessionLockClient: ExtSessionLockV1Events {
    public nonisolated func locked(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated { onLocked?() }
    }
    public nonisolated func finished(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated { onFinished?() }
    }
}
