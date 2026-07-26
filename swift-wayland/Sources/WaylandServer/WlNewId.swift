// A `new_id` request argument: an object the client has allocated an id for but that the server
// has not yet created. A factory request (wl_compositor.create_surface, xdg_wm_base.get_xdg_surface,
// every *_manager create/get) delivers one; the consumer materializes it into a live wl_resource
// with the owner + request vtable of its choosing — the one thing the generator cannot know.
//
//   * create(vtable:owner:) — an object that carries server-side state and/or handles requests
//     (the owner is retained via the resource and released on destroy, as in WaylandResource.create).
//   * createBare()          — a pure-notification object with no owner and no requests (wl_callback):
//     the server only ever sends it an event and destroys it.
//
// `version` is already resolved to min(parent-resource version, child interface's max version), so
// the consumer never recomputes it. Deferring creation to the consumer also means a factory request
// that fails validation simply never creates the object (no create-then-destroy on the error path).

import WaylandServerC

/// A request-scoped carrier of borrowed libwayland pointers. The client and
/// interface must remain valid until one create method returns.
@safe public struct WlNewId<Interface: WaylandServerInterface>: ~Escapable {
    @unsafe package let client: OpaquePointer
    public let id: UInt32
    public let version: Int32

    public var clientID: WaylandClientID {
        unsafe WaylandClientID(client)!
    }

    @_lifetime(borrow client)
    @unsafe package init(client: borrowing OpaquePointer, id: UInt32, version: Int32) {
        unsafe self.client = copy client
        self.id = id
        self.version = version
    }

    /// Implementation seam used by generated, interface-specific owner factories.
    @discardableResult
    @MainActor
    package func _create<Owner: AnyObject>(
        vtable: UnsafeRawPointer?,
        owner: (WaylandResourceHandle<Interface>) -> Owner?,
        installed: (Owner) -> Void
    ) -> Owner? {
        unsafe WaylandResource.create(
            client: client,
            interface: Interface.self,
            version: version,
            id: id,
            vtable: vtable,
            owner: owner,
            installed: installed)
    }

    /// Implementation seam used only by generated descriptor-specific bare
    /// factories for genuinely ownerless, requestless notification resources.
    @discardableResult
    @MainActor
    package func _createBare() -> WaylandResourceReference<Interface>? {
        let resource = unsafe wl_resource_create(
            client, Interface.descriptor.nativeInterface, version, id)
        return unsafe WaylandResourceReference<Interface>(resource)
    }
}
