#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

/// A uniquely owned heap buffer that is zeroed before its allocation is released.
///
/// Swift `String` storage cannot be scrubbed: it is copy-on-write, small values can
/// live inline, and the compiler may create copies. A credential therefore leaves
/// text storage through this type and has one statically enforced owner thereafter.
/// Moving `SecureBytes` transfers that allocation; copying it is not permitted.
///
/// The unsafe implementation has four invariants:
///
/// - `storage.count` is the requested nonnegative capacity for the owner's lifetime.
/// - A nonempty `storage` has an allocation of exactly `storage.count` initialized bytes.
/// - No pointer to `storage` escapes a `withUnsafe*Bytes` call.
/// - `deinit` performs a non-elidable zeroization before releasing the allocation.
@safe
public struct SecureBytes: ~Copyable {
    private var storage: UnsafeMutableRawBufferPointer
    private let byteCount: Int
    private let lifecycleObserver: SecureBytesLifecycleObserver?

    public var count: Int { byteCount }
    public var isEmpty: Bool { byteCount == 0 }

    public init(count: Int) {
        self.init(count: count, lifecycleObserver: nil)
    }

    internal init(
        count: Int,
        lifecycleObserver: SecureBytesLifecycleObserver?
    ) {
        precondition(count >= 0, "SecureBytes capacity must be nonnegative")
        byteCount = count
        if count == 0 {
            unsafe storage = UnsafeMutableRawBufferPointer(_empty: ())
        } else {
            unsafe storage = UnsafeMutableRawBufferPointer.allocate(
                byteCount: count, alignment: 1)
            unsafe storage.initializeMemory(as: UInt8.self, repeating: 0)
        }
        self.lifecycleObserver = lifecycleObserver
        lifecycleObserver?.didAllocate(count)
    }

    /// Copy `string`'s UTF-8 into scrubable storage.
    ///
    /// The source `String` itself cannot be scrubbed. Callers must drop it once this
    /// value becomes authoritative. The copy is written directly from the UTF-8 view;
    /// no intermediate byte array creates another heap-resident credential.
    public init(utf8 string: String) {
        self.init(count: string.utf8.count)
        var index = 0
        for byte in string.utf8 {
            unsafe storage[index] = byte
            index += 1
        }
    }

    public init(_ bytes: [UInt8]) {
        self.init(count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            unsafe storage[index] = byte
        }
    }

    deinit {
        scrubStorage()
        guard byteCount > 0 else { return }
        unsafe storage.deallocate()
        lifecycleObserver?.didDeallocate()
    }

    /// Borrow the allocation for an operation that genuinely requires a pointer.
    ///
    /// The declaration is unsafe because the closure must not let the pointer escape,
    /// change its binding, deinitialize bytes, or access it concurrently. Prefer a
    /// boundary-specific operation that consumes `SecureBytes` when one exists.
    @unsafe
    public borrowing func withUnsafeBytes<T>(
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        try unsafe body(UnsafeRawBufferPointer(storage))
    }

    /// Mutably borrow the allocation for a genuine pointer boundary.
    ///
    /// In addition to the read-borrow rules, the closure must leave every byte
    /// initialized before returning.
    @unsafe
    public mutating func withUnsafeMutableBytes<T>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        try unsafe body(storage)
    }

    /// Zero the contents now while retaining the initialized allocation.
    public borrowing func scrub() {
        scrubStorage()
    }

    /// `explicit_bzero` and `memset_s` are the audited libc boundary: both promise
    /// that the store cannot be removed even when the allocation is freed next.
    private borrowing func scrubStorage() {
        guard byteCount > 0 else { return }
        let base = unsafe storage.baseAddress!
        #if canImport(Glibc) || canImport(Android)
        unsafe explicit_bzero(base, byteCount)
        #else
        unsafe memset_s(base, byteCount, 0, byteCount)
        #endif

        if let lifecycleObserver {
            var snapshot: [UInt8] = []
            snapshot.reserveCapacity(byteCount)
            for index in 0..<byteCount {
                snapshot.append(unsafe storage[index])
            }
            lifecycleObserver.didScrub(snapshot)
        }
    }
}

/// Per-instance observation for runtime ownership tests. It receives only counts,
/// copied post-scrub bytes, and lifecycle events; raw storage never escapes through
/// the seam and production construction supplies no observer.
internal struct SecureBytesLifecycleObserver {
    var didAllocate: (Int) -> Void = { _ in }
    var didScrub: ([UInt8]) -> Void = { _ in }
    var didDeallocate: () -> Void = {}
}
