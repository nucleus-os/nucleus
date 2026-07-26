// org_kde_kwin_blur on the router. Lets a client request that the compositor blur
// whatever is behind a (region of a) surface. Unlike ext-background-effect this is
// KDE's protocol with its own explicit blur.commit (it does not latch on
// wl_surface.commit), and a null region means "blur the whole surface".
//
// The router owns the request/publish mechanics and SceneFeeder lowers the
// published region into the renderer's backdrop-effect pass.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The render seam for KDE blur. `wholeSurface` true means blur behind the entire
/// surface (region is then nil).
@MainActor
protocol KdeBlurDelegate: AnyObject {
    func kdeBlurUpdated(_ surface: WlSurface, region: RegionSnapshot?, wholeSurface: Bool)
    func kdeBlurCleared(_ surface: WlSurface)
}

@MainActor
final class OrgKdeKwinBlurManager {
    weak var delegate: (any KdeBlurDelegate)?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            OrgKdeKwinBlurManagerServer.global(
                implementation: self))
    }

    fileprivate func publish(_ surface: WlSurface, region: RegionSnapshot?, wholeSurface: Bool) {
        delegate?.kdeBlurUpdated(surface, region: region, wholeSurface: wholeSurface)
    }
    fileprivate func cleared(_ surface: WlSurface) { delegate?.kdeBlurCleared(surface) }
}

extension OrgKdeKwinBlurManager: OrgKdeKwinBlurManagerRequests {
    // create(id, surface)
    func create(
        _ request: WaylandRequest<OrgKdeKwinBlurManagerServer>,
        id: WlNewId<OrgKdeKwinBlurServer>,
                surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        _ = id.create { handle in
            OrgKdeKwinBlur(resource: handle, manager: self, surface: surface)
        }
    }

    // unset(surface): remove the blur effect without needing the blur object.
    func unset(_ request: WaylandRequest<OrgKdeKwinBlurManagerServer>,
               surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>) {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        delegate?.kdeBlurCleared(surface)
    }
}

/// org_kde_kwin_blur owner (Rule 9). Accumulates a pending region, published to the
/// render side on its own commit request.
@MainActor
final class OrgKdeKwinBlur {
    private let resource: WaylandResourceHandle<OrgKdeKwinBlurServer>
    private weak var manager: OrgKdeKwinBlurManager?
    private weak var surface: WlSurface?
    private var pendingRegion: RegionSnapshot?
    private var pendingWholeSurface = true  // null region (or none) blurs the whole surface

    init(
        resource: WaylandResourceHandle<OrgKdeKwinBlurServer>,
        manager: OrgKdeKwinBlurManager,
        surface: WlSurface
    ) {
        self.resource = resource
        self.manager = manager
        self.surface = surface
    }

    isolated deinit { if let surface { manager?.cleared(surface) } }
}

extension OrgKdeKwinBlur: OrgKdeKwinBlurRequests {
    // commit: publish the accumulated blur region.
    func commit(_ request: WaylandRequest<OrgKdeKwinBlurServer>) {
        guard let surface else { return }
        manager?.publish(surface, region: pendingRegion, wholeSurface: pendingWholeSurface)
    }

    // set_region(region): null region blurs the whole surface.
    func setRegion(_ request: WaylandRequest<OrgKdeKwinBlurServer>,
                   region regionRes: WaylandBorrowedObject<WlRegionServer>?) {
        if let region = regionRes?.owner(as: WlRegion.self) {
            pendingRegion = region.snapshot()
            pendingWholeSurface = false
        } else {
            pendingRegion = nil
            pendingWholeSurface = true
        }
    }
}
