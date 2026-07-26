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
import WaylandProtocolTypes

/// A named point on a DRM syncobj timeline: the imported handle plus the 64-bit point.
struct SyncPoint: Equatable, Sendable {
    var handle: UInt32
    var point: UInt64
}

/// The DRM seam. importTimeline turns a syncobj fd into a kernel handle (nil =
/// invalid); applied surface transactions hand materialized acquire/release points
/// to the renderer import and retirement paths.
@MainActor
protocol DrmSyncobjDelegate: AnyObject {
    func importSyncobjTimeline(fd: Int32) -> UInt32?
    func destroySyncobjTimeline(handle: UInt32)
}

@MainActor
@safe final class WpLinuxDrmSyncobjManager {
    weak var delegate: (any DrmSyncobjDelegate)?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            WpLinuxDrmSyncobjManagerV1Server.global(
                implementation: self))
    }
}

extension WpLinuxDrmSyncobjManager: WpLinuxDrmSyncobjManagerV1Requests {
    // import_timeline(id, fd): import the syncobj fd into a kernel handle.
    func importTimeline(
        _ request: WaylandRequest<WpLinuxDrmSyncobjManagerV1Server>,
        id: WlNewId<WpLinuxDrmSyncobjTimelineV1Server>,
        fd: consuming WaylandOwnedFileDescriptor
    ) {
        let rawFD = fd.take()
        let handle = delegate?.importSyncobjTimeline(fd: rawFD)
        if rawFD >= 0 { close(rawFD) }  // the import consumes the fd; DRM holds the handle
        guard let handle, handle != 0 else {
            request.postError(
                .invalidTimeline,
                message: "cannot import drm syncobj timeline")
            return
        }
        _ = id.create { resource in
            WpDrmSyncobjTimeline(
                resource: resource,
                handle: handle
            ) { [self] handle in
                delegate?.destroySyncobjTimeline(handle: handle)
            }
        }
    }

    // get_surface(id, surface): one syncobj surface per wl_surface (surface_exists = 0).
    func getSurface(
        _ request: WaylandRequest<WpLinuxDrmSyncobjManagerV1Server>,
        id: WlNewId<WpLinuxDrmSyncobjSurfaceV1Server>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard surface.claimAux(.syncobj) else {
            request.postError(
                .surfaceExists,
                message: "surface already has a syncobj surface")
            return
        }
        guard id.create(
            owner: { handle in
                WpDrmSyncobjSurface(resource: handle, surface: surface)
            },
            installed: { object in
                surface.addCommitObserver(object)
            }
        ) != nil else {
            surface.releaseAux(.syncobj)
            return
        }
    }
}

/// wp_linux_drm_syncobj_timeline_v1 owner (Rule 9): a DRM syncobj handle.
@MainActor
@safe final class WpDrmSyncobjTimeline {
    private let resource:
        WaylandResourceHandle<WpLinuxDrmSyncobjTimelineV1Server>
    let handle: UInt32
    private let destroy: (UInt32) -> Void
    init(
        resource:
            WaylandResourceHandle<WpLinuxDrmSyncobjTimelineV1Server>,
        handle: UInt32,
        destroy: @escaping (UInt32) -> Void
    ) {
        self.resource = resource
        self.handle = handle
        self.destroy = destroy
    }

    isolated deinit { destroy(handle) }
}

/// wp_linux_drm_syncobj_surface_v1 owner (Rule 9). Double-buffered acquire/release
/// points latched and validated on the surface's commit.
@MainActor
@safe final class WpDrmSyncobjSurface: WlSurfaceCommitObserver {
    private weak let surface: WlSurface?
    private let resource:
        WaylandResourceHandle<WpLinuxDrmSyncobjSurfaceV1Server>
    private var pendingAcquire: SyncPoint?
    private var pendingRelease: SyncPoint?

    init(
        resource:
            WaylandResourceHandle<WpLinuxDrmSyncobjSurfaceV1Server>,
        surface: WlSurface
    ) {
        self.resource = resource
        self.surface = surface
    }

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

        // Points and one newly attached non-null buffer are an iff contract.
        guard bufferAttached, attachedBufferIsNonNull else {
            guard !hasPoint else {
                resource.postError(
                    .noBuffer,
                    message: "sync points require a non-null attached buffer")
                return false
            }
            return true
        }
        guard attachedBufferSupportsExplicitSync else {
            resource.postError(
                .unsupportedBuffer,
                message: "attached buffer does not support explicit synchronization")
            return false
        }
        guard let acquire = pendingAcquire else {
            resource.postError(
                .noAcquirePoint,
                message: "no acquire point set")
            return false
        }
        guard let release = pendingRelease else {
            resource.postError(
                .noReleasePoint,
                message: "no release point set")
            return false
        }
        if acquire.handle == release.handle, acquire.point >= release.point {
            resource.postError(
                .conflictingPoints,
                message: "acquire point not before release point")
            return false
        }
        aux.syncAcquire = acquire
        aux.syncRelease = release
        return true
    }

    isolated deinit { surface?.releaseAux(.syncobj) }
}

extension WpDrmSyncobjSurface: WpLinuxDrmSyncobjSurfaceV1Requests {
    // set_acquire_point(timeline, point_hi, point_lo)
    func setAcquirePoint(
        _ request: WaylandRequest<WpLinuxDrmSyncobjSurfaceV1Server>,
        timeline timelineRes: WaylandBorrowedObject<WpLinuxDrmSyncobjTimelineV1Server>, point_hi hi: UInt32, point_lo lo: UInt32
    ) {
        guard surface != nil else {
            request.postError(.noSurface, message: "wl_surface was destroyed")
            return
        }
        guard let timeline = timelineRes.owner(as: WpDrmSyncobjTimeline.self) else { return }
        pendingAcquire = SyncPoint(handle: timeline.handle, point: (UInt64(hi) << 32) | UInt64(lo))
    }

    // set_release_point(timeline, point_hi, point_lo)
    func setReleasePoint(
        _ request: WaylandRequest<WpLinuxDrmSyncobjSurfaceV1Server>,
        timeline timelineRes: WaylandBorrowedObject<WpLinuxDrmSyncobjTimelineV1Server>, point_hi hi: UInt32, point_lo lo: UInt32
    ) {
        guard surface != nil else {
            request.postError(.noSurface, message: "wl_surface was destroyed")
            return
        }
        guard let timeline = timelineRes.owner(as: WpDrmSyncobjTimeline.self) else { return }
        pendingRelease = SyncPoint(handle: timeline.handle, point: (UInt64(hi) << 32) | UInt64(lo))
    }
}
