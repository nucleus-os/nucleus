// Stable client-side runtime types used by generated listener dispatch.

package import WaylandClientC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Safe, immutable metadata for one generated client interface.
///
/// The native `wl_interface` pointer is package-private and process-lifetime.
/// Consumers get the wire name without importing or manipulating libwayland
/// metadata directly.
@safe package struct WaylandClientInterfaceDescriptor: Sendable {
    package let wireName: String
    private let nativeInterfaceAddress: UInt

    @unsafe package var nativeInterface: UnsafePointer<wl_interface> {
        unsafe UnsafePointer<wl_interface>(
            bitPattern: nativeInterfaceAddress)!
    }

    @unsafe package init(
        nativeInterface: UnsafePointer<wl_interface>?
    ) {
        unsafe precondition(
            nativeInterface != nil,
            "generated Wayland interface is missing")
        unsafe nativeInterfaceAddress = UInt(bitPattern: nativeInterface!)
        unsafe wireName = String(cString: nativeInterface!.pointee.name)
    }
}

/// Metadata implemented by each generated client interface type.
///
/// Client descriptors are distinct from server descriptors so native object
/// identities cannot cross protocol roles accidentally.
package protocol WaylandClientInterface {
    static var descriptor: WaylandClientInterfaceDescriptor { get }
    static var maximumVersion: UInt32 { get }
}

package enum WaylandProxyError: Error, Equatable {
    case destroyed
    case listenerAlreadyInstalled
    case listenerInstallationFailed(Int32)
    case unsupportedVersion(required: UInt32, actual: UInt32)
    case proxyCreationFailed
}

/// Owns the native display lifetime shared by a connection and all of its
/// proxies. The display disconnects only after the connection and every proxy
/// created from it have been released.
@safe package final class WaylandClientConnectionLifetime {
    @unsafe package let display: OpaquePointer

    @unsafe package init(adopting display: OpaquePointer) {
        unsafe self.display = display
    }

    deinit {
        unsafe wl_display_disconnect(display)
    }
}

/// Retained userdata installed on one native proxy.
///
/// Libwayland borrows the userdata pointer. `WaylandProxy` owns this context
/// until it destroys or invalidates the native proxy, keeping both the event
/// handler and display connection alive for every callback.
@safe final class WaylandClientListenerContext {
    weak var owner: AnyObject?
    let connectionLifetime: WaylandClientConnectionLifetime

    init(
        owner: AnyObject,
        connectionLifetime: WaylandClientConnectionLifetime
    ) {
        self.owner = owner
        self.connectionLifetime = connectionLifetime
    }

    @unsafe static func recover(
        _ pointer: UnsafeMutableRawPointer
    ) -> WaylandClientListenerContext {
        unsafe Unmanaged<WaylandClientListenerContext>
            .fromOpaque(pointer)
            .takeUnretainedValue()
    }
}

/// An owned, interface-typed Wayland client proxy.
///
/// The native pointer stays private. Generated requests and listeners use
/// package-scoped access; platform integrations can use
/// `withUnsafeNativeProxy` at an explicit unsafe boundary.
@MainActor
@safe
package final class WaylandProxy<
    Interface: WaylandClientInterface
