import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Wire request decoding for `wl_surface`. Validation that depends only on the
/// request and negotiated protocol version stays here; accepted mutations are
/// submitted to the surface transaction aggregate.
extension WlSurface: WlSurfaceRequests {
    func attach(
        _ resource: UnsafeMutablePointer<wl_resource>,
        buffer: UnsafeMutablePointer<wl_resource>?,
        x: Int32,
        y: Int32
    ) {
        if version >= 5, x != 0 || y != 0 {
            swift_wayland_resource_post_error(
                resource, 3,
                "non-zero attach offset is invalid at wl_surface v5+")
            return
        }
        attach(buffer: buffer, x: x, y: y)
    }

    func damage(
        _ resource: UnsafeMutablePointer<wl_resource>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        addSurfaceDamage(WlRect(
            x: x, y: y, width: width, height: height))
    }

    func damageBuffer(
        _ resource: UnsafeMutablePointer<wl_resource>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        addBufferDamage(WlRect(
            x: x, y: y, width: width, height: height))
    }

    func frame(
        _ resource: UnsafeMutablePointer<wl_resource>,
        callback: WlNewId
    ) {
        guard let callback = callback.createBare() else { return }
        addFrameCallback(callback)
    }

    func setOpaqueRegion(
        _ resource: UnsafeMutablePointer<wl_resource>,
        region: UnsafeMutablePointer<wl_resource>?
    ) {
        setOpaqueRegion(Self.regionSnapshot(region))
    }

    func setInputRegion(
        _ resource: UnsafeMutablePointer<wl_resource>,
        region: UnsafeMutablePointer<wl_resource>?
    ) {
        setInputRegion(Self.regionSnapshot(region))
    }

    func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
        _ = commit()
    }

    func offset(
        _ resource: UnsafeMutablePointer<wl_resource>,
        x: Int32,
        y: Int32
    ) {
        // wl_surface.offset does not affect subsurface position.
        guard subsurfaceParent == nil else { return }
        setOffset(x: x, y: y)
    }

    func getRelease(
        _ resource: UnsafeMutablePointer<wl_resource>,
        callback: WlNewId
    ) {
        installPendingReleaseCallback(
            callback, postingErrorsTo: resource)
    }

    func setBufferScale(
        _ resource: UnsafeMutablePointer<wl_resource>,
        scale: Int32
    ) {
        guard scale >= 1 else {
            swift_wayland_resource_post_error(
                resource, 0, "buffer scale must be at least one")
            return
        }
        setBufferScale(scale)
    }

    func setBufferTransform(
        _ resource: UnsafeMutablePointer<wl_resource>,
        transform: Int32
    ) {
        guard (0...7).contains(transform) else {
            swift_wayland_resource_post_error(
                resource, 1, "invalid buffer transform")
            return
        }
        setBufferTransform(transform)
    }

    private static func regionSnapshot(
        _ resource: UnsafeMutablePointer<wl_resource>?
    ) -> RegionSnapshot? {
        guard let resource,
              let region = WaylandResource.owner(
                of: resource, as: WlRegion.self)
        else { return nil }
        return region.snapshot()
    }
}

extension WlCompositor {
    /// Create a wl_surface resource bound to one transaction aggregate.
    @MainActor
    func makeSurface(
        client: OpaquePointer,
        id: UInt32,
        version: Int32
    ) -> UnsafeMutablePointer<wl_resource>? {
        let surface = WlSurface(
            compositor: self,
            pointerCursorSurface: host.pointerCursorSurface,
            version: version,
            stableObjectId: allocateSurfaceIdentity(
                preferred: id))
        guard let resource = WaylandResource.create(
            client: client,
            interface: swift_wayland_iface_wl_surface(),
            version: version,
            id: id,
            vtable: WlSurfaceServer.vtable,
            owner: surface)
        else { return nil }
        surface.bind(resource: resource)
        registerSurface(surface)
        return resource
    }
}
