// wp_alpha_modifier_v1 on the router. The multiplier is ordinary
// double-buffered surface state: requests update pending state and
// wl_surface.commit latches it atomically with buffer, damage, regions,
// viewport, and explicit synchronization.

import WaylandServer
import WaylandServerDispatch

@MainActor
final class WpAlphaModifierManager {
}

extension WpAlphaModifierManager: WpAlphaModifierV1Requests {
    func getSurface(
        _ request: WaylandRequest<WpAlphaModifierV1Server>,
        id: WlNewId<WpAlphaModifierSurfaceV1Server>,
        surface surfaceResource:
            WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard
            let surface = surfaceResource.owner(
                as: WlSurface.self)
        else { return }
        guard surface.claimAux(.alphaModifier) else {
            request.postError(
                .alreadyConstructed,
                message:
                    "wl_surface already has an alpha modifier")
            return
        }
        guard
            id.create(owner: { handle in
                WpAlphaModifierSurface(
                    resource: handle,
                    surface: surface)
            }) != nil
        else {
            surface.releaseAux(.alphaModifier)
            return
        }
    }
}

@MainActor
final class WpAlphaModifierSurface {
    private let resource: WaylandResourceHandle<WpAlphaModifierSurfaceV1Server>
    private weak var surface: WlSurface?

    init(
        resource:
            WaylandResourceHandle<WpAlphaModifierSurfaceV1Server>,
        surface: WlSurface
    ) {
        self.resource = resource
        self.surface = surface
    }

    isolated deinit {
        if let surface {
            // Protocol destruction is an implicit pending reset to opaque.
            surface.setPendingAlphaMultiplier(.max)
            surface.releaseAux(.alphaModifier)
        }
    }
}

extension WpAlphaModifierSurface:
    WpAlphaModifierSurfaceV1Requests
{
    func setMultiplier(
        _ request:
            WaylandRequest<WpAlphaModifierSurfaceV1Server>,
        factor: UInt32
    ) {
        guard let surface else {
            request.postError(
                .noSurface,
                message: "wl_surface was destroyed")
            return
        }
        surface.setPendingAlphaMultiplier(factor)
    }
}
