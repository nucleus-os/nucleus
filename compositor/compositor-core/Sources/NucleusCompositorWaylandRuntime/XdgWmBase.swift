// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

@MainActor
@safe final class XdgWmBaseBinding {
    unowned let shell: XdgShell
    let resource: WaylandResourceHandle<XdgWmBaseServer>

    init(
        _ shell: XdgShell,
        resource: WaylandResourceHandle<XdgWmBaseServer>
    ) {
        self.shell = shell
        self.resource = resource
    }
}

// The xdg_wm_base request handlers, recovered by XdgWmBaseServer.vtable from the
// per-resource XdgWmBaseBinding owner and forwarded to the shared XdgShell.
extension XdgWmBaseBinding: XdgWmBaseRequests {
    func createPositioner(
        _ request: WaylandRequest<XdgWmBaseServer>,
        id: WlNewId<XdgPositionerServer>
    ) {
        _ = unsafe id.create { handle in
            XdgPositioner(resource: handle)
        }
    }

    func getXdgSurface(
        _ request: WaylandRequest<XdgWmBaseServer>,
        id: WlNewId<XdgSurfaceServer>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard surface.claimXdgConstruction() else {
            request.postError(
                surface.hasRole ? .role : .invalidSurfaceState,
                message:
                    "wl_surface already has an XDG construction or committed state")
            return
        }
        guard unsafe id.create(
            owner: { handle in
                XdgSurface(
                    resource: handle,
                    shell: shell,
                    surface: surface,
                    wmBaseResource: resource)
            },
            installed: { xdgSurface in
                surface.bindXdgConstructionRole(xdgSurface)
            }
        ) != nil else {
            surface.releaseXdgConstruction()
            return
        }
    }

    func pong(_ request: WaylandRequest<XdgWmBaseServer>, serial: UInt32) {}  // liveness ack — no state to track
}
