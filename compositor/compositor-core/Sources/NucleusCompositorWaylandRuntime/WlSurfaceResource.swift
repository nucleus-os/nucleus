import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
import NucleusRenderModel

/// Wire request decoding for `wl_surface`. Validation that depends only on the
/// request and negotiated protocol version stays here; accepted mutations are
/// submitted to the surface transaction aggregate.
extension WlSurface: WlSurfaceRequests {
    func attach(
        _ request: WaylandRequest<WlSurfaceServer>,
        buffer: WaylandBorrowedObject<WlBufferServer>?,
        x: Int32,
        y: Int32
    ) {
        if version >= 5, x != 0 || y != 0 {
            request.postError(.invalidOffset, message: "non-zero attach offset is invalid at wl_surface v5+")
            return
        }
        attach(buffer: buffer, x: x, y: y)
    }

    func damage(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        addSurfaceDamage(WlRect(
            x: x, y: y, width: width, height: height))
    }

    func damageBuffer(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        addBufferDamage(WlRect(
            x: x, y: y, width: width, height: height))
    }

    func frame(
        _ request: WaylandRequest<WlSurfaceServer>,
        callback: WlNewId<WlCallbackServer>
    ) {
        guard let callback = callback.createBare() else { return }
        addFrameCallback(callback)
    }

    func setOpaqueRegion(
        _ request: WaylandRequest<WlSurfaceServer>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {
        setOpaqueRegion(Self.regionSnapshot(region))
    }

    func setInputRegion(
        _ request: WaylandRequest<WlSurfaceServer>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {
        setInputRegion(Self.regionSnapshot(region))
    }

    func commit(_ request: WaylandRequest<WlSurfaceServer>) {
        _ = commit()
    }

    func offset(
        _ request: WaylandRequest<WlSurfaceServer>,
        x: Int32,
        y: Int32
    ) {
        // wl_surface.offset does not affect subsurface position.
        guard subsurfaceParent == nil else { return }
        setOffset(x: x, y: y)
    }

    func getRelease(
        _ request: WaylandRequest<WlSurfaceServer>,
        callback: WlNewId<WlCallbackServer>
    ) {
        guard unsafe installPendingReleaseCallback(callback) else {
            request.postError(
                .noBuffer,
                message: "get_release without an attached buffer")
            return
        }
    }

    func setBufferScale(
        _ request: WaylandRequest<WlSurfaceServer>,
        scale: Int32
    ) {
        guard scale >= 1 else {
            request.postError(.invalidScale, message: "buffer scale must be at least one")
            return
        }
        setBufferScale(scale)
    }

    func setBufferTransform(
        _ request: WaylandRequest<WlSurfaceServer>,
        transform: WlOutputTransform
    ) {
        guard transform.rawValue <= 7 else {
            request.postError(.invalidTransform, message: "invalid buffer transform")
            return
        }
        setBufferTransform(Int32(bitPattern: transform.rawValue))
    }

    private static func regionSnapshot(
        _ regionObject: WaylandBorrowedObject<WlRegionServer>?
    ) -> RegionSnapshot? {
        regionObject?.owner(as: WlRegion.self)?.snapshot()
    }
}

extension WlCompositor {
    /// Create a wl_surface resource bound to one transaction aggregate.
    @MainActor
    func makeSurface(
        id: WlNewId<WlSurfaceServer>
    ) -> WlSurface? {
        id.create(
            owner: { handle in
                WlSurface(
                    resource: handle,
                    compositor: self,
                    pointerCursorSurface: self.host.pointerCursorSurface,
                    version: id.version,
                    stableObjectId: self.allocateSurfaceIdentity(
                        preferred: id.id))
            },
            installed: { surface in
                self.registerSurface(surface)
                surface.sendInitialPreferredScale()
            })
    }
}
