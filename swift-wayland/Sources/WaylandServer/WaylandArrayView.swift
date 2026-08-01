package import WaylandServerC

/// A read-only, request-scoped view over a Wayland `array` argument.
///
/// The view exposes bytes without exposing `wl_array`. Typed loads reject
/// misaligned sizes instead of silently truncating a malformed wire value.
@MainActor
@safe package struct WaylandArrayView: ~Escapable {
    @unsafe private let array: UnsafeMutablePointer<wl_array>

    @_lifetime(borrow array)
    package init(_ array: UnsafeMutablePointer<wl_array>) {
        unsafe self.array = copy array
    }

    package var byteCount: Int {
        unsafe array.pointee.size
    }

    package var isEmpty: Bool {
        byteCount == 0
    }

    package func withUnsafeBytes<Result: ~Copyable, E: Error>(
        _ body: (UnsafeRawBufferPointer) throws(E) -> Result
    ) throws(E) -> Result {
        let count = byteCount
        if count == 0 {
            return try unsafe body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return try unsafe body(
            UnsafeRawBufferPointer(start: array.pointee.data, count: count))
    }

    package func copiedElements<Element>(
        of _: Element.Type = Element.self
    ) -> [Element]? {
        let stride = MemoryLayout<Element>.stride
        guard stride > 0, byteCount.isMultiple(of: stride) else { return nil }
        return unsafe withUnsafeBytes { bytes in
            guard unsafe !bytes.isEmpty else { return [] }
            return unsafe Array(
                UnsafeBufferPointer(
                    start: bytes.baseAddress!.assumingMemoryBound(to: Element.self),
                    count: bytes.count / stride))
        }
    }
}
