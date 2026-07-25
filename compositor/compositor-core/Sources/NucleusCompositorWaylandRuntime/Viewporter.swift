// wp_viewporter on the router. Lets a client crop (set_source) and scale
// (set_destination) its surface content. Both are double-buffered surface state:
// the requests write the surface's pending viewport fields, latched on commit
// (boundary plan line 205 — the router owns viewport). libwayland owns the
// resource mechanics; WlSurface owns the latched state.
//
// Source/destination validation
// raises bad_value, a request after the wl_surface is gone raises no_surface, and
// a second get_viewport for one surface raises viewport_exists.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
import NucleusTypes

@MainActor
@safe final class WpViewporter {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            WpViewporterServer.global(
                implementation: self,
                owner: { viewporter, _ in viewporter }))
    }
}

// get_viewport(id, surface): one viewport per surface (viewport_exists = 0). The manager owner is
// shared across every bound resource, so the error is posted on the specific request `resource`.
extension WpViewporter: WpViewporterRequests {
    func getViewport(
        _ request: WaylandRequest<WpViewporterServer>,
        id: WlNewId<WpViewportServer>,
                     surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard surface.claimAux(.viewport) else {
            request.postError(
                .viewportExists,
                message: "wl_surface already has a viewport")
            return
        }
        guard unsafe id.create(
            owner: { handle in
                WpViewport(resource: handle, surface: surface)
            },
            installed: { viewport in
                surface.viewport = viewport
            }
        ) != nil else {
            surface.releaseAux(.viewport)
            return
        }
    }
}

/// wp_viewport resource owner (Rule 9). Writes the surface's pending crop/scale.
@MainActor
@safe final class WpViewport {
    private weak var surface: WlSurface?
    private let resource: WaylandResourceHandle<WpViewportServer>

    init(resource: WaylandResourceHandle<WpViewportServer>, surface: WlSurface) {
        self.resource = resource
        self.surface = surface
    }

    isolated deinit {
        // Removing the viewport clears the surface's crop/scale on the next commit.
        if let surface {
            surface.setPendingViewportSource(nil)
            surface.setPendingViewportDestination(nil)
            surface.releaseAux(.viewport)
            if surface.viewport === self { surface.viewport = nil }
        }
    }

    func postError(_ code: WpViewportError, _ message: String) {
        resource.postError(code, message: message)
    }
}

extension WpViewport: WpViewportRequests {
    func setSource(_ request: WaylandRequest<WpViewportServer>,
                   x dx: Double, y dy: Double, width dw: Double, height dh: Double) {
        guard let surface else {
            request.postError(.noSurface, message: "wl_surface was destroyed")
            return
        }
        if dx == -1.0, dy == -1.0, dw == -1.0, dh == -1.0 {
            surface.setPendingViewportSource(nil)  // unset
            return
        }
        guard dx >= 0, dy >= 0, dw > 0, dh > 0 else {
            request.postError(
                .badValue,
                message: "invalid viewport source rectangle")
            return
        }
        surface.setPendingViewportSource(WlFRect(x: dx, y: dy, width: dw, height: dh))
    }

    func setDestination(_ request: WaylandRequest<WpViewportServer>, width: Int32, height: Int32) {
        guard let surface else {
            request.postError(.noSurface, message: "wl_surface was destroyed")
            return
        }
        if width == -1, height == -1 {
            surface.setPendingViewportDestination(nil)  // unset
            return
        }
        guard width > 0, height > 0 else {
            request.postError(
                .badValue,
                message: "invalid viewport destination size")
            return
        }
        surface.setPendingViewportDestination(WlSize(width: width, height: height))
    }
}
