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
protocol KdeBlurDelegate: AnyObject {
    func kdeBlurUpdated(_ surface: WlSurface, region: RegionSnapshot?, wholeSurface: Bool)
    func kdeBlurCleared(_ surface: WlSurface)
}

final class OrgKdeKwinBlurManager {
    weak var delegate: (any KdeBlurDelegate)?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_org_kde_kwin_blur_manager(), version: 1,
            impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: OrgKdeKwinBlurManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_org_kde_kwin_blur_manager(),
            version: Int32(version), id: id, vtable: OrgKdeKwinBlurManagerServer.vtable, owner: me)
    }

    fileprivate func publish(_ surface: WlSurface, region: RegionSnapshot?, wholeSurface: Bool) {
        delegate?.kdeBlurUpdated(surface, region: region, wholeSurface: wholeSurface)
    }
    fileprivate func cleared(_ surface: WlSurface) { delegate?.kdeBlurCleared(surface) }
}

extension OrgKdeKwinBlurManager: OrgKdeKwinBlurManagerRequests {
    // create(id, surface)
    func create(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        let blur = OrgKdeKwinBlur(manager: self, surface: surface)
        _ = id.create(vtable: OrgKdeKwinBlurServer.vtable, owner: blur)
    }

    // unset(surface): remove the blur effect without needing the blur object.
    func unset(_ resource: UnsafeMutablePointer<wl_resource>,
               surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        delegate?.kdeBlurCleared(surface)
    }
}

/// org_kde_kwin_blur owner (Rule 9). Accumulates a pending region, published to the
/// render side on its own commit request.
final class OrgKdeKwinBlur {
    private weak var manager: OrgKdeKwinBlurManager?
    private weak var surface: WlSurface?
    private var pendingRegion: RegionSnapshot?
    private var pendingWholeSurface = true  // null region (or none) blurs the whole surface

    init(manager: OrgKdeKwinBlurManager, surface: WlSurface) {
        self.manager = manager
        self.surface = surface
    }

    deinit { if let surface { manager?.cleared(surface) } }
}

extension OrgKdeKwinBlur: OrgKdeKwinBlurRequests {
    // commit: publish the accumulated blur region.
    func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard let surface else { return }
        manager?.publish(surface, region: pendingRegion, wholeSurface: pendingWholeSurface)
    }

    // set_region(region): null region blurs the whole surface.
    func setRegion(_ resource: UnsafeMutablePointer<wl_resource>,
                   region regionRes: UnsafeMutablePointer<wl_resource>?) {
        if let regionRes, let region = WaylandResource.owner(of: regionRes, as: WlRegion.self) {
            pendingRegion = region.snapshot()
            pendingWholeSurface = false
        } else {
            pendingRegion = nil
            pendingWholeSurface = true
        }
    }
}
