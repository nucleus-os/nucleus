// The ext-session-lock client — the lock-screen role: bind the manager, request
// the lock, create one lock surface per output, unlock after authentication.
//
// Security note: the compositor is the fail-closed authority (an unresponsive locker keeps
// the session blocked); this client merely presents the lock UI and requests unlock.

import WaylandClientC
public import WaylandClientDispatch

@MainActor
public final class SessionLockClient {
    private let manager: OpaquePointer
    private weak var client: ShellWaylandClient?
    private var lock: OpaquePointer?
    private var lockConfirmed = false

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

    /// Create the lock surface for one output. Returns nil before the lock is
    /// confirmed — the protocol only permits lock surfaces on a held lock.
    public func lockSurface(for output: WaylandOutput) -> SessionLockSurface? {
        guard let lock, let client else { return nil }
        return SessionLockSurface(lock: lock, client: client, output: output)
    }

    /// Whether the compositor has confirmed the lock. Until it does, the session
    /// is not yet secure and no lock surface may be created.
    public var isLocked: Bool { lock != nil && lockConfirmed }

    /// Release the lock (after successful authentication).
    /// Release the lock after successful authentication. Refuses unless the
    /// compositor confirmed the lock: unlocking a lock that was never held is a
    /// protocol error, and silently doing nothing is safer than a crash that
    /// would strand the session.
    public func unlockAndDestroy() {
        guard let lock, lockConfirmed else { return }
        ext_session_lock_v1_unlock_and_destroy(lock)
        self.lock = nil
        lockConfirmed = false
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland callback); the shell
// pumps wl_display on its main-thread event loop, so each handler reasserts the main actor.
extension SessionLockClient: ExtSessionLockV1Events {
    public nonisolated func locked(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated {
            lockConfirmed = true
            onLocked?()
        }
    }

    /// The compositor refused or revoked the lock. The protocol forbids touching
    /// the lock object further, so it is dropped without `unlock_and_destroy` —
    /// calling that on a finished lock is a protocol error.
    public nonisolated func finished(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated {
            lockConfirmed = false
            lock = nil
            onFinished?()
        }
    }
}
