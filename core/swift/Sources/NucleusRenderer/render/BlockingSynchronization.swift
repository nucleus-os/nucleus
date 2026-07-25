import NucleusBlockingSynchronizationC

/// Heap-stable pthread mutex/condition ownership for blocking worker loops.
///
/// Swift stores only this reference and an opaque pointer. The pthread objects
/// themselves never live in movable Swift storage. The C shim owns the pointer
/// until `deinit`; its mutex serializes all cross-thread access.
@safe final class BlockingSynchronization: @unchecked Sendable {
    private let handle: OpaquePointer

    init() {
        guard let handle = unsafe nucleus_blocking_synchronization_create() else {
            preconditionFailure(
                "failed to create blocking synchronization state")
        }
        unsafe self.handle = handle
    }

    deinit {
        unsafe nucleus_blocking_synchronization_destroy(handle)
    }

    @inline(__always)
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }

    @inline(__always)
    func lock() {
        let result = unsafe nucleus_blocking_synchronization_lock(handle)
        precondition(
            result == 0,
            "failed to lock blocking synchronization state")
    }

    @inline(__always)
    func wait() {
        let result = unsafe nucleus_blocking_synchronization_wait(handle)
        precondition(
            result == 0,
            "failed to wait on blocking synchronization state")
    }

    @inline(__always)
    func signal() {
        let result = unsafe nucleus_blocking_synchronization_signal(handle)
        precondition(
            result == 0,
            "failed to signal blocking synchronization state")
    }

    @inline(__always)
    func broadcast() {
        let result = unsafe nucleus_blocking_synchronization_broadcast(handle)
        precondition(
            result == 0,
            "failed to broadcast blocking synchronization state")
    }

    @inline(__always)
    func unlock() {
        let result = unsafe nucleus_blocking_synchronization_unlock(handle)
        precondition(
            result == 0,
            "failed to unlock blocking synchronization state")
    }
}
