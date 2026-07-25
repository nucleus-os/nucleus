// xwayland_shell_v1 on the router. Xwayland — attached to the router as a client
// through `nucleus_runtime_router_create_client` at the socket handover — binds
// this singleton to associate each X11 window to a router wl_surface by a 64-bit
// serial. `get_xwayland_surface` attaches an xwayland_surface_v1 role to a
// wl_surface; `set_serial` records the serial (double-buffered); the surface's
// first post-serial commit reports the (serial, surfaceObjectId) pairing directly
// to the owning runtime's Swift XWM,
// which resolves it against the X11 window the XWM parked under the same serial and
// drives router Window creation.
//
// The whole Xwayland stack (XWM, property reads, X listen sockets, process
// supervision) is Swift now; this owns only the
// wayland-side association. No-ops before Xwayland attaches to the router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

@MainActor
@safe final class XwaylandShellManager {
    private unowned let host: RouterHost

    init(host: RouterHost) {
        self.host = host
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            XwaylandShellV1Server.global(
                implementation: self,
                owner: { manager, _ in manager }))
    }
}

extension XwaylandShellManager: XwaylandShellV1Requests {
    // get_xwayland_surface(id, surface): attach the xwayland_surface role.
    // The manager is its own resource owner (owner: me on bind).
    func getXwaylandSurface(
        _ request: WaylandRequest<XwaylandShellV1Server>,
        id: WlNewId<XwaylandSurfaceV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surface.owner(as: WlSurface.self) else { return }
        guard !surface.hasRole else {
            request.postError(.role, message: "surface already has a role")
            return
        }
        _ = unsafe id.create(
            owner: { handle in
                XwaylandSurfaceRole(
                    resource: handle, surface: surface, host: host)
            },
            installed: { role in
                precondition(surface.assignRole(role))
            })
    }
}

/// xwayland_surface_v1 owner (Rule 9): the per-window association role. Records the
/// pairing serial (double-buffered) and reports it to the XWM on the first
/// post-serial commit.
@MainActor
@safe final class XwaylandSurfaceRole: WlSurfaceRole {
    private unowned let host: RouterHost
    private weak var surface: WlSurface?
    private let resource: WaylandResourceHandle<XwaylandSurfaceV1Server>
    /// Serial set since the last commit, latched into `serial` on commit.
    private var pendingSerial: UInt64?
    private var serial: UInt64?
    /// True once a serial has committed; a second set_serial commit is the
    /// `already_associated` protocol error.
    private var serialCommitted = false

    init(
        resource: WaylandResourceHandle<XwaylandSurfaceV1Server>,
        surface: WlSurface,
        host: RouterHost
    ) {
        self.resource = resource
        self.surface = surface
        self.host = host
    }
    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {
        guard let pending = pendingSerial else { return }
        pendingSerial = nil
        if serialCommitted {
            resource.postError(
                .alreadyAssociated,
                message: "wl_surface already associated")
            return
        }
        serial = pending
        serialCommitted = true
        let surfaceObjectId = UInt64(surface.objectId)
        _ = host.xwaylandHost?.xwm?.tryAssociateRouterSurfaceBySerial(
            pending, surfaceObjectId)
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }
}

extension XwaylandSurfaceRole: XwaylandSurfaceV1Requests {
    // set_serial(serial_lo, serial_hi): double-buffered, latched on commit.
    func setSerial(_ request: WaylandRequest<XwaylandSurfaceV1Server>, serial_lo lo: UInt32, serial_hi hi: UInt32) {
        let serial = (UInt64(hi) << 32) | UInt64(lo)
        guard serial != 0 else {
            request.postError(.invalidSerial, message: "serial was not valid")
            return
        }
        pendingSerial = serial
    }
}
