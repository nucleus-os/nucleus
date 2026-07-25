// Stable client-side runtime types used by generated listener dispatch.

public import WaylandClientC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Metadata implemented by each generated client interface descriptor.
///
/// Client descriptors are distinct from server descriptors so native object
/// identities cannot cross protocol roles accidentally.
public protocol WaylandClientInterface {
    static var interface: UnsafePointer<wl_interface>? { get }
    static var maximumVersion: UInt32 { get }
}

/// A typed proxy view that cannot escape its synchronous listener callback.
@safe public struct WaylandBorrowedProxy<
    Interface: WaylandClientInterface
>: ~Escapable {
    @unsafe public let proxy: OpaquePointer

    @_lifetime(borrow proxy)
    public init(_ proxy: OpaquePointer) {
        unsafe self.proxy = copy proxy
    }

    public var version: UInt32 {
        unsafe wl_proxy_get_version(proxy)
    }
}

/// A read-only array view that cannot outlive its listener callback.
@safe public struct WaylandClientArrayView: ~Escapable {
    @unsafe private let array: UnsafeMutablePointer<wl_array>

    @_lifetime(borrow array)
    public init(_ array: UnsafeMutablePointer<wl_array>) {
        unsafe self.array = copy array
    }

    public var byteCount: Int {
        unsafe array.pointee.size
    }

    public var isEmpty: Bool {
        byteCount == 0
    }

    public func withUnsafeBytes<Result: ~Copyable, E: Error>(
        _ body: (UnsafeRawBufferPointer) throws(E) -> Result
    ) throws(E) -> Result {
        let count = byteCount
        if count == 0 {
            return try unsafe body(
                UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return try unsafe body(
            UnsafeRawBufferPointer(
                start: array.pointee.data, count: count))
    }

    public func copiedElements<Element>(
        of _: Element.Type = Element.self
    ) -> [Element]? {
        let stride = MemoryLayout<Element>.stride
        guard stride > 0,
              byteCount.isMultiple(of: stride)
        else { return nil }
        return unsafe withUnsafeBytes { bytes in
            guard unsafe !bytes.isEmpty else { return [] }
            return unsafe Array(
                UnsafeBufferPointer(
                    start: bytes.baseAddress!.assumingMemoryBound(
                        to: Element.self),
                    count: bytes.count / stride))
        }
    }
}

/// Move-only ownership of a file descriptor transferred by a client event.
@safe public struct WaylandClientOwnedFileDescriptor: ~Copyable {
    private var descriptor: Int32

    public init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    public var rawValue: Int32 {
        descriptor
    }

    public consuming func take() -> Int32 {
        let result = descriptor
        descriptor = -1
        return result
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }
}
