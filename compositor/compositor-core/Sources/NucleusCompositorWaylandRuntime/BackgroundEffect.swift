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
import WaylandProtocolTypes

/// The render seam for ext-background-effect. `region` nil = no blur.
@MainActor
protocol BackgroundEffectDelegate: AnyObject {
    func backgroundBlurRegionUpdated(surfaceID: UInt32, region: RegionSnapshot?)
}

@MainActor
final class ExtBackgroundEffectManager {
    weak var delegate: (any BackgroundEffectDelegate)?
    /// Advertised capability bitfield (capability.blur = 1).
    var capabilities: UInt32 = 1

    fileprivate func publish(surfaceID: UInt32, region: RegionSnapshot?) {
        delegate?.backgroundBlurRegionUpdated(surfaceID: surfaceID, region: region)
    }
}

extension ExtBackgroundEffectManager: ExtBackgroundEffectManagerV1Requests {
    // get_background_effect(id, surface): one per surface (background_effect_exists = 0).
    func getBackgroundEffect(
        _ request: WaylandRequest<ExtBackgroundEffectManagerV1Server>,
        id: WlNewId<ExtBackgroundEffectSurfaceV1Server>,
                             surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard surface.claimAux(.backgroundEffect) else {
            request.postError(.backgroundEffectExists, message: "surface already has a background effect")
            return
        }
        guard id.create(
            owner: { handle in
                ExtBackgroundEffectSurface(
                    resource: handle,
                    manager: self,
                    surface: surface)
            },
            installed: { object in
                surface.addCommitObserver(object)
            }) != nil
        else {
            surface.releaseAux(.backgroundEffect)
            return
        }
    }
}

/// ext_background_effect_surface_v1 owner (Rule 9). Double-buffered blur region:
/// set_blur_region writes pending, latched and published on the surface's commit.
@MainActor
final class ExtBackgroundEffectSurface: WlSurfaceCommitObserver {
    private let resource:
        WaylandResourceHandle<ExtBackgroundEffectSurfaceV1Server>
    private weak var manager: ExtBackgroundEffectManager?
    private weak var surface: WlSurface?
    private var pendingRegion: RegionSnapshot?
    private var pendingSet = false

    init(
        resource: WaylandResourceHandle<ExtBackgroundEffectSurfaceV1Server>,
        manager: ExtBackgroundEffectManager,
        surface: WlSurface
    ) {
        self.resource = resource
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

    isolated deinit { surface?.releaseAux(.backgroundEffect) }
}

extension ExtBackgroundEffectSurface: ExtBackgroundEffectSurfaceV1Requests {
    // set_blur_region(region): null region = no blur.
    func setBlurRegion(_ request: WaylandRequest<ExtBackgroundEffectSurfaceV1Server>,
                       region regionRes: WaylandBorrowedObject<WlRegionServer>?) {
        guard surface != nil else {
            request.postError(.surfaceDestroyed, message: "wl_surface was destroyed")  // surface_destroyed
            return
        }
        if let region = regionRes?.owner(as: WlRegion.self) {
            pendingRegion = region.snapshot()
        } else {
            pendingRegion = nil
        }
        pendingSet = true
    }
}
