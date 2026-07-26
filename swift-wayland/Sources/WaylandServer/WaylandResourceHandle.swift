import WaylandServerC

/// A typed, lifetime-checked view of one server-side Wayland resource.
///
/// The handle observes the native resource through `WaylandResourceReference`;
/// it does not retain or resurrect the native object. The descriptor phantom
/// type prevents resources belonging to different protocol interfaces from
/// being mixed at Swift call sites.
@MainActor
@safe public final class WaylandResourceHandle<Interface: WaylandServerInterface> {
    private let reference: WaylandResourceReference<Interface>

    @unsafe
    package init?(_ resource: UnsafeMutablePointer<wl_resource>?) {
        guard let reference =
            unsafe WaylandResourceReference<Interface>(resource)
        else {
            return nil
        }
        unsafe self.reference = reference
    }

    package init(reference: WaylandResourceReference<Interface>) {
        unsafe self.reference = reference
    }

    package var resource: UnsafeMutablePointer<wl_resource>? {
        unsafe reference.nativeResource
    }

    public var referenceValue: WaylandResourceReference<Interface> {
        unsafe reference
    }

    public var isLive: Bool {
        unsafe reference.isLive
    }

    public var version: Int32? {
        unsafe reference.version
    }

    public var clientID: WaylandClientID? {
        unsafe reference.clientID
    }

    public var objectID: UInt32? {
        unsafe reference.objectID
    }

    @discardableResult
    public func destroy() -> Bool {
        unsafe reference.destroy()
    }

    @discardableResult
    public func postNoMemory() -> Bool {
        unsafe reference.postNoMemory()
    }

    @discardableResult
    package func postError(code: UInt32, message: String) -> Bool {
        guard let resource = unsafe reference.nativeResource else {
            return false
        }
        unsafe swift_wayland_resource_post_error(resource, code, message)
        return true
    }
}
