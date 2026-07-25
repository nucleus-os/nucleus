// Resource ownership: each wl_resource has exactly one Swift owner object, retained through the
// resource's user_data and released by libwayland's destroy callback. Request handlers recover a
// *borrowed* reference to the owner; it must not escape the handler call. libwayland owns the
// resource's wire/object mechanics; the Swift owner holds the server-side semantic state for it.

public import WaylandServerC

@MainActor
public enum WaylandResource {
    typealias ResourceFactory = (
        OpaquePointer,
        UnsafePointer<wl_interface>?,
        Int32,
        UInt32
    ) -> UnsafeMutablePointer<wl_resource>?

    /// Create a wl_resource and bind a Swift owner to it. The owner is retained
    /// and stored as the resource's user_data; the shared destroy callback
    /// releases that retain when libwayland destroys the resource, so the owner's
    /// deinit runs the semantic teardown. `vtable` is a pointer to libwayland's
    /// request-handler struct (e.g. a zero-initialized swift_wayland_<iface>_requests
    /// with its handler fields assigned), or nil for resources that take no
    /// requests.
    public static func create(
        client: OpaquePointer,
        interface: UnsafePointer<wl_interface>?,
        version: Int32,
        id: UInt32,
        vtable: UnsafeRawPointer?,
        owner: AnyObject
    ) -> UnsafeMutablePointer<wl_resource>? {
        unsafe create(
            client: client,
            interface: interface,
            version: version,
            id: id,
            vtable: vtable,
            owner: owner,
            using: wl_resource_create)
    }

    /// Create, construct, install, and publish a typed resource owner as one
    /// transaction. Generated `WlNewId` factories supply the interface and
    /// request vtable so policy code cannot mismatch either value.
    package static func create<
        Interface: WaylandServerInterface, Owner: AnyObject
    >(
        client: OpaquePointer,
        interface _: Interface.Type,
        version: Int32,
        id: UInt32,
        vtable: UnsafeRawPointer?,
        owner makeOwner: (WaylandResourceHandle<Interface>) -> Owner?,
        installed: (Owner) -> Void
    ) -> Owner? {
        unsafe create(
            client: client,
            interface: Interface.self,
            version: version,
            id: id,
            vtable: vtable,
            owner: makeOwner,
            installed: installed,
            using: wl_resource_create)
    }

    /// Internal injection point for typed allocation and rollback coverage.
    static func create<
        Interface: WaylandServerInterface, Owner: AnyObject
    >(
        client: OpaquePointer,
        interface _: Interface.Type,
        version: Int32,
        id: UInt32,
        vtable: UnsafeRawPointer?,
        owner makeOwner: (WaylandResourceHandle<Interface>) -> Owner?,
        installed: (Owner) -> Void,
        using createResource: ResourceFactory
    ) -> Owner? {
        guard let resource = unsafe createResource(
            client, Interface.interface, version, id)
        else { return nil }

        guard let reference = unsafe WaylandResourceReference(resource) else {
            unsafe wl_resource_destroy(resource)
            return nil
        }
        let handle = unsafe WaylandResourceHandle<Interface>(reference: reference)

        guard let owner = unsafe makeOwner(handle) else {
            unsafe wl_resource_destroy(resource)
            return nil
        }

        let retained = unsafe Unmanaged.passRetained(owner).toOpaque()
        unsafe wl_resource_set_implementation(
            resource, vtable, retained, swiftWaylandResourceDestroy)
        installed(owner)
        return owner
    }

    /// Internal injection point for deterministic allocation-failure coverage.
    /// Ownership transfers only after the native resource exists.
    static func create(
        client: OpaquePointer,
        interface: UnsafePointer<wl_interface>?,
        version: Int32,
        id: UInt32,
        vtable: UnsafeRawPointer?,
        owner: AnyObject,
        using createResource: ResourceFactory
    ) -> UnsafeMutablePointer<wl_resource>? {
        guard let resource = unsafe createResource(
            client, interface, version, id)
        else { return nil }
        let retained = unsafe Unmanaged.passRetained(owner).toOpaque()
        unsafe wl_resource_set_implementation(
            resource, vtable, retained, swiftWaylandResourceDestroy)
        return unsafe resource
    }

