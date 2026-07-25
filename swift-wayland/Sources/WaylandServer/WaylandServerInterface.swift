public import WaylandServerC

/// Generated, policy-free metadata for one server-side Wayland interface.
///
/// The descriptor type is also the phantom type carried by typed resources. Its
/// native pointers are process-lifetime protocol metadata emitted by
/// wayland-scanner, not resource instances.
@unsafe
public protocol WaylandServerInterface {
    static var interface: UnsafePointer<wl_interface>? { get }
    static var maximumVersion: Int32 { get }
    static func requestVtable() -> UnsafeRawPointer?
}
