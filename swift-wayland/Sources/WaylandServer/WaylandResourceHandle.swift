public import WaylandServerC
public import WaylandProtocolTypes

/// A typed, lifetime-checked view of one server-side Wayland resource.
///
/// The handle observes the native resource through `WaylandResourceReference`;
/// it does not retain or resurrect the native object. The descriptor phantom
/// type prevents resources belonging to different protocol interfaces from
/// being mixed at Swift call sites.
@MainActor
@safe public final class WaylandResourceHandle<Interface: WaylandServerInterface> {
    private let reference: WaylandResourceReference

    @unsafe
    public init?(_ resource: UnsafeMutablePointer<wl_resource>?) {
        guard let reference = unsafe WaylandResourceReference(resource) else {
            return nil
        }
        unsafe self.reference = reference
    }

    init(reference: WaylandResourceReference) {
        unsafe self.reference = reference
    }

    /// The resource while it remains live. This raw escape exists for generated
    /// dispatch and narrow interoperability code; policy code should use typed
    /// operations on the handle.
    @unsafe
    public var resource: UnsafeMutablePointer<wl_resource>? {
        unsafe reference.resource
    }

    public var version: Int32? {
        guard let resource = unsafe reference.resource else { return nil }
        return unsafe wl_resource_get_version(resource)
    }

    public var clientID: WaylandClientID? {
        guard let resource = unsafe reference.resource else { return nil }
        return unsafe WaylandClientID(wl_resource_get_client(resource))
    }

    @discardableResult
    package func postError(code: UInt32, message: String) -> Bool {
        guard let resource = unsafe reference.resource else { return false }
        unsafe swift_wayland_resource_post_error(resource, code, message)
        return true
    }

    @discardableResult
    public func postError<Code: WaylandProtocolErrorValue>(
        _ code: Code,
        message: String
    ) -> Bool {
        unsafe postError(code: code.rawValue, message: message)
    }
}
