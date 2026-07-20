// wp_linux_drm_syncobj_manager_v1 on the router. Lets a client drive explicit GPU
// synchronization for a surface: it imports DRM syncobj timelines and, per commit,
// names an acquire point (the compositor waits for it before sampling the buffer)
// and a release point (the compositor signals it when done). The acquire/release
// points are double-buffered, latched on wl_surface.commit. The router owns the
// protocol mechanics + validation; the DRM side (delegate) imports timelines and
// materializes the fences.
//
// One syncobj surface per wl_surface
// (surface_exists); commit-time validation enforces no_buffer / no_acquire_point /
// no_release_point / conflicting_points.

import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// A named point on a DRM syncobj timeline: the imported handle plus the 64-bit point.
struct SyncPoint: Equatable, Sendable {
    var handle: UInt32
    var point: UInt64
}

/// The DRM seam. importTimeline turns a syncobj fd into a kernel handle (nil =
/// invalid); applied surface transactions hand materialized acquire/release points
/// to the renderer import and retirement paths.
protocol DrmSyncobjDelegate: AnyObject {
    func importSyncobjTimeline(fd: Int32) -> UInt32?
    func destroySyncobjTimeline(handle: UInt32)
}

final class WpLinuxDrmSyncobjManager {
    weak var delegate: DrmSyncobjDelegate?

    // wp_linux_drm_syncobj_timeline_v1 is destroy-only (no generated dispatch): its
    // request vtable stays hand-wired and is passed to id.create when a timeline is
    // materialized in importTimeline.
    private let timelineVtable: UnsafeMutableRawPointer

    init() {
        timelineVtable = allocVtable(
            MemoryLayout<swift_wayland_wp_linux_drm_syncobj_timeline_v1_requests>.stride,
            MemoryLayout<swift_wayland_wp_linux_drm_syncobj_timeline_v1_requests>.alignment)
        let tvt = timelineVtable.bindMemory(
            to: swift_wayland_wp_linux_drm_syncobj_timeline_v1_requests.self, capacity: 1)
        tvt.pointee.destroy = WpDrmSyncobjTimeline.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_linux_drm_syncobj_manager_v1(), version: 1,
            impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpLinuxDrmSyncobjManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_linux_drm_syncobj_manager_v1(),
            version: Int32(version), id: id, vtable: WpLinuxDrmSyncobjManagerV1Server.vtable, owner: me)
    }

    deinit {
        timelineVtable.deallocate()
    }
}

extension WpLinuxDrmSyncobjManager: WpLinuxDrmSyncobjManagerV1Requests {
    // import_timeline(id, fd): import the syncobj fd into a kernel handle.
    func importTimeline(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId, fd: Int32) {
        let handle = delegate?.importSyncobjTimeline(fd: fd)
        if fd >= 0 { close(fd) }  // the import consumes the fd; DRM holds the handle
        guard let handle, handle != 0 else {
            swift_wayland_resource_post_error(resource, 1, "cannot import drm syncobj timeline")  // invalid_timeline
            return
        }
        let timeline = WpDrmSyncobjTimeline(handle: handle) { [self] handle in
            delegate?.destroySyncobjTimeline(handle: handle)
        }
        // Timeline is destroy-only: materialize with its hand-wired request vtable.
        _ = id.create(vtable: UnsafeRawPointer(timelineVtable), owner: timeline)
    }

    // get_surface(id, surface): one syncobj surface per wl_surface (surface_exists = 0).
    func getSurface(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.syncobj) else {
            swift_wayland_resource_post_error(resource, 0, "surface already has a syncobj surface")  // surface_exists
            return
        }
        let object = WpDrmSyncobjSurface(surface: surface)
        guard let ores = id.create(vtable: WpLinuxDrmSyncobjSurfaceV1Server.vtable, owner: object) else {
            surface.releaseAux(.syncobj)
            return
        }
        object.bind(ores)
        surface.addCommitObserver(object)
    }
}

