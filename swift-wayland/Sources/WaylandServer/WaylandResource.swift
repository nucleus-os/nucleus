// Resource ownership: each resource created here has exactly one Swift owner object, retained
// through the resource's user_data and released by libwayland's destroy callback. A checked
// registry distinguishes these resources from foreign resources whose user_data belongs to
// libwayland or another subsystem. libwayland owns the resource's wire/object mechanics; the
// Swift owner holds the server-side semantic state for it.

public import WaylandServerC

@MainActor
public enum WaylandResource {
    private static var owners: [UInt: AnyObject] = [:]

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

    /// Allocate and publish a server-created child from its live parent as one
    /// transaction. The parent determines the native client. Owner construction
    /// and event publication failures destroy the child before returning.
    package static func createChild<
        Parent: WaylandServerInterface,
        Child: WaylandServerInterface,
        Owner: AnyObject
    >(
        parent: WaylandResourceHandle<Parent>,
        interface _: Child.Type,
        version: Int32,
        owner makeOwner: (WaylandResourceHandle<Child>) -> Owner?,
        installed: (Owner) -> Void,
        publish: (WaylandResourceHandle<Child>) -> Bool
    ) -> Owner? {
        unsafe createChild(
            parent: parent,
            interface: Child.self,
            version: version,
            owner: makeOwner,
            installed: installed,
            publish: publish,
            using: wl_resource_create)
    }

    /// Internal allocation injection point for the complete parent/child
    /// transaction, including allocation, owner, publication, and rollback
    /// failure coverage.
    static func createChild<
        Parent: WaylandServerInterface,
        Child: WaylandServerInterface,
        Owner: AnyObject
    >(
        parent: WaylandResourceHandle<Parent>,
        interface _: Child.Type,
        version: Int32,
        owner makeOwner: (WaylandResourceHandle<Child>) -> Owner?,
        installed: (Owner) -> Void,
        publish: (WaylandResourceHandle<Child>) -> Bool,
        using createResource: ResourceFactory
    ) -> Owner? {
        guard let parentResource = unsafe parent.resource,
            let client = unsafe wl_resource_get_client(parentResource)
        else { return nil }

        var childHandle: WaylandResourceHandle<Child>?
        var published = false
        let created: Owner? = unsafe create(
            client: client,
            interface: Child.self,
            version: Swift.min(version, Child.maximumVersion),
            id: 0,
            vtable: Child.descriptor.nativeRequestVtable,
            owner: { handle in
                childHandle = handle
                return makeOwner(handle)
            },
            installed: { childOwner in
                guard let childHandle, publish(childHandle) else {
                    childHandle?.destroy()
                    return
                }
                published = true
                installed(childOwner)
            },
            using: createResource)

        guard let created else {
            if childHandle == nil {
                parent.postNoMemory()
            }
            return nil
        }
        guard published else {
            childHandle?.destroy()
            return nil
        }
        return created
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
            client, Interface.descriptor.nativeInterface, version, id)
        else { return nil }

        guard let reference =
            unsafe WaylandResourceReference<Interface>(resource)
        else {
            unsafe wl_resource_destroy(resource)
            return nil
        }
        let handle = WaylandResourceHandle<Interface>(reference: reference)

        guard let owner = makeOwner(handle) else {
            unsafe wl_resource_destroy(resource)
            return nil
        }

        let retained = unsafe Unmanaged.passRetained(owner).toOpaque()
        owners[UInt(bitPattern: resource)] = owner
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
        owners[UInt(bitPattern: resource)] = owner
        unsafe wl_resource_set_implementation(
            resource, vtable, retained, swiftWaylandResourceDestroy)
        return unsafe resource
    }

    /// Borrow the Swift owner bound to a resource created by this runtime.
    /// Foreign resources return nil without interpreting their user data.
    public static func owner<T: AnyObject>(
        of resource: UnsafeMutablePointer<wl_resource>, as _: T.Type
    ) -> T? {
        owners[UInt(bitPattern: resource)] as? T
    }

    fileprivate static func resourceWasDestroyed(
        _ resource: UnsafeMutablePointer<wl_resource>
    ) {
        owners.removeValue(forKey: UInt(bitPattern: resource))
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
@safe private final class WaylandResourceLifetime {
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    let semanticOwner: AnyObject?
    private var listener: UnsafeMutablePointer<swift_wayland_resource_lifetime_listener>?

    init?(
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

/// An interface-typed, checked cross-request reference to a `wl_resource`.
///
/// Native destruction clears the shared lifetime state before libwayland frees
/// the resource. The interface parameter is fixed when the reference is created,
/// so retained resources cannot be reconstructed as another protocol type.
@MainActor
@safe public final class WaylandResourceReference<
    Interface: WaylandServerInterface
> {
    private let lifetime: WaylandResourceLifetime

    @unsafe
    package init?(
        _ resource: UnsafeMutablePointer<wl_resource>?,
        retaining semanticOwner: AnyObject? = nil
    ) {
        guard let lifetime = unsafe WaylandResourceLifetime(
            resource,
            retaining: semanticOwner)
        else { return nil }
        self.lifetime = lifetime
    }

    public var handle: WaylandResourceHandle<Interface> {
        WaylandResourceHandle(reference: self)
    }

    public var isLive: Bool {
        unsafe lifetime.resource != nil
    }

    public var version: Int32? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe wl_resource_get_version(resource)
    }

    public var clientID: WaylandClientID? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    public var objectID: UInt32? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe wl_resource_get_id(resource)
    }

    public func retainedSemanticOwner<Owner: AnyObject>(
        as _: Owner.Type
    ) -> Owner? {
        lifetime.semanticOwner as? Owner
    }

    @discardableResult
    public func destroy() -> Bool {
        guard let resource = unsafe lifetime.resource else { return false }
        unsafe wl_resource_destroy(resource)
        return true
    }

    @discardableResult
    public func postNoMemory() -> Bool {
        guard let resource = unsafe lifetime.resource else { return false }
        unsafe wl_resource_post_no_memory(resource)
        return true
    }

    package var nativeResource: UnsafeMutablePointer<wl_resource>? {
        unsafe lifetime.resource
    }
}

private let waylandResourceReferenceDestroyed: @convention(c) (
    UnsafeMutablePointer<wl_listener>?, UnsafeMutableRawPointer?
) -> Void = { listener, _ in
    guard let listener = unsafe listener,
          let owner = unsafe swift_wayland_resource_lifetime_listener_owner(
            listener)
    else { return }
    let reference = unsafe Unmanaged<WaylandResourceLifetime>
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
    nonisolated(unsafe) let actorResource = unsafe resource
    MainActor.assumeIsolated {
        unsafe WaylandResource.resourceWasDestroyed(actorResource)
        unsafe Unmanaged<AnyObject>.fromOpaque(actorOwner).release()
    }
}
