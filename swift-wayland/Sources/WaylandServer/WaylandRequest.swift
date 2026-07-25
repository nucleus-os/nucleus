public import WaylandServerC
public import WaylandProtocolTypes

/// The typed resource on which one generated server request arrived.
///
/// A request view is nonescapable: the native resource and its borrowed argument
/// storage are valid only for the synchronous generated dispatch call.
@MainActor
@safe public struct WaylandRequest<
    Interface: WaylandServerInterface
>: ~Escapable {
    @unsafe public let resource: UnsafeMutablePointer<wl_resource>

    @_lifetime(borrow resource)
    package init(_ resource: UnsafeMutablePointer<wl_resource>) {
        unsafe self.resource = copy resource
    }

    public var version: Int32 {
        unsafe wl_resource_get_version(resource)
    }

    public var clientID: WaylandClientID? {
        unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    package func postError(code: UInt32, message: String) {
        unsafe swift_wayland_resource_post_error(
            resource, code, message)
    }

    public func postError<Code: WaylandProtocolErrorValue>(
        _ code: Code,
        message: String
    ) {
        unsafe postError(code: code.rawValue, message: message)
    }
}

/// A request-scoped, interface-typed reference to another Wayland resource.
///
/// The view never retains the native resource. Policy explicitly resolves the
/// domain owner it expects, while the phantom interface prevents cross-protocol
/// object arguments from being mixed.
@MainActor
@safe public struct WaylandBorrowedObject<
    Interface: WaylandServerInterface
>: ~Escapable {
    @unsafe public let resource: UnsafeMutablePointer<wl_resource>

    @_lifetime(borrow resource)
    package init(_ resource: UnsafeMutablePointer<wl_resource>) {
        unsafe self.resource = copy resource
    }

    public func owner<Owner: AnyObject>(
        as _: Owner.Type
    ) -> Owner? {
        unsafe WaylandResource.owner(of: resource, as: Owner.self)
    }

    public var version: Int32 {
        unsafe wl_resource_get_version(resource)
    }

    public var clientID: WaylandClientID? {
        unsafe WaylandClientID(wl_resource_get_client(resource))
    }
}
