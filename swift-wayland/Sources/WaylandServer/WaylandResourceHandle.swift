import WaylandServerC

/// A typed, lifetime-checked view of one server-side Wayland resource.
///
/// The handle observes the native resource through `WaylandResourceReference`;
/// it does not retain or resurrect the native object. The descriptor phantom
/// type prevents resources belonging to different protocol interfaces from
/// being mixed at Swift call sites.
@MainActor
@safe package final class WaylandResourceHandle<Interface: WaylandServerInterface> {
    private let reference: WaylandResourceReference<Interface>

    @unsafe
    package init?(_ resource: UnsafeMutablePointer<wl_resource>?) {
        guard
            let reference =
                unsafe WaylandResourceReference<Interface>(resource)
        else {
            return nil
        }
        self.reference = reference
    }

    package init(reference: WaylandResourceReference<Interface>) {
        self.reference = reference
    }

    package var resource: UnsafeMutablePointer<wl_resource>? {
        unsafe reference.nativeResource
    }

    package var referenceValue: WaylandResourceReference<Interface> {
        reference
    }

    package var isLive: Bool {
        reference.isLive
    }

    package var version: Int32? {
        reference.version
    }

    package var clientID: WaylandClientID? {
        reference.clientID
    }

    package var objectID: UInt32? {
        reference.objectID
    }

    @discardableResult
    package func destroy() -> Bool {
        reference.destroy()
    }

    @discardableResult
    package func postNoMemory() -> Bool {
        reference.postNoMemory()
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
