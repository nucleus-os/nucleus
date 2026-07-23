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

public import WaylandServerC

public struct WlNewId {
    public let client: OpaquePointer
    public let id: UInt32
    public let version: Int32
    public let interface: UnsafePointer<wl_interface>?

    public init(client: OpaquePointer, id: UInt32, version: Int32,
                interface: UnsafePointer<wl_interface>?) {
        self.client = client
        self.id = id
        self.version = version
        self.interface = interface
    }

    /// Materialize with an owner + request vtable. The owner is retained through the resource's
    /// user_data and released when libwayland destroys it (see WaylandResource.create).
    @discardableResult
    public func create(vtable: UnsafeRawPointer?, owner: AnyObject) -> UnsafeMutablePointer<wl_resource>? {
        WaylandResource.create(client: client, interface: interface, version: version, id: id,
                               vtable: vtable, owner: owner)
    }

    /// Materialize a pure-notification object with no owner and no request handlers (wl_callback).
    @discardableResult
    public func createBare() -> UnsafeMutablePointer<wl_resource>? {
        wl_resource_create(client, interface, version, id)
    }
}
