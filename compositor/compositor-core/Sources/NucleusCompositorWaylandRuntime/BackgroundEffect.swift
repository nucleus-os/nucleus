// ext_background_effect_manager_v1 on the router. The staging successor to KDE
// blur: a client requests a background blur region for a surface, double-buffered
// with the surface's content (latched on wl_surface.commit via the surface's
// commit-observer seam). The manager advertises its capabilities on bind.
//
// The router owns the request/latch mechanics and publishes the committed region
// through SceneFeeder into the renderer's backdrop-effect plan.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The render seam for ext-background-effect. `region` nil = no blur.
protocol BackgroundEffectDelegate: AnyObject {
    func backgroundBlurRegionUpdated(surfaceID: UInt32, region: RegionSnapshot?)
}

final class ExtBackgroundEffectManager {
    weak var delegate: (any BackgroundEffectDelegate)?
    /// Advertised capability bitfield (capability.blur = 1).
    var capabilities: UInt32 = 1

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_ext_background_effect_manager_v1(), version: 1,
            impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: ExtBackgroundEffectManager.self)
        else { return }
        guard let res = WaylandResource.create(
            client: client, interface: swift_wayland_iface_ext_background_effect_manager_v1(),
            version: Int32(version), id: id, vtable: ExtBackgroundEffectManagerV1Server.vtable, owner: me)
        else { return }
        // Advertise supported effects immediately on bind.
        ext_background_effect_manager_v1_send_capabilities(res, me.capabilities)
    }

    fileprivate func publish(surfaceID: UInt32, region: RegionSnapshot?) {
        delegate?.backgroundBlurRegionUpdated(surfaceID: surfaceID, region: region)
    }
}

extension ExtBackgroundEffectManager: ExtBackgroundEffectManagerV1Requests {
    // get_background_effect(id, surface): one per surface (background_effect_exists = 0).
    func getBackgroundEffect(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                             surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.backgroundEffect) else {
            swift_wayland_resource_post_error(resource, 0, "surface already has a background effect")
            return
        }
        let object = ExtBackgroundEffectSurface(manager: self, surface: surface)
        guard id.create(vtable: ExtBackgroundEffectSurfaceV1Server.vtable, owner: object) != nil
        else {
            surface.releaseAux(.backgroundEffect)
            return
        }
        surface.addCommitObserver(object)
    }
}

/// ext_background_effect_surface_v1 owner (Rule 9). Double-buffered blur region:
/// set_blur_region writes pending, latched and published on the surface's commit.
final class ExtBackgroundEffectSurface: WlSurfaceCommitObserver {
    private weak var manager: ExtBackgroundEffectManager?
    private weak var surface: WlSurface?
    private var pendingRegion: RegionSnapshot?
    private var pendingSet = false

    init(manager: ExtBackgroundEffectManager, surface: WlSurface) {
        self.manager = manager
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
        guard pendingSet else { return true }
        let region = pendingRegion
        let surfaceID = surface.objectId
        pendingSet = false
        effects.append { [weak manager] in
            manager?.publish(surfaceID: surfaceID, region: region)
        }
        return true
    }

    deinit { surface?.releaseAux(.backgroundEffect) }
}

extension ExtBackgroundEffectSurface: ExtBackgroundEffectSurfaceV1Requests {
    // set_blur_region(region): null region = no blur.
    func setBlurRegion(_ resource: UnsafeMutablePointer<wl_resource>,
                       region regionRes: UnsafeMutablePointer<wl_resource>?) {
        guard surface != nil else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface was destroyed")  // surface_destroyed
            return
        }
        if let regionRes, let region = WaylandResource.owner(of: regionRes, as: WlRegion.self) {
            pendingRegion = region.snapshot()
        } else {
            pendingRegion = nil
        }
        pendingSet = true
    }
}
