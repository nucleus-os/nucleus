#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A heap buffer that is zeroed when it is released.
///
/// Exists because a Swift `String` cannot be scrubbed. Its storage is
/// copy-on-write, small values live inline in the struct, and the compiler is
/// free to copy it anywhere; there is no handle to the bytes that can be
/// overwritten with any guarantee. For a credential that is the difference
/// between "cleared" and "cleared as far as anyone bothered to check".
///
/// A reference type on purpose: the buffer has one owner and one address for its
/// whole life, so `deinit` scrubs the same bytes that were written. Copying the
/// value copies the reference, not the secret.
public final class SecureBytes {
    private var storage: UnsafeMutableRawBufferPointer

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.count == 0 }

    public init(count: Int) {
        storage = .allocate(byteCount: max(0, count), alignment: 1)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// Copy `string`'s UTF-8 into a scrubable buffer.
    ///
    /// The `String` this came from is *not* scrubbed — it cannot be. Callers
    /// holding a credential in a `String` should treat this as the point after
    /// which the byte copy is the authoritative one, and drop the string.
    public convenience init(utf8 string: String) {
        let utf8 = Array(string.utf8)
        self.init(count: utf8.count)
        utf8.withUnsafeBytes { source in
            if let base = source.baseAddress, source.count > 0 {
                storage.baseAddress?.copyMemory(from: base, byteCount: source.count)
            }
        }
    }

    public init(_ bytes: [UInt8]) {
        storage = .allocate(byteCount: bytes.count, alignment: 1)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress, source.count > 0 {
                storage.baseAddress?.copyMemory(from: base, byteCount: source.count)
            }
        }
    }

    deinit {
        SecureBytes.scrub(storage)
        storage.deallocate()
    }

    /// Borrow the bytes. The pointer must not outlive the call — nothing else
    /// can promise the memory stays scrubable.
    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawBufferPointer(storage))
    }

    public func withUnsafeMutableBytes<T>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        try body(storage)
    }

    /// Zero the contents now rather than waiting for release.
    public func scrub() {
        SecureBytes.scrub(storage)
    }

    /// Overwrite `buffer` in a way the optimizer will not remove.
    ///
    /// A plain loop or `memset` on memory that is about to be freed is a dead
    /// store, and the compiler may legally drop it — which is precisely how
    /// scrubbing code silently stops working. `explicit_bzero` exists for this
    /// and is guaranteed not to be elided.
    private static func scrub(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        #if canImport(Glibc)
        explicit_bzero(base, buffer.count)
        #else
        memset_s(base, buffer.count, 0, buffer.count)
        #endif
    }
}
