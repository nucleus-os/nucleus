// zwp_pointer_constraints_v1 on the router. Two constraint kinds:
//   - zwp_locked_pointer_v1 — the cursor stays at one position while active; the
//     client receives no wl_pointer.motion but does receive relative_motion (the
//     mouselook path).
//   - zwp_confined_pointer_v1 — the cursor moves freely within a region; motion
//     keeps flowing, the cursor is just clamped.
//
// A constraint becomes active when its surface has pointer focus on the seat, and
// deactivates on focus loss; a `oneshot` constraint that deactivated once is
// permanently dead, while `persistent` reactivates on the next focus-enter. Only
// one constraint may exist per (surface, pointer): re-requesting raises
// already_constrained. InputDispatch applies the cursor clamp/freeze; this owns the
// lifetime/active/dead transitions and the (un)locked/(un)confined wire events.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Owner bound to each zwp_pointer_constraints_v1 resource (Rule 9).
final class PointerConstraintsManagerBinding {
    unowned let manager: PointerConstraintsManager
    init(_ manager: PointerConstraintsManager) { self.manager = manager }
}

private final class WeakConstraint {
    weak var constraint: PointerConstraint?
    init(_ constraint: PointerConstraint) { self.constraint = constraint }
}

final class PointerConstraintsManager {
    private var constraints: [WeakConstraint] = []

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwp_pointer_constraints_v1(), version: 1,
            impl: self, bind: Self.bind
        )
    }

    fileprivate func add(_ constraint: PointerConstraint) { constraints.append(WeakConstraint(constraint)) }

    fileprivate func remove(_ constraint: PointerConstraint) {
        constraints.removeAll { $0.constraint == nil || $0.constraint === constraint }
    }

    fileprivate func constraint(for surface: WlSurface) -> PointerConstraint? {
        for box in constraints where box.constraint?.surface === surface { return box.constraint }
        return nil
    }

    /// The kind of the active constraint on `surface`, or nil if none is active.
    /// The seat consults this on motion (a locked constraint suppresses the absolute
    /// wl_pointer.motion) and the input feed consults it (by surface id) to clamp
    /// / freeze the compositor cursor.
    func activeConstraintKind(for surface: WlSurface) -> PointerConstraint.Kind? {
        guard let c = constraint(for: surface), c.active else { return nil }
        return c.kind
    }

    /// Drive the active/inactive transitions alongside wl_pointer.enter/leave.
    func notifyPointerFocus(old: WlSurface?, new: WlSurface?) {
        if let old, let c = constraint(for: old), c.active {
            c.active = false
            c.sendInactive()
            if c.lifetime == .oneshot { c.dead = true }
        }
        if let new, let c = constraint(for: new), !c.active, !c.dead {
            c.active = true
            c.sendActive()
        }
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: PointerConstraintsManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwp_pointer_constraints_v1(),
            version: Int32(version), id: id, vtable: ZwpPointerConstraintsV1Server.vtable,
            owner: PointerConstraintsManagerBinding(me)
        )
    }

    fileprivate func createConstraint(
        resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surfaceRes: UnsafeMutablePointer<wl_resource>?, regionRes: UnsafeMutablePointer<wl_resource>?,
        lifetimeRaw: UInt32, kind: PointerConstraint.Kind
    ) {
        guard let surfaceRes, let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        // already_constrained (code 1): one constraint per (surface, pointer).
        guard constraint(for: surface) == nil else {
            swift_wayland_resource_post_error(resource, 1, "pointer already constrained for surface")
            return
        }
        let lifetime: PointerConstraint.Lifetime = (lifetimeRaw == 2) ? .persistent : .oneshot
        let region = regionRes.flatMap { WaylandResource.owner(of: $0, as: WlRegion.self)?.snapshot() }
        let vtable = (kind == .locked)
            ? ZwpLockedPointerV1Server.vtable : ZwpConfinedPointerV1Server.vtable
        let owner = PointerConstraint(
            manager: self, surface: surface, kind: kind, lifetime: lifetime, region: region)
        guard let cres = id.create(vtable: vtable, owner: owner) else { return }
        owner.bind(cres)
        add(owner)
    }
}

// The zwp_pointer_constraints_v1 manager owner is shared across every bound resource, so
// already_constrained is posted on the specific request `resource`.
extension PointerConstraintsManagerBinding: ZwpPointerConstraintsV1Requests {
    func lockPointer(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface: UnsafeMutablePointer<wl_resource>?, pointer: UnsafeMutablePointer<wl_resource>?,
        region: UnsafeMutablePointer<wl_resource>?, lifetime: UInt32
    ) {
        manager.createConstraint(
            resource: resource, id: id, surfaceRes: surface, regionRes: region,
            lifetimeRaw: lifetime, kind: .locked)
    }

    func confinePointer(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface: UnsafeMutablePointer<wl_resource>?, pointer: UnsafeMutablePointer<wl_resource>?,
        region: UnsafeMutablePointer<wl_resource>?, lifetime: UInt32
    ) {
        manager.createConstraint(
            resource: resource, id: id, surfaceRes: surface, regionRes: region,
            lifetimeRaw: lifetime, kind: .confined)
    }
}

/// zwp_locked_pointer_v1 / zwp_confined_pointer_v1 resource owner (Rule 9). Holds
/// the constraint's lifetime/active/dead state and a weak back-link to its surface.
final class PointerConstraint {
    enum Kind { case locked, confined }
    enum Lifetime { case oneshot, persistent }

    private weak var manager: PointerConstraintsManager?
    weak var surface: WlSurface?
    let kind: Kind
    let lifetime: Lifetime
    var active = false
    /// A oneshot constraint that deactivated once cannot reactivate.
    var dead = false
    var region: RegionSnapshot?
    /// Locked-only: where the cursor lands on deactivation (surface-local).
    var cursorPositionHint: (x: Double, y: Double)?
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(
        manager: PointerConstraintsManager, surface: WlSurface,
        kind: Kind, lifetime: Lifetime, region: RegionSnapshot?
    ) {
        self.manager = manager
        self.surface = surface
        self.kind = kind
        self.lifetime = lifetime
        self.region = region
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    fileprivate func sendActive() {
        guard let resource else { return }
        switch kind {
        case .locked: zwp_locked_pointer_v1_send_locked(resource)
        case .confined: zwp_confined_pointer_v1_send_confined(resource)
        }
    }

    fileprivate func sendInactive() {
        guard let resource else { return }
        switch kind {
        case .locked: zwp_locked_pointer_v1_send_unlocked(resource)
        case .confined: zwp_confined_pointer_v1_send_unconfined(resource)
        }
    }

    deinit { manager?.remove(self) }
}

// Per-resource owner for both constraint kinds. locked adds set_cursor_position_hint;
// both share set_region (one implementation satisfies both protocol requirements).
extension PointerConstraint: ZwpLockedPointerV1Requests, ZwpConfinedPointerV1Requests {
    // Both protocols default `destroy`; conforming to both makes that default ambiguous, so pin it
    // explicitly (plain teardown — the constraint's release runs in deinit when the owner is freed).
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) { wl_resource_destroy(resource) }

    func setCursorPositionHint(
        _ resource: UnsafeMutablePointer<wl_resource>, surface_x: Double, surface_y: Double
    ) {
        cursorPositionHint = (surface_x, surface_y)
    }

    func setRegion(
        _ resource: UnsafeMutablePointer<wl_resource>, region regionRes: UnsafeMutablePointer<wl_resource>?
    ) {
        region = regionRes.flatMap { WaylandResource.owner(of: $0, as: WlRegion.self)?.snapshot() }
    }
}
