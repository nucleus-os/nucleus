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

final class XwaylandShellManager {
    private unowned let host: RouterHost

    init(host: RouterHost) {
        self.host = host
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_xwayland_shell_v1(), version: 1,
            impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XwaylandShellManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_xwayland_shell_v1(),
            version: Int32(version), id: id, vtable: XwaylandShellV1Server.vtable, owner: me)
    }
}

extension XwaylandShellManager: XwaylandShellV1Requests {
    // get_xwayland_surface(id, surface): attach the xwayland_surface role.
    // The manager is its own resource owner (owner: me on bind).
    func getXwaylandSurface(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                            surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard !surface.hasRole else {
            swift_wayland_resource_post_error(resource, 0, "surface already has a role")  // role
            return
        }
        let role = XwaylandSurfaceRole(surface: surface, host: host)
        surface.assignRole(role)
        guard let xres = id.create(vtable: XwaylandSurfaceV1Server.vtable, owner: role) else { return }
        role.bind(xres)
    }
}

/// xwayland_surface_v1 owner (Rule 9): the per-window association role. Records the
/// pairing serial (double-buffered) and reports it to the XWM on the first
/// post-serial commit.
final class XwaylandSurfaceRole: WlSurfaceRole {
    private unowned let host: RouterHost
    private weak var surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?
    /// Serial set since the last commit, latched into `serial` on commit.
    private var pendingSerial: UInt64?
    private var serial: UInt64?
    /// True once a serial has committed; a second set_serial commit is the
    /// `already_associated` protocol error.
    private var serialCommitted = false

    init(surface: WlSurface, host: RouterHost) {
        self.surface = surface
        self.host = host
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {
        guard let pending = pendingSerial else { return }
        pendingSerial = nil
        if serialCommitted {
            if let res = resource {
                swift_wayland_resource_post_error(res, 0, "wl_surface already associated")  // already_associated
            }
            return
        }
        serial = pending
        serialCommitted = true
        let surfaceObjectId = UInt64(surface.objectId)
        let hostBits = UInt(bitPattern: Unmanaged.passUnretained(host).toOpaque())
        // The router dispatch runs single-threaded on the compositor main actor. The
        // pairing is handed directly to the XWM.
        MainActor.assumeIsolated {
            guard let hostPointer = UnsafeRawPointer(bitPattern: hostBits) else { return }
            let host = Unmanaged<RouterHost>.fromOpaque(hostPointer)
                .takeUnretainedValue()
            _ = host.xwaylandHost?.xwm?.tryAssociateRouterSurfaceBySerial(
                pending, surfaceObjectId)
        }
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }
}

extension XwaylandSurfaceRole: XwaylandSurfaceV1Requests {
    // set_serial(serial_lo, serial_hi): double-buffered, latched on commit.
    func setSerial(_ resource: UnsafeMutablePointer<wl_resource>, serial_lo lo: UInt32, serial_hi hi: UInt32) {
        let serial = (UInt64(hi) << 32) | UInt64(lo)
        guard serial != 0 else {
            swift_wayland_resource_post_error(resource, 1, "serial was not valid")  // invalid_serial
            return
        }
        pendingSerial = serial
    }
}
