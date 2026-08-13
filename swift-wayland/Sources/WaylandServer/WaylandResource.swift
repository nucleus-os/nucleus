// Resource ownership: each resource created here has exactly one Swift owner object, retained
// through the resource's user_data and released by libwayland's destroy callback. Interface and
// implementation identity distinguish these resources from foreign resources whose user_data
// belongs to libwayland or another subsystem. libwayland owns the resource's wire/object
// mechanics; the Swift owner holds the server-side semantic state for it.

package import WaylandServerC

@MainActor
package enum WaylandResource {
    /// Create a resource and bind an owner that conforms to the generated
    /// request contract. Conformance is resolved once before native allocation;
    /// a non-conforming owner fails creation rather than silently dropping every
    /// request for the resource's lifetime.
    package static func create<Interface: WaylandServerInterface>(
        client: OpaquePointer,
        interface _: Interface.Type,
        version: Int32,
        id: UInt32,
        owner: AnyObject
    ) -> UnsafeMutablePointer<wl_resource>? {
        guard let handler = owner as? Interface.Requests else { return nil }
        let resource = unsafe wl_resource_create(
            client, Interface.descriptor.nativeInterface, version, id)
        return unsafe installCreatedResource(
            resource,
            interface: Interface.self,
            owner: owner,
            handler: handler)
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
        owner makeOwner: (WaylandResourceHandle<Interface>) -> Owner?,
        handler bindHandler: (Owner) -> Interface.Requests?,
        installed: (Owner) -> Void
    ) -> Owner? {
        let resource = unsafe wl_resource_create(
            client, Interface.descriptor.nativeInterface, version, id)
        return unsafe installCreatedResource(
            resource,
            owner: makeOwner,
            handler: bindHandler,
            installed: installed)
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
        handler bindHandler: (Owner) -> Child.Requests?,
        installed: (Owner) -> Void,
        publish: (WaylandResourceHandle<Child>) -> Bool
    ) -> Owner? {
        guard let parentResource = unsafe parent.resource,
            let client = unsafe wl_resource_get_client(parentResource)
        else { return nil }
        let resource = unsafe wl_resource_create(
            client,
            Child.descriptor.nativeInterface,
            Swift.min(version, Child.maximumVersion),
            0)
        return unsafe installCreatedChild(
            resource,
            parent: parent,
            interface: Child.self,
            owner: { handle in
                return makeOwner(handle)
            },
            handler: bindHandler,
            installed: installed,
            publish: publish)
    }

    /// Complete owner installation for a native allocation result. Tests pass
    /// `nil` to cover allocation failure without replacing the allocator used by
    /// production creation paths.
    static func installCreatedResource<
        Interface: WaylandServerInterface, Owner: AnyObject
    >(
        _ resource: UnsafeMutablePointer<wl_resource>?,
        owner makeOwner: (WaylandResourceHandle<Interface>) -> Owner?,
        handler bindHandler: (Owner) -> Interface.Requests?,
        installed: (Owner) -> Void
    ) -> Owner? {
        guard let resource = unsafe resource else { return nil }
        guard
            let reference =
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

        let box = WaylandDispatchBox<Interface>(
            owner: owner,
            handler: bindHandler(owner))
        let retained = unsafe Unmanaged.passRetained(box).toOpaque()
        unsafe wl_resource_set_implementation(
            resource, Interface.descriptor.nativeRequestVtable, retained,
            swiftWaylandResourceDestroy)
        installed(owner)
        return owner
    }

    static func installCreatedResource<Interface: WaylandServerInterface>(
        _ resource: UnsafeMutablePointer<wl_resource>?,
        interface _: Interface.Type,
        owner: AnyObject,
        handler: Interface.Requests
    ) -> UnsafeMutablePointer<wl_resource>? {
        guard let resource = unsafe resource else { return nil }
        let box = WaylandDispatchBox<Interface>(owner: owner, handler: handler)
        let retained = unsafe Unmanaged.passRetained(box).toOpaque()
        unsafe wl_resource_set_implementation(
            resource, Interface.descriptor.nativeRequestVtable, retained,
            swiftWaylandResourceDestroy)
        return unsafe resource
    }

    /// Complete a server-created child transaction from the native allocation
    /// result. A missing allocation reports no-memory on the still-live parent;
    /// later owner or publication failures destroy the allocated child.
    static func installCreatedChild<
        Parent: WaylandServerInterface,
        Child: WaylandServerInterface,
        Owner: AnyObject
    >(
        _ resource: UnsafeMutablePointer<wl_resource>?,
        parent: WaylandResourceHandle<Parent>,
        interface _: Child.Type,
        owner makeOwner: (WaylandResourceHandle<Child>) -> Owner?,
        handler bindHandler: (Owner) -> Child.Requests?,
        installed: (Owner) -> Void,
        publish: (WaylandResourceHandle<Child>) -> Bool
    ) -> Owner? {
        guard let resource = unsafe resource else {
            parent.postNoMemory()
            return nil
        }
        guard
            let reference = unsafe WaylandResourceReference<Child>(resource)
        else {
            unsafe wl_resource_destroy(resource)
            return nil
        }
        let handle = WaylandResourceHandle<Child>(reference: reference)
        guard let owner = makeOwner(handle) else {
            unsafe wl_resource_destroy(resource)
            return nil
        }

        let box = WaylandDispatchBox<Child>(
            owner: owner,
            handler: bindHandler(owner))
        let retained = unsafe Unmanaged.passRetained(box).toOpaque()
        unsafe wl_resource_set_implementation(
            resource,
            Child.descriptor.nativeRequestVtable,
            retained,
            swiftWaylandResourceDestroy)
        guard publish(handle) else {
            unsafe wl_resource_destroy(resource)
            return nil
        }
        installed(owner)
        return owner
    }

    /// Explicit binding seam for destroy-only resources whose owner may choose
    /// not to override the generated fallback handler.
    package static func create<
        Interface: WaylandServerInterface, Owner: AnyObject
    >(
        client: OpaquePointer,
        interface _: Interface.Type,
        version: Int32,
        id: UInt32,
        owner: Owner,
        handler: Interface.Requests?
    ) -> UnsafeMutablePointer<wl_resource>? {
        guard
            let resource = unsafe wl_resource_create(
                client, Interface.descriptor.nativeInterface, version, id)
        else { return nil }
        let box = WaylandDispatchBox<Interface>(owner: owner, handler: handler)
        let retained = unsafe Unmanaged.passRetained(box).toOpaque()
        unsafe wl_resource_set_implementation(
            resource, Interface.descriptor.nativeRequestVtable, retained,
            swiftWaylandResourceDestroy)
        return unsafe resource
    }

    /// Borrow the Swift owner bound to a resource created by this runtime.
    /// Foreign resources return nil without interpreting their user data.
    package static func owner<
        Interface: WaylandServerInterface, Owner: AnyObject
    >(
        of resource: UnsafeMutablePointer<wl_resource>,
        interface _: Interface.Type,
        as _: Owner.Type
    ) -> Owner? {
        guard let requestVtable = unsafe Interface.descriptor.nativeRequestVtable,
            unsafe wl_resource_instance_of(
                resource,
                Interface.descriptor.nativeInterface,
                requestVtable) != 0,
            let userData = unsafe wl_resource_get_user_data(resource)
        else { return nil }
        return unsafe Unmanaged<WaylandDispatchBox<Interface>>
            .fromOpaque(userData).takeUnretainedValue().owner as? Owner
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
        guard
            let listener = unsafe swift_wayland_resource_lifetime_listener_create(
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

    package func typedHandle<Interface: WaylandServerInterface>(
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
@safe
package final class WaylandResourceReference<
    Interface: WaylandServerInterface
> {
    private let lifetime: WaylandResourceLifetime

    @unsafe
    package init?(
        _ resource: UnsafeMutablePointer<wl_resource>?,
        retaining semanticOwner: AnyObject? = nil
    ) {
        guard
            let lifetime = unsafe WaylandResourceLifetime(
                resource,
                retaining: semanticOwner)
        else { return nil }
        self.lifetime = lifetime
    }

    package var handle: WaylandResourceHandle<Interface> {
        WaylandResourceHandle(reference: self)
    }

    package var isLive: Bool {
        unsafe lifetime.resource != nil
    }

    package var version: Int32? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe wl_resource_get_version(resource)
    }

    package var clientID: WaylandClientID? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    package var objectID: UInt32? {
        guard let resource = unsafe lifetime.resource else { return nil }
        return unsafe wl_resource_get_id(resource)
    }

    package func retainedSemanticOwner<Owner: AnyObject>(
        as _: Owner.Type
    ) -> Owner? {
        lifetime.semanticOwner as? Owner
    }

    @discardableResult
    package func destroy() -> Bool {
        guard let resource = unsafe lifetime.resource else { return false }
        unsafe wl_resource_destroy(resource)
        return true
    }

    @discardableResult
    package func postNoMemory() -> Bool {
        guard let resource = unsafe lifetime.resource else { return false }
        unsafe wl_resource_post_no_memory(resource)
        return true
    }

    package var nativeResource: UnsafeMutablePointer<wl_resource>? {
        unsafe lifetime.resource
    }
}

private let waylandResourceReferenceDestroyed:
    @convention(c) (
        UnsafeMutablePointer<wl_listener>?, UnsafeMutableRawPointer?
    ) -> Void = { listener, _ in
        guard let listener = unsafe listener,
            let owner = unsafe swift_wayland_resource_lifetime_listener_owner(
                listener)
        else { return }
        let reference = unsafe Unmanaged<WaylandResourceLifetime>
            .fromOpaque(owner).takeUnretainedValue()
        guard
            let box = unsafe swift_wayland_resource_lifetime_listener_box(
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