/// wp_linux_drm_syncobj_timeline_v1 owner (Rule 9): a DRM syncobj handle.
final class WpDrmSyncobjTimeline {
    let handle: UInt32
    private let destroy: (UInt32) -> Void
    init(handle: UInt32, destroy: @escaping (UInt32) -> Void) {
        self.handle = handle
        self.destroy = destroy
    }

    fileprivate static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit { destroy(handle) }
}

/// wp_linux_drm_syncobj_surface_v1 owner (Rule 9). Double-buffered acquire/release
/// points latched and validated on the surface's commit.
final class WpDrmSyncobjSurface: WlSurfaceCommitObserver {
    private weak let surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var pendingAcquire: SyncPoint?
    private var pendingRelease: SyncPoint?

    init(surface: WlSurface) {
        self.surface = surface
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    func captureSurfaceCommit(
        _ surface: WlSurface,
        bufferAttached: Bool,
        attachedBufferIsNonNull: Bool,
        attachedBufferSupportsExplicitSync: Bool,
        aux: inout SurfaceAuxState,
        effects: inout [() -> Void]
    ) -> Bool {
        let hasPoint = pendingAcquire != nil || pendingRelease != nil
        defer { pendingAcquire = nil; pendingRelease = nil }
        guard let res = resource else { return false }

        // Points and one newly attached non-null buffer are an iff contract.
        guard bufferAttached, attachedBufferIsNonNull else {
            guard !hasPoint else {
                swift_wayland_resource_post_error(
                    res, 3, "sync points require a non-null attached buffer")
                return false
            }
            return true
        }
        guard attachedBufferSupportsExplicitSync else {
            swift_wayland_resource_post_error(
                res, 2, "attached buffer does not support explicit synchronization")
            return false
        }
        guard let acquire = pendingAcquire else {
            swift_wayland_resource_post_error(res, 4, "no acquire point set")  // no_acquire_point
            return false
        }
        guard let release = pendingRelease else {
            swift_wayland_resource_post_error(res, 5, "no release point set")  // no_release_point
            return false
        }
        if acquire.handle == release.handle, acquire.point >= release.point {
            swift_wayland_resource_post_error(
                res, 6, "acquire point not before release point")  // conflicting_points
            return false
        }
        aux.syncAcquire = acquire
        aux.syncRelease = release
        return true
    }

    deinit { surface?.releaseAux(.syncobj) }
}

extension WpDrmSyncobjSurface: WpLinuxDrmSyncobjSurfaceV1Requests {
    // set_acquire_point(timeline, point_hi, point_lo)
    func setAcquirePoint(
        _ resource: UnsafeMutablePointer<wl_resource>,
        timeline timelineRes: UnsafeMutablePointer<wl_resource>?, point_hi hi: UInt32, point_lo lo: UInt32
    ) {
        guard surface != nil else {
            swift_wayland_resource_post_error(resource, 1, "wl_surface was destroyed")  // no_surface
            return
        }
        guard let timelineRes,
            let timeline = WaylandResource.owner(of: timelineRes, as: WpDrmSyncobjTimeline.self)
        else { return }
        pendingAcquire = SyncPoint(handle: timeline.handle, point: (UInt64(hi) << 32) | UInt64(lo))
    }

    // set_release_point(timeline, point_hi, point_lo)
    func setReleasePoint(
        _ resource: UnsafeMutablePointer<wl_resource>,
        timeline timelineRes: UnsafeMutablePointer<wl_resource>?, point_hi hi: UInt32, point_lo lo: UInt32
    ) {
        guard surface != nil else {
            swift_wayland_resource_post_error(resource, 1, "wl_surface was destroyed")  // no_surface
            return
        }
        guard let timelineRes,
            let timeline = WaylandResource.owner(of: timelineRes, as: WpDrmSyncobjTimeline.self)
        else { return }
        pendingRelease = SyncPoint(handle: timeline.handle, point: (UInt64(hi) << 32) | UInt64(lo))
    }
}
