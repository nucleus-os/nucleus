// wp_fifo_manager_v1 on the router. Lets a client mark a surface's commits with
// FIFO barriers so the compositor paces updates to the display refresh without the
// client busy-waiting. The barrier flags are per-commit double-buffered surface
// state (the router owns this timing — boundary plan line 205); the presentation
// path enforces the FIFO constraint at #12.
//
// A second get_fifo for one surface raises
// already_exists; set_barrier/wait_barrier after the surface is gone raise
// surface_destroyed.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class WpFifoManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_fifo_manager_v1(), version: 1, impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpFifoManager.self) else {
            return
        }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_fifo_manager_v1(),
            version: Int32(version), id: id, vtable: WpFifoManagerV1Server.vtable, owner: me
        )
    }
}

extension WpFifoManager: WpFifoManagerV1Requests {
    func getFifo(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.fifo) else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface already has a fifo")  // already_exists
            return
        }
        let fifo = WpFifo(surface: surface)
        guard let fres = id.create(vtable: WpFifoV1Server.vtable, owner: fifo) else {
            surface.releaseAux(.fifo)
            return
        }
        fifo.bind(fres)
    }
}

/// wp_fifo_v1 resource owner (Rule 9). Marks the surface's pending barrier flags.
final class WpFifo {
    private weak var surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(surface: WlSurface) { self.surface = surface }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit { if let surface { surface.releaseAux(.fifo) } }
}

extension WpFifo: WpFifoV1Requests {
    func setBarrier(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard let surface else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface was destroyed")  // surface_destroyed
            return
        }
        surface.markPendingFifoBarrier()
    }

    func waitBarrier(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard let surface else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface was destroyed")  // surface_destroyed
            return
        }
        surface.markPendingFifoWaitBarrier()
    }
}
