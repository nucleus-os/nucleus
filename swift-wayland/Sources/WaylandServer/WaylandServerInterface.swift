import WaylandServerC

/// Safe, immutable metadata for one generated server interface.
///
/// Native scanner metadata and request vtables remain package-private. Public
/// users carry the descriptor type without gaining raw-pointer access.
@safe public struct WaylandServerInterfaceDescriptor: Sendable {
    public let wireName: String
    private let nativeInterfaceAddress: UInt
    private let nativeRequestVtableAddress: UInt?

    @unsafe package var nativeInterface: UnsafePointer<wl_interface> {
        unsafe UnsafePointer<wl_interface>(
            bitPattern: nativeInterfaceAddress)!
    }

    @unsafe package var nativeRequestVtable: UnsafeRawPointer? {
        guard let nativeRequestVtableAddress else { return nil }
        return unsafe UnsafeRawPointer(bitPattern: nativeRequestVtableAddress)
    }

    @unsafe package init(
        nativeInterface: UnsafePointer<wl_interface>?,
        nativeRequestVtable: UnsafeRawPointer?
    ) {
        unsafe precondition(
            nativeInterface != nil,
            "generated Wayland interface is missing")
        unsafe nativeInterfaceAddress = UInt(bitPattern: nativeInterface!)
        unsafe nativeRequestVtableAddress = nativeRequestVtable.map {
            UInt(bitPattern: $0)
        }
        unsafe wireName = String(cString: nativeInterface!.pointee.name)
    }
}

/// Generated, policy-free metadata for one server-side Wayland interface.
///
/// The descriptor type is also the phantom type carried by typed resources. Its
/// native pointers are process-lifetime protocol metadata emitted by
/// wayland-scanner, not resource instances.
public protocol WaylandServerInterface {
    static var descriptor: WaylandServerInterfaceDescriptor { get }
    static var maximumVersion: Int32 { get }
}
