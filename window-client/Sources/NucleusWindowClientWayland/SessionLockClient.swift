// The ext-session-lock client — the lock-screen role: bind the manager, request
// the lock, create one lock surface per output, unlock after authentication.
//
// Security note: the compositor is the fail-closed authority (an unresponsive locker keeps
// the session blocked); this client merely presents the lock UI and requests unlock.

package import WaylandClientDispatch

@MainActor
@safe public final class NucleusDesktopSessionLock {
    private let manager:
        WaylandProxy<ExtSessionLockManagerV1Client>
    private weak var client: NucleusDesktopConnection?
    private var lock: WaylandProxy<ExtSessionLockV1Client>?
    private var lockConfirmed = false

    /// Fired when the compositor confirms the session is locked (all outputs blanked). The
    /// host then creates a lock surface per output and presents the lock UI.
    package var onLocked: (() -> Void)?
    /// Fired if the lock request is refused (another client already holds the lock).
    package var onFinished: (() -> Void)?

    package init?(client: NucleusDesktopConnection) {
        guard let manager = client.sessionLock else { return nil }
        self.manager = manager
        self.client = client
    }

    /// Request the session lock. On `onLocked`, present per-output lock surfaces.
    package func lockSession() {
        guard let lock = try? manager.lock() else {
            return
        }
        self.lock = lock
        try? lock.installListener(self)
    }

    /// Create the lock surface for one output. Returns nil before the lock is
    /// confirmed — the protocol only permits lock surfaces on a held lock.
    package func lockSurface(for output: NucleusDesktopOutput) -> NucleusDesktopSessionLockSurface? {
        guard let lock, let client else { return nil }
        return NucleusDesktopSessionLockSurface(
            lock: lock, client: client, output: output)
    }

    /// Whether the compositor has confirmed the lock. Until it does, the session
    /// is not yet secure and no lock surface may be created.
    package var isLocked: Bool { lock != nil && lockConfirmed }

    /// Release the lock (after successful authentication).
    /// Release the lock after successful authentication. Refuses unless the
    /// compositor confirmed the lock: unlocking a lock that was never held is a
    /// protocol error, and silently doing nothing is safer than a crash that
    /// would strand the session.
    package func unlockAndDestroy() {
        guard let lock, lockConfirmed else { return }
        try? lock.unlockAndDestroy()
        self.lock = nil
        lockConfirmed = false
    }
}

extension NucleusDesktopSessionLock: ExtSessionLockV1Events {
    package func locked(_ proxy: WaylandBorrowedProxy<ExtSessionLockV1Client>) {
        lockConfirmed = true
        onLocked?()
    }

    /// The compositor refused or revoked the lock. The protocol forbids touching
    /// the lock object further, so it is dropped without `unlock_and_destroy` —
    /// calling that on a finished lock is a protocol error.
    package func finished(_ proxy: WaylandBorrowedProxy<ExtSessionLockV1Client>) {
        lockConfirmed = false
        lock = nil
        onFinished?()
    }
}
