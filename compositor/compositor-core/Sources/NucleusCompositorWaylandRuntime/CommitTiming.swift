// wp_commit_timing_manager_v1 on the router. Lets a client set a target
// presentation timestamp for a surface's next commit (timed content updates,
// e.g. media playback). The timestamp is per-commit double-buffered surface
// state (the router owns timing — boundary plan line 205); the presentation path
// schedules against it at #12.
//
// A second get_timer for one surface
// raises commit_timer_exists; set_timestamp validates the nanosecond field and
// rejects a second timestamp before the commit consumes the first.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class WpCommitTimingManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_commit_timing_manager_v1(), version: 1,
            impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpCommitTimingManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_commit_timing_manager_v1(),
            version: Int32(version), id: id, vtable: WpCommitTimingManagerV1Server.vtable, owner: me
        )
    }
}

extension WpCommitTimingManager: WpCommitTimingManagerV1Requests {
    func getTimer(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.commitTimer) else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface already has a commit timer")
            return
        }
        let timer = WpCommitTimer(surface: surface)
        guard let tres = id.create(vtable: WpCommitTimerV1Server.vtable, owner: timer) else {
            surface.releaseAux(.commitTimer)
            return
        }
        timer.bind(tres)
    }
}

/// wp_commit_timer_v1 resource owner (Rule 9). Writes the surface's pending target.
final class WpCommitTimer {
    private weak var surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(surface: WlSurface) { self.surface = surface }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit { if let surface { surface.releaseAux(.commitTimer) } }
}

extension WpCommitTimer: WpCommitTimerV1Requests {
    // set_timestamp(tv_sec_hi, tv_sec_lo, tv_nsec). Errors: invalid_timestamp = 0,
    // timestamp_exists = 1, surface_destroyed = 2.
    func setTimestamp(
        _ resource: UnsafeMutablePointer<wl_resource>,
        tv_sec_hi: UInt32, tv_sec_lo: UInt32, tv_nsec: UInt32
    ) {
        guard let surface else {
            swift_wayland_resource_post_error(resource, 2, "wl_surface was destroyed")  // surface_destroyed
            return
        }
        guard tv_nsec < 1_000_000_000 else {
            swift_wayland_resource_post_error(resource, 0, "tv_nsec out of range")  // invalid_timestamp
            return
        }
        guard !surface.hasPendingCommitTimestamp else {
            swift_wayland_resource_post_error(resource, 1, "timestamp already set this commit")  // timestamp_exists
            return
        }
        let secs = (UInt64(tv_sec_hi) << 32) | UInt64(tv_sec_lo)
        surface.setPendingCommitTimestamp(secs &* 1_000_000_000 &+ UInt64(tv_nsec))
    }
}
