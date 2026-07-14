// wl_region on the router. A region is built by the client through add/subtract
// rectangle calls; the surface snapshots it (a value copy) when the client passes
// it to set_input_region / set_opaque_region, so the client may mutate or destroy
// the wl_region afterward without affecting the surface.
//
// Mutations are resolved immediately into canonical coverage. Every downstream
// consumer therefore observes identical input, opacity, blur, and damage geometry.

import NucleusRenderModel
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// A wire rectangle. Shared by region ops and surface damage.
typealias WlRect = RegionRect

/// Immutable snapshot of a region's accumulated operations, taken at set-region
/// time. Decoupled from the live wl_region's lifetime.
struct RegionSnapshot: Equatable, Sendable {
    let region: Region
    var isEmpty: Bool { region.isEmpty }
    var rectangles: [RegionRect] { region.rectangles }
    var rectangleCount: Int { region.rectangleCount }

    /// Point-in-region test in the region's own coordinate space (surface-local
    /// pixels for an input region). Applies the client's add/subtract sequence in
    /// order — the last op covering the point wins — matching wl_region semantics
    /// where a later subtract carves out an earlier add and a later add fills it
    /// back in. Used by the router hit-test to refine a surface hit through its
    /// `wl_surface.set_input_region`.
    func contains(x: Double, y: Double) -> Bool {
        region.contains(x: x, y: y)
    }
}

final class WlRegion {
    private var region = Region()

    func add(_ r: WlRect) {
        guard r.width > 0, r.height > 0 else { return }
        region.formUnion(r)
    }

    func subtract(_ r: WlRect) {
        guard r.width > 0, r.height > 0 else { return }
        region.subtract(r)
    }

    func snapshot() -> RegionSnapshot { RegionSnapshot(region: region) }
}

// The wl_region request handlers (add/subtract) — the shared WlRegionServer.vtable recovers this
// WlRegion owner and forwards. `destroy` is the generated fixed wl_resource_destroy trampoline.
extension WlRegion: WlRegionRequests {
    func add(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32) {
        add(WlRect(x: x, y: y, width: width, height: height))
    }
    func subtract(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32) {
        subtract(WlRect(x: x, y: y, width: width, height: height))
    }
}
