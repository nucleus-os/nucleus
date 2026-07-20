// wl_subcompositor / wl_subsurface on the router. get_subsurface gives a surface
// the subsurface role: it joins its parent's z-order stack (initially on top,
// synchronized), and its position, stacking, and sync mode are managed through
// the wl_subsurface object. Synchronized-commit semantics live on WlSurface
// (commit caches while sync; the parent commit cascades cached child commits).
//
// libwayland owns the resource mechanics; this owns the topology semantics.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Owner bound to each wl_subcompositor resource (Rule 9). Routes get_subsurface
/// back to the shared WlSubcompositor.
final class SubcompositorBinding {
    unowned let subcompositor: WlSubcompositor
    init(_ subcompositor: WlSubcompositor) { self.subcompositor = subcompositor }
}

extension SubcompositorBinding: WlSubcompositorRequests {
    func getSubsurface(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?,
        parent parentRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self),
            let parentRes, let parent = WaylandResource.owner(of: parentRes, as: WlSurface.self)
        else { return }

        guard !surface.wouldCreateSubsurfaceCycle(parent: parent),
            surface.claimSubsurfaceRole()
        else {
            swift_wayland_resource_post_error(resource, 0 /* WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE */,
                "surface already has a role or is its own parent")
            return
        }

        let sub = WlSubsurface(surface: surface, parent: parent)
        guard id.create(vtable: WlSubsurfaceServer.vtable, owner: sub) != nil else {
            surface.releaseSubsurfaceRole()
            return
        }
        surface.attachAsSubsurface(to: parent)
    }
}

/// The wl_subsurface role object (Rule 9 owner of the wl_subsurface resource).
/// Holds weak links: a subsurface is owned by its own resource, and its surface
/// and parent are owned by theirs.
final class WlSubsurface {
    weak var surface: WlSurface?
    weak var parent: WlSurface?

    init(surface: WlSurface, parent: WlSurface) {
        self.surface = surface
        self.parent = parent
    }

    deinit {
        // wl_subsurface destroyed: the surface loses its subsurface role.
        surface?.detachFromParent()
        surface?.releaseSubsurfaceRole()
    }
}

extension WlSubsurface: WlSubsurfaceRequests {
    func setPosition(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32) {
        surface?.setSubsurfacePosition(x: x, y: y)
    }

    func placeAbove(
        _ resource: UnsafeMutablePointer<wl_resource>, sibling siblingRes: UnsafeMutablePointer<wl_resource>?
    ) {
        place(resource, siblingRes, .above)
    }

    func placeBelow(
        _ resource: UnsafeMutablePointer<wl_resource>, sibling siblingRes: UnsafeMutablePointer<wl_resource>?
    ) {
        place(resource, siblingRes, .below)
    }

    func setSync(_ resource: UnsafeMutablePointer<wl_resource>) {
        surface?.setSubsurfaceSync(true)
    }

    func setDesync(_ resource: UnsafeMutablePointer<wl_resource>) {
        surface?.setSubsurfaceSync(false)
    }

    private func place(
        _ resource: UnsafeMutablePointer<wl_resource>,
        _ siblingRes: UnsafeMutablePointer<wl_resource>?,
        _ dir: WlSurface.PlaceDir
    ) {
        guard let surface = self.surface, let parent = self.parent,
            let siblingRes, let sibling = WaylandResource.owner(of: siblingRes, as: WlSurface.self)
        else { return }
        guard sibling === parent || sibling.subsurfaceParent === parent,
            parent.placeChild(surface, relativeTo: sibling, dir)
        else {
            swift_wayland_resource_post_error(
                resource, 0 /* WL_SUBSURFACE_ERROR_BAD_SURFACE */,
                "stacking reference is not the parent or a sibling")
            return
        }
    }
}

final class WlSubcompositor {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wl_subcompositor(), version: 1, impl: self, bind: Self.bind
        )
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlSubcompositor.self) else {
            return
        }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_subcompositor(),
            version: Int32(version), id: id, vtable: WlSubcompositorServer.vtable,
            owner: SubcompositorBinding(me)
        )
    }
}
