import NucleusBlockingSynchronizationC

/// Heap-stable pthread mutex/condition ownership for blocking worker loops.
///
/// Swift stores only this reference and an opaque pointer. The pthread objects
/// themselves never live in movable Swift storage.
final class BlockingSynchronization: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = nucleus_blocking_synchronization_create() else {
            preconditionFailure(
                "failed to create blocking synchronization state")
        }
        self.handle = handle
    }

    deinit {
        nucleus_blocking_synchronization_destroy(handle)
    }

    @inline(__always)
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }

    @inline(__always)
    func lock() {
        precondition(
            nucleus_blocking_synchronization_lock(handle) == 0,
            "failed to lock blocking synchronization state")
    }

    @inline(__always)
    func wait() {
        precondition(
            nucleus_blocking_synchronization_wait(handle) == 0,
            "failed to wait on blocking synchronization state")
    }

    @inline(__always)
    func signal() {
        precondition(
            nucleus_blocking_synchronization_signal(handle) == 0,
            "failed to signal blocking synchronization state")
    }

    @inline(__always)
    func broadcast() {
        precondition(
            nucleus_blocking_synchronization_broadcast(handle) == 0,
            "failed to broadcast blocking synchronization state")
    }

    @inline(__always)
    func unlock() {
        precondition(
            nucleus_blocking_synchronization_unlock(handle) == 0,
            "failed to unlock blocking synchronization state")
    }
}