> {
    @unsafe private var nativeProxy: OpaquePointer?
    private let connectionLifetime: WaylandClientConnectionLifetime
    private let destroysNativeProxyLocally: Bool
    private var listenerContext: WaylandClientListenerContext?
    package let version: UInt32
    /// Stable native object identity for routing and dictionary keys.
    ///
    /// This is an identifier only; it cannot be converted back into a usable
    /// proxy through the safe API.
    package let identity: UInt

    @unsafe package init(
        adopting nativeProxy: OpaquePointer,
        connectionLifetime: WaylandClientConnectionLifetime,
        destroysNativeProxyLocally: Bool = true
    ) {
        unsafe self.nativeProxy = nativeProxy
        self.connectionLifetime = connectionLifetime
        self.destroysNativeProxyLocally = destroysNativeProxyLocally
        unsafe version = wl_proxy_get_version(nativeProxy)
        identity = UInt(bitPattern: nativeProxy)
    }

    package var isLive: Bool {
        unsafe nativeProxy != nil
    }

    /// Destroy only the local libwayland proxy. This never sends a protocol
    /// destructor request.
    package func destroyLocally() throws(WaylandProxyError) {
        guard let proxy = unsafe takeNativeProxy() else {
            throw .destroyed
        }
        if destroysNativeProxyLocally {
            unsafe wl_proxy_destroy(proxy)
        }
        listenerContext = nil
    }

    /// Gives a native integration temporary access to the live proxy.
    ///
    /// The pointer must not be retained beyond `body`.
    @unsafe
    package func withUnsafeNativeProxy<
        Result: ~Copyable,
        Failure: Error
    >(
        _ body: (OpaquePointer) throws(Failure) -> Result
    ) throws -> Result {
        guard let proxy = unsafe nativeProxy else {
            throw WaylandProxyError.destroyed
        }
        return try unsafe body(proxy)
    }

    @unsafe func installListener(
        owner: AnyObject,
        _ install: (
            OpaquePointer,
            UnsafeMutableRawPointer
        ) -> Int32
    ) throws(WaylandProxyError) {
        guard listenerContext == nil else {
            throw .listenerAlreadyInstalled
        }
        guard let proxy = unsafe nativeProxy else {
            throw .destroyed
        }
        let context = WaylandClientListenerContext(
            owner: owner,
            connectionLifetime: connectionLifetime)
        listenerContext = context
        let result = unsafe install(
            proxy,
            Unmanaged.passUnretained(context).toOpaque())
        guard result == 0 else {
            listenerContext = nil
            throw .listenerInstallationFailed(result)
        }
    }

    @unsafe
    func makeOwnedProxy<
        Child: WaylandClientInterface
    >(
        adopting proxy: OpaquePointer,
        _: Child.Type
    ) -> WaylandProxy<Child> {
        unsafe WaylandProxy<Child>(
            adopting: proxy,
            connectionLifetime: connectionLifetime)
    }

    @unsafe package func requireNativeProxy()
        throws(WaylandProxyError) -> OpaquePointer
    {
        guard let nativeProxy = unsafe nativeProxy else {
            throw .destroyed
        }
        return unsafe nativeProxy
    }

    /// Marks a proxy consumed by a generated protocol destructor. The generated
    /// C request already released the native proxy through
    /// `WL_MARSHAL_FLAG_DESTROY`.
    @unsafe package func invalidateAfterProtocolDestructor()
        throws(WaylandProxyError)
    {
        guard unsafe takeNativeProxy() != nil else {
            throw .destroyed
        }
        listenerContext = nil
    }

    @unsafe private func takeNativeProxy() -> OpaquePointer? {
        defer { unsafe nativeProxy = nil }
        return unsafe nativeProxy
    }

    isolated deinit {
        if let proxy = unsafe takeNativeProxy() {
            if destroysNativeProxyLocally {
                unsafe wl_proxy_destroy(proxy)
            }
        }
        listenerContext = nil
    }
}

/// A typed proxy view that cannot escape its synchronous listener callback.
@safe
package struct WaylandBorrowedProxy<
    Interface: WaylandClientInterface
>: ~Escapable {
    @unsafe package let proxy: OpaquePointer

    @_lifetime(borrow proxy)
    package init(_ proxy: OpaquePointer) {
        unsafe self.proxy = copy proxy
    }

    package var version: UInt32 {
        unsafe wl_proxy_get_version(proxy)
    }

    package var identity: UInt {
        unsafe UInt(bitPattern: proxy)
    }
}

/// A read-only array view that cannot outlive its listener callback.
@safe package struct WaylandClientArrayView: ~Escapable {
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
            return try unsafe body(
                UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return try unsafe body(
            UnsafeRawBufferPointer(
                start: array.pointee.data, count: count))
    }

    package func copiedElements<Element>(
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

/// Owned bytes marshalled as one Wayland request `array` argument.
@safe package struct WaylandClientArrayArgument {
    private let bytes: [UInt8]

    package init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    @unsafe
    package func withNativeArray<
        Result: ~Copyable,
        Failure: Error
    >(
        _ body: (
            UnsafeMutablePointer<wl_array>
        ) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        var array = unsafe wl_array()
        unsafe wl_array_init(&array)
        defer { unsafe wl_array_release(&array) }
        if !bytes.isEmpty {
            guard
                let destination = unsafe wl_array_add(
                    &array,
                    bytes.count)
            else {
                preconditionFailure(
                    "wl_array allocation failed while marshalling a request")
            }
            bytes.withUnsafeBytes {
                unsafe destination.copyMemory(
                    from: $0.baseAddress!,
                    byteCount: $0.count)
            }
        }
        return try unsafe body(&array)
    }
}

/// Move-only ownership of a file descriptor transferred by a client event.
@safe package struct WaylandClientOwnedFileDescriptor: ~Copyable {
    private var descriptor: Int32

    package init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    package var rawValue: Int32 {
        descriptor
    }

    package consuming func take() -> Int32 {
        let result = descriptor
        descriptor = -1
        return result
    }

    package static func closeTransferred(_ descriptor: Int32) {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }
}
