// Resource ownership: each wl_resource has exactly one Swift owner object, retained through the
// resource's user_data and released by libwayland's destroy callback. Request handlers recover a
// *borrowed* reference to the owner; it must not escape the handler call. libwayland owns the
// resource's wire/object mechanics; the Swift owner holds the server-side semantic state for it.

public import WaylandServerC

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
        create(
            client: client,
            interface: interface,
            version: version,
            id: id,
            vtable: vtable,
            owner: owner,
            using: wl_resource_create)
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
        guard let resource = createResource(client, interface, version, id)
        else { return nil }
        let retained = Unmanaged.passRetained(owner).toOpaque()
        wl_resource_set_implementation(resource, vtable, retained, swiftWaylandResourceDestroy)
        return resource
    }

    /// Borrow the Swift owner bound to a resource. The reference is valid only for
    /// the current call; storing it past the handler breaks the ownership contract.
    public static func owner<T: AnyObject>(
        of resource: UnsafeMutablePointer<wl_resource>, as _: T.Type
    ) -> T? {
        guard let ud = wl_resource_get_user_data(resource) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ud).takeUnretainedValue() as? T
    }
}

/// A checked cross-request reference to a `wl_resource`. A destroy listener
/// clears `resource` before libwayland frees it, so callers never need to probe or
/// dereference a stale raw pointer. `semanticOwner` optionally keeps the object
/// behind the wire resource alive (for example DMA-BUF plane storage).
public final class WaylandResourceReference {
    public private(set) var resource: UnsafeMutablePointer<wl_resource>?
    public let semanticOwner: AnyObject?
    private var listener: UnsafeMutablePointer<swift_wayland_resource_lifetime_listener>?

    public init?(
        _ resource: UnsafeMutablePointer<wl_resource>?, retaining semanticOwner: AnyObject? = nil
    ) {
        guard let resource else { return nil }
        self.resource = resource
        self.semanticOwner = semanticOwner
        self.listener = nil
        guard let listener = swift_wayland_resource_lifetime_listener_create(
            Unmanaged.passUnretained(self).toOpaque(), waylandResourceReferenceDestroyed)
        else { return nil }
        self.listener = listener
        swift_wayland_resource_lifetime_listener_attach(listener, resource)
    }

    deinit {
        if let listener { swift_wayland_resource_lifetime_listener_destroy(listener) }
    }

    fileprivate func resourceDestroyed(
        _ listener: UnsafeMutablePointer<swift_wayland_resource_lifetime_listener>
    ) {
        self.listener = nil
        resource = nil
        swift_wayland_resource_lifetime_listener_destroy(listener)
    }
}

private let waylandResourceReferenceDestroyed: @convention(c) (
    UnsafeMutablePointer<wl_listener>?, UnsafeMutableRawPointer?
) -> Void = { listener, _ in
    guard let listener,
          let owner = swift_wayland_resource_lifetime_listener_owner(listener)
    else { return }
    let reference = Unmanaged<WaylandResourceReference>.fromOpaque(owner).takeUnretainedValue()
    guard let box = swift_wayland_resource_lifetime_listener_box(listener) else { return }
    reference.resourceDestroyed(box)
}

// One destroy callback serves every resource: release the retained owner box.
// Semantic teardown runs in the owner's deinit.
let swiftWaylandResourceDestroy: @convention(c) (UnsafeMutablePointer<wl_resource>?) -> Void = {
    resource in
    guard let resource, let ud = wl_resource_get_user_data(resource) else { return }
    Unmanaged<AnyObject>.fromOpaque(ud).release()
}
