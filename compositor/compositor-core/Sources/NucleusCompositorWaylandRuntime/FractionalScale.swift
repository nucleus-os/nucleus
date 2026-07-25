// wp_fractional_scale_manager_v1 on the router. Lets a client learn the preferred
// fractional scale (×120) for its surface, so it can render at the exact output
// scale instead of an integer wl_surface buffer scale. Unlike viewport/tearing/etc.
// this is NOT buffered: it is output-affinity advice the compositor pushes whenever
// the surface's preferred scale changes (WlSurface.setPreferredFractionalScale).
//
// The object dedups repeated scales
// and a second get_fractional_scale for one surface raises fractional_scale_exists.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

@MainActor
@safe final class WpFractionalScaleManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            WpFractionalScaleManagerV1Server.global(
                implementation: self,
                owner: { manager, _ in manager }))
    }
}

extension WpFractionalScaleManager: WpFractionalScaleManagerV1Requests {
    func getFractionalScale(
        _ request: WaylandRequest<WpFractionalScaleManagerV1Server>,
        id: WlNewId<WpFractionalScaleV1Server>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard surface.claimAux(.fractionalScale) else {
            request.postError(.fractionalScaleExists, message: "wl_surface already has a fractional scale")
            return
        }
        guard unsafe id.create(
            owner: { handle in
                WpFractionalScale(resource: handle, surface: surface)
            },
            installed: { object in
                surface.fractionalScaleSink = object
                object.sendPreferredScale(surface.preferredFractionalScale120)
            }
        ) != nil else {
            surface.releaseAux(.fractionalScale)
            return
        }
    }
}

/// wp_fractional_scale_v1 resource owner (Rule 9). Sends preferred_scale (deduped).
/// Its destroy-only request is handled by generated dispatch.
@MainActor
@safe final class WpFractionalScale: PreferredScaleSink {
    private weak var surface: WlSurface?
    private let resource: WaylandResourceHandle<WpFractionalScaleV1Server>
    private var lastSent: UInt32?

    init(
        resource: WaylandResourceHandle<WpFractionalScaleV1Server>,
        surface: WlSurface
    ) {
        self.resource = resource
        self.surface = surface
    }

    func sendPreferredScale(_ scale120: UInt32) {
        guard lastSent != scale120 else { return }
        lastSent = scale120
        resource.sendPreferredScale(scale: scale120)
    }

    isolated deinit {
        if let surface {
            if surface.fractionalScaleSink === self { surface.fractionalScaleSink = nil }
            surface.releaseAux(.fractionalScale)
        }
    }
}
