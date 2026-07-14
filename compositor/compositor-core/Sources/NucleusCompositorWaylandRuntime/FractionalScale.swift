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

final class WpFractionalScaleManager {
    // wp_fractional_scale_v1 is destroy-only (no generated dispatch), so its request
    // vtable stays hand-wired here.
    private let objectVtable: UnsafeMutableRawPointer

    init() {
        objectVtable = allocVtable(
            MemoryLayout<swift_wayland_wp_fractional_scale_v1_requests>.stride,
            MemoryLayout<swift_wayland_wp_fractional_scale_v1_requests>.alignment)
        let ovt = objectVtable.bindMemory(
            to: swift_wayland_wp_fractional_scale_v1_requests.self, capacity: 1)
        ovt.pointee.destroy = WpFractionalScale.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_fractional_scale_manager_v1(), version: 1,
            impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WpFractionalScaleManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_fractional_scale_manager_v1(),
            version: Int32(version), id: id, vtable: WpFractionalScaleManagerV1Server.vtable, owner: me
        )
    }

    deinit {
        objectVtable.deallocate()
    }
}

extension WpFractionalScaleManager: WpFractionalScaleManagerV1Requests {
    func getFractionalScale(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        guard surface.claimAux(.fractionalScale) else {
            swift_wayland_resource_post_error(resource, 0, "wl_surface already has a fractional scale")
            return
        }
        let object = WpFractionalScale(surface: surface)
        guard let ores = id.create(vtable: UnsafeRawPointer(objectVtable), owner: object) else {
            surface.releaseAux(.fractionalScale)
            return
        }
        object.bind(ores)
        surface.fractionalScaleSink = object
        // Push the surface's current preferred scale right away.
        object.sendPreferredScale(surface.preferredFractionalScale120)
    }
}

/// wp_fractional_scale_v1 resource owner (Rule 9). Sends preferred_scale (deduped).
/// Destroy-only: it handles no client requests, so its vtable stays hand-wired.
final class WpFractionalScale: PreferredScaleSink {
    private weak var surface: WlSurface?
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var lastSent: UInt32?

    init(surface: WlSurface) { self.surface = surface }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    func sendPreferredScale(_ scale120: UInt32) {
        guard let resource, lastSent != scale120 else { return }
        lastSent = scale120
        wp_fractional_scale_v1_send_preferred_scale(resource, scale120)
    }

    fileprivate static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit {
        if let surface {
            if surface.fractionalScaleSink === self { surface.fractionalScaleSink = nil }
            surface.releaseAux(.fractionalScale)
        }
    }
}
