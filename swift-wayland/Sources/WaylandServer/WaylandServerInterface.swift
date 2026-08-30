package import WaylandServerC

/// Safe, immutable metadata for one generated server interface.
///
/// Native scanner metadata and request vtables remain package-private. Public
/// users carry the descriptor type without gaining raw-pointer access.
@safe package struct WaylandServerInterfaceDescriptor: Sendable {
    package let wireName: String
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
package protocol WaylandServerInterface {
    associatedtype Requests

    static var descriptor: WaylandServerInterfaceDescriptor { get }
    static var maximumVersion: Int32 { get }
}

/// The one retained object installed as a resource's native user data.
///
/// The semantic owner remains available to ownership queries, while generated
/// request dispatch reads the already-bound handler without repeating a
/// protocol-conformance lookup for every request.
@MainActor
@safe
/// A resource owner that is told when its resource is being destroyed.
///
/// A resource owner's `deinit` runs when the last reference to it goes, which
/// during a teardown cascade can be after objects it points at have already
/// been deinitialized -- so a `deinit` cannot safely reach outward, and any
/// `unowned` reference it reads may already be dead. Destruction of the
/// resource is the event that actually means "this object is going away", and
/// it happens while the graph around it is still whole. An owner with outward
/// work to do does it here, and leaves `deinit` to release what it owns.
package protocol WaylandResourceOwnerLifetime: AnyObject {
    @MainActor func willDestroyResourceOwner()
}

/// Reaches a dispatch box's owner without its interface type, which the
/// resource destructor does not have.
protocol WaylandDispatchBoxOwning: AnyObject {
    var dispatchBoxOwner: AnyObject { get }
}

package final class WaylandDispatchBox<Interface: WaylandServerInterface> {
    package let owner: AnyObject
    package let handler: Interface.Requests?

    package init<Owner: AnyObject>(
        owner: Owner,
        handler: Interface.Requests?
    ) {
        self.owner = owner
        self.handler = handler
    }
}

extension WaylandDispatchBox: WaylandDispatchBoxOwning {
    var dispatchBoxOwner: AnyObject { owner }
}
