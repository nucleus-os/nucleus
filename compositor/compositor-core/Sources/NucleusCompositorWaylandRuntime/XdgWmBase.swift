// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class XdgWmBaseBinding {
    unowned let shell: XdgShell
    init(_ shell: XdgShell) { self.shell = shell }
}

// The xdg_wm_base request handlers, recovered by XdgWmBaseServer.vtable from the
// per-resource XdgWmBaseBinding owner and forwarded to the shared XdgShell.
extension XdgWmBaseBinding: XdgWmBaseRequests {
    func createPositioner(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        _ = id.create(vtable: XdgPositionerServer.vtable, owner: XdgPositioner())
    }

    func getXdgSurface(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes,
            let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimXdgConstruction() else {
            swift_wayland_resource_post_error(
                resource, surface.hasRole ? 0 /* role */ : 4 /* invalid_surface_state */,
                "wl_surface already has an XDG construction or committed state")
            return
        }
        let xdgSurface = XdgSurface(
            shell: shell, surface: surface, wmBaseResource: resource)
        guard let xres = id.create(vtable: XdgSurfaceServer.vtable, owner: xdgSurface)
        else {
            surface.releaseXdgConstruction()
            return
        }
        xdgSurface.bind(xres)
        surface.bindXdgConstructionRole(xdgSurface)
    }

    func pong(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {}  // liveness ack — no state to track
}
