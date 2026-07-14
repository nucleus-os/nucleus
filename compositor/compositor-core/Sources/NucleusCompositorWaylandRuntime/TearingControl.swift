// wp_tearing_control_manager_v1 on the router. Lets a client hint whether a
// surface's updates may tear (async) or must be vsync'd. The hint is double-
// buffered surface state latched on commit (the router owns tearing — boundary
// plan line 205); the presentation path consumes it at #12.
//
// A second get_tearing_control for one
// surface raises tearing_control_exists; destroying the object resets the surface
// to vsync on the next commit.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class WpTearingControlManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_tearing_control_manager_v1(), version: 1,
            impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpTearingControlManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_tearing_control_manager_v1(),
            version: Int32(version), id: id, vtable: WpTearingControlManagerV1Server.vtable, owner: me
        )
    }
}

extension WpTearingControlManager: WpTearingControlManagerV1Requests {
    func getTearingControl(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.tearingControl) else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface already has a tearing control")
            return
        }
        let control = WpTearingControl(surface: surface)
        guard let cres = id.create(vtable: WpTearingControlV1Server.vtable, owner: control) else {
            surface.releaseAux(.tearingControl)
            return
        }
        control.bind(cres)
    }
}

/// wp_tearing_control_v1 resource owner (Rule 9). Writes the surface's pending hint.
final class WpTearingControl {
    private weak var surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(surface: WlSurface) { self.surface = surface }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit {
        // Destroying the control restores vsync on the next commit.
        if let surface {
            surface.setPendingPresentationHint(0)
            surface.releaseAux(.tearingControl)
        }
    }
}

extension WpTearingControl: WpTearingControlV1Requests {
    // set_presentation_hint(hint): vsync = 0, async = 1.
    func setPresentationHint(_ resource: UnsafeMutablePointer<wl_resource>, hint: UInt32) {
        guard hint <= 1 else {
            swift_wayland_resource_post_error(resource, 0, "invalid presentation hint")
            return
        }
        surface?.setPendingPresentationHint(hint)
    }
}