    /// Borrow the Swift owner bound to a resource. The reference is valid only for
    /// the current call; storing it past the handler breaks the ownership contract.
    public static func owner<T: AnyObject>(
        of resource: UnsafeMutablePointer<wl_resource>, as _: T.Type
    ) -> T? {
        guard let ud = unsafe wl_resource_get_user_data(resource) else { return nil }
        return unsafe Unmanaged<AnyObject>.fromOpaque(ud)
            .takeUnretainedValue() as? T
    }
}

/// A checked cross-request reference to a `wl_resource`. A destroy listener
/// clears `resource` before libwayland frees it, so callers never need to probe or
/// dereference a stale raw pointer. `semanticOwner` optionally keeps the object
/// behind the wire resource alive (for example DMA-BUF plane storage).
///
/// The listener stores an unretained `self` because listener registration,
/// explicit listener release, and libwayland resource destruction are serialized
/// on the Wayland event-loop owner. The listener cannot race this reference's
/// deinitialization on another thread.
@MainActor
@safe public final class WaylandResourceReference {
    public private(set) var resource: UnsafeMutablePointer<wl_resource>?
    public let semanticOwner: AnyObject?
    private var listener: UnsafeMutablePointer<swift_wayland_resource_lifetime_listener>?

    public init?(
        _ resource: UnsafeMutablePointer<wl_resource>?, retaining semanticOwner: AnyObject? = nil
    ) {
        guard let resource = unsafe resource else { return nil }
        unsafe self.resource = resource
        self.semanticOwner = semanticOwner
        unsafe self.listener = nil
        guard let listener = unsafe swift_wayland_resource_lifetime_listener_create(
            Unmanaged.passUnretained(self).toOpaque(),
            waylandResourceReferenceDestroyed)
        else { return nil }
        unsafe self.listener = listener
        unsafe swift_wayland_resource_lifetime_listener_attach(
            listener, resource)
    }

    isolated deinit {
        if let listener = unsafe listener {
            unsafe swift_wayland_resource_lifetime_listener_destroy(listener)
        }
    }

    public func typedHandle<Interface: WaylandServerInterface>(
        as _: Interface.Type
    ) -> WaylandResourceHandle<Interface>? {
        unsafe WaylandResourceHandle(resource)
    }

    fileprivate func resourceDestroyed(
        _ listener: UnsafeMutablePointer<swift_wayland_resource_lifetime_listener>
    ) {
        unsafe self.listener = nil
        unsafe resource = nil
        unsafe swift_wayland_resource_lifetime_listener_destroy(listener)
    }
}

private let waylandResourceReferenceDestroyed: @convention(c) (
    UnsafeMutablePointer<wl_listener>?, UnsafeMutableRawPointer?
) -> Void = { listener, _ in
    guard let listener = unsafe listener,
          let owner = unsafe swift_wayland_resource_lifetime_listener_owner(
            listener)
    else { return }
    let reference = unsafe Unmanaged<WaylandResourceReference>
        .fromOpaque(owner).takeUnretainedValue()
    guard let box = unsafe swift_wayland_resource_lifetime_listener_box(
        listener)
    else { return }
    let actorReference = reference
    nonisolated(unsafe) let actorBox = unsafe box
    MainActor.assumeIsolated {
        unsafe actorReference.resourceDestroyed(actorBox)
    }
}

// One destroy callback serves every resource: release the retained owner box.
// Semantic teardown runs in the owner's deinit.
let swiftWaylandResourceDestroy: @convention(c) (UnsafeMutablePointer<wl_resource>?) -> Void = {
    resource in
    guard let resource = unsafe resource,
          let ud = unsafe wl_resource_get_user_data(resource)
    else { return }
    nonisolated(unsafe) let actorOwner = unsafe ud
    MainActor.assumeIsolated {
        unsafe Unmanaged<AnyObject>.fromOpaque(actorOwner).release()
    }
}
