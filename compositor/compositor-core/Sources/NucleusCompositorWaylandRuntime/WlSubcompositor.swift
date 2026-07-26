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
import WaylandProtocolTypes

extension WlSubcompositor: WlSubcompositorRequests {
    func getSubsurface(
        _ request: WaylandRequest<WlSubcompositorServer>,
        id: WlNewId<WlSubsurfaceServer>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
        parent parentRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard let surface = surfaceRes.owner(as: WlSurface.self),
            let parent = parentRes.owner(as: WlSurface.self)
        else { return }

        guard !surface.wouldCreateSubsurfaceCycle(parent: parent),
            surface.claimSubsurfaceRole()
        else {
            request.postError(.badSurface, message: "surface already has a role or is its own parent")
            return
        }

        guard id.create(
            owner: { handle in
                WlSubsurface(
                    resource: handle, surface: surface, parent: parent)
            },
            installed: { _ in
                surface.attachAsSubsurface(to: parent)
            }
        ) != nil else {
            surface.releaseSubsurfaceRole()
            return
        }
    }
}

/// The wl_subsurface role object (Rule 9 owner of the wl_subsurface resource).
/// Holds weak links: a subsurface is owned by its own resource, and its surface
/// and parent are owned by theirs.
@MainActor
@safe final class WlSubsurface {
    private let resource: WaylandResourceHandle<WlSubsurfaceServer>
    weak var surface: WlSurface?
    weak var parent: WlSurface?

    init(
        resource: WaylandResourceHandle<WlSubsurfaceServer>,
        surface: WlSurface,
        parent: WlSurface
    ) {
        self.resource = resource
        self.surface = surface
        self.parent = parent
    }

    isolated deinit {
        // wl_subsurface destroyed: the surface loses its subsurface role.
        surface?.detachFromParent()
        surface?.releaseSubsurfaceRole()
    }
}

extension WlSubsurface: WlSubsurfaceRequests {
    func setPosition(_ request: WaylandRequest<WlSubsurfaceServer>, x: Int32, y: Int32) {
        surface?.setSubsurfacePosition(x: x, y: y)
    }

    func placeAbove(
        _ request: WaylandRequest<WlSubsurfaceServer>, sibling siblingRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        place(request, siblingRes, .above)
    }

    func placeBelow(
        _ request: WaylandRequest<WlSubsurfaceServer>, sibling siblingRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        place(request, siblingRes, .below)
    }

    func setSync(_ request: WaylandRequest<WlSubsurfaceServer>) {
        surface?.setSubsurfaceSync(true)
    }

    func setDesync(_ request: WaylandRequest<WlSubsurfaceServer>) {
        surface?.setSubsurfaceSync(false)
    }

    private func place(
        _ request: WaylandRequest<WlSubsurfaceServer>,
        _ siblingRes: WaylandBorrowedObject<WlSurfaceServer>,
        _ dir: WlSurface.PlaceDir
    ) {
        guard let surface = self.surface, let parent = self.parent,
            let sibling = siblingRes.owner(as: WlSurface.self)
        else { return }
        guard sibling === parent || sibling.subsurfaceParent === parent,
            parent.placeChild(surface, relativeTo: sibling, dir)
        else {
            request.postError(.badSurface, message: "stacking reference is not the parent or a sibling")
            return
        }
    }
}

@MainActor
@safe final class WlSubcompositor {
}
