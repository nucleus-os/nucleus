// wp_viewporter on the router. Lets a client crop (set_source) and scale
// (set_destination) its surface content. Both are double-buffered surface state:
// the requests write the surface's pending viewport fields, latched on commit
// (boundary plan line 205 — the router owns viewport). libwayland owns the
// resource mechanics; WlSurface owns the latched state.
//
// Source/destination validation
// raises bad_value, a request after the wl_surface is gone raises no_surface, and
// a second get_viewport for one surface raises viewport_exists.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class WpViewporter {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_viewporter(), version: 1, impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpViewporter.self) else {
            return
        }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_viewporter(),
            version: Int32(version), id: id, vtable: WpViewporterServer.vtable,
            owner: me  // the manager is its own resource owner (router retains it)
        )
    }
}

// get_viewport(id, surface): one viewport per surface (viewport_exists = 0). The manager owner is
// shared across every bound resource, so the error is posted on the specific request `resource`.
extension WpViewporter: WpViewporterRequests {
    func getViewport(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                     surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.viewport) else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface already has a viewport")
            return
        }
        let viewport = WpViewport(surface: surface)
        guard let vres = id.create(vtable: WpViewportServer.vtable, owner: viewport) else {
            surface.releaseAux(.viewport)
            return
        }
        viewport.bind(vres)
    }
}

/// wp_viewport resource owner (Rule 9). Writes the surface's pending crop/scale.
final class WpViewport {
    private weak var surface: WlSurface?
    fileprivate(set) var resource: UnsafeMutablePointer<wl_resource>?

    init(surface: WlSurface) { self.surface = surface }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit {
        // Removing the viewport clears the surface's crop/scale on the next commit.
        if let surface {
            surface.setPendingViewportSource(nil)
            surface.setPendingViewportDestination(nil)
            surface.releaseAux(.viewport)
        }
    }
}

extension WpViewport: WpViewportRequests {
    func setSource(_ resource: UnsafeMutablePointer<wl_resource>,
                   x dx: Double, y dy: Double, width dw: Double, height dh: Double) {
        guard let surface else {
            swift_wayland_resource_post_error(resource, 3, "wl_surface was destroyed")  // no_surface
            return
        }
        if dx == -1.0, dy == -1.0, dw == -1.0, dh == -1.0 {
            surface.setPendingViewportSource(nil)  // unset
            return
        }
        guard dx >= 0, dy >= 0, dw > 0, dh > 0 else {
            swift_wayland_resource_post_error(resource, 0, "invalid viewport source rectangle")  // bad_value
            return
        }
        surface.setPendingViewportSource(WlFRect(x: dx, y: dy, width: dw, height: dh))
    }

    func setDestination(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard let surface else {
            swift_wayland_resource_post_error(resource, 3, "wl_surface was destroyed")  // no_surface
            return
        }
        if width == -1, height == -1 {
            surface.setPendingViewportDestination(nil)  // unset
            return
        }
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(resource, 0, "invalid viewport destination size")  // bad_value
            return
        }
        surface.setPendingViewportDestination(WlSize(width: width, height: height))
    }
}
