package import WaylandServerC

/// The typed resource on which one generated server request arrived.
///
/// A request view is nonescapable: the native resource and its borrowed argument
/// storage are valid only for the synchronous generated dispatch call.
@MainActor
@safe
package struct WaylandRequest<
    Interface: WaylandServerInterface
>: ~Escapable {
    @unsafe package let resource: UnsafeMutablePointer<wl_resource>

    @_lifetime(borrow resource)
    package init(_ resource: UnsafeMutablePointer<wl_resource>) {
        unsafe self.resource = copy resource
    }

    package var version: Int32 {
        unsafe wl_resource_get_version(resource)
    }

    package var clientID: WaylandClientID? {
        unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    package var objectID: UInt32 {
        unsafe wl_resource_get_id(resource)
    }

    package func destroy() {
        unsafe wl_resource_destroy(resource)
    }

    package func postNoMemory() {
        unsafe wl_resource_post_no_memory(resource)
    }

    package func postError(code: UInt32, message: String) {
        unsafe swift_wayland_resource_post_error(
            resource, code, message)
    }
}

/// A request-scoped, interface-typed reference to another Wayland resource.
///
/// The view never retains the native resource. Policy explicitly resolves the
/// domain owner it expects, while the phantom interface prevents cross-protocol
/// object arguments from being mixed.
@MainActor
@safe
package struct WaylandBorrowedObject<
    Interface: WaylandServerInterface
>: ~Escapable {
    @unsafe package let resource: UnsafeMutablePointer<wl_resource>

    @_lifetime(borrow resource)
    package init(_ resource: UnsafeMutablePointer<wl_resource>) {
        unsafe self.resource = copy resource
    }

    package func owner<Owner: AnyObject>(
        as _: Owner.Type
    ) -> Owner? {
        unsafe WaylandResource.owner(
            of: resource,
            interface: Interface.self,
            as: Owner.self)
    }

    package var version: Int32 {
        unsafe wl_resource_get_version(resource)
    }

    package var clientID: WaylandClientID? {
        unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    package func retainedReference(
        retaining semanticOwner: AnyObject? = nil
    ) -> WaylandResourceReference<Interface>? {
        unsafe WaylandResourceReference<Interface>(
            resource,
            retaining: semanticOwner)
    }
}
