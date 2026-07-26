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
import WaylandProtocolTypes

@MainActor
@safe final class PointerConstraintsManager {
    private var constraints: [WeakReference<PointerConstraint>] = []

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ZwpPointerConstraintsV1Server.global(
                implementation: self))
    }

    fileprivate func add(_ constraint: PointerConstraint) {
        constraints.append(WeakReference(constraint))
    }

    fileprivate func remove(_ constraint: PointerConstraint) {
        constraints.removeAll { $0.value == nil || $0.value === constraint }
    }

    fileprivate func constraint(for surface: WlSurface) -> PointerConstraint? {
        for box in constraints where box.value?.surface === surface {
            return box.value
        }
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

    fileprivate func prepareConstraint(
        surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
        regionRes: WaylandBorrowedObject<WlRegionServer>?,
        lifetimeRaw: UInt32,
        kind: PointerConstraint.Kind,
        onAlreadyConstrained: () -> Void
    ) -> (
        surface: WlSurface,
        lifetime: PointerConstraint.Lifetime,
        region: RegionSnapshot?
    )? {
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return nil }
        // already_constrained (code 1): one constraint per (surface, pointer).
        guard constraint(for: surface) == nil else {
            onAlreadyConstrained()
            return nil
        }
        let lifetime: PointerConstraint.Lifetime = (lifetimeRaw == 2) ? .persistent : .oneshot
        let region = regionRes?.owner(as: WlRegion.self)?.snapshot()
        return (surface, lifetime, region)
    }
}

// The zwp_pointer_constraints_v1 manager owner is shared across every bound resource, so
// already_constrained is posted on the specific request `resource`.
extension PointerConstraintsManager: ZwpPointerConstraintsV1Requests {
    func lockPointer(
        _ request: WaylandRequest<ZwpPointerConstraintsV1Server>,
        id: WlNewId<ZwpLockedPointerV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>, pointer: WaylandBorrowedObject<WlPointerServer>,
        region: WaylandBorrowedObject<WlRegionServer>?, lifetime: ZwpPointerConstraintsV1Lifetime
    ) {
        guard let prepared = prepareConstraint(
            surfaceRes: surface,
            regionRes: region,
            lifetimeRaw: lifetime.rawValue,
            kind: .locked,
            onAlreadyConstrained: {
                request.postError(
                    .alreadyConstrained,
                    message: "pointer already constrained for surface")
            })
        else { return }
        _ = id.create(
            owner: { handle in
                PointerConstraint(
                    resource: .locked(handle),
                    manager: self,
                    surface: prepared.surface,
                    kind: .locked,
                    lifetime: prepared.lifetime,
                    region: prepared.region)
            },
            installed: { constraint in
                self.add(constraint)
            })
    }

    func confinePointer(
        _ request: WaylandRequest<ZwpPointerConstraintsV1Server>,
        id: WlNewId<ZwpConfinedPointerV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>, pointer: WaylandBorrowedObject<WlPointerServer>,
        region: WaylandBorrowedObject<WlRegionServer>?, lifetime: ZwpPointerConstraintsV1Lifetime
    ) {
        guard let prepared = prepareConstraint(
            surfaceRes: surface,
            regionRes: region,
            lifetimeRaw: lifetime.rawValue,
            kind: .confined,
            onAlreadyConstrained: {
                request.postError(
                    .alreadyConstrained,
                    message: "pointer already constrained for surface")
            })
        else { return }
        _ = id.create(
            owner: { handle in
                PointerConstraint(
                    resource: .confined(handle),
                    manager: self,
                    surface: prepared.surface,
                    kind: .confined,
                    lifetime: prepared.lifetime,
                    region: prepared.region)
            },
            installed: { constraint in
                self.add(constraint)
            })
    }
}

/// zwp_locked_pointer_v1 / zwp_confined_pointer_v1 resource owner (Rule 9). Holds
/// the constraint's lifetime/active/dead state and a weak back-link to its surface.
@MainActor
@safe final class PointerConstraint {
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
    @MainActor
    enum Resource {
        case locked(WaylandResourceHandle<ZwpLockedPointerV1Server>)
        case confined(
            WaylandResourceHandle<ZwpConfinedPointerV1Server>)

    }
    private let resource: Resource

    init(
        resource: Resource,
        manager: PointerConstraintsManager, surface: WlSurface,
        kind: Kind, lifetime: Lifetime, region: RegionSnapshot?
    ) {
        self.resource = resource
        self.manager = manager
        self.surface = surface
        self.kind = kind
        self.lifetime = lifetime
        self.region = region
    }

    fileprivate func sendActive() {
        switch resource {
        case let .locked(handle): handle.sendLocked()
        case let .confined(handle): handle.sendConfined()
        }
    }

    fileprivate func sendInactive() {
        switch resource {
        case let .locked(handle): handle.sendUnlocked()
        case let .confined(handle): handle.sendUnconfined()
        }
    }

    isolated deinit { manager?.remove(self) }
}

// Per-resource owner for both constraint kinds. locked adds set_cursor_position_hint;
// both share set_region (one implementation satisfies both protocol requirements).
extension PointerConstraint: ZwpLockedPointerV1Requests, ZwpConfinedPointerV1Requests {
    // Both protocols default `destroy`; conforming to both makes that default ambiguous, so pin it
    // explicitly (plain teardown — the constraint's release runs in deinit when the owner is freed).
    func destroy(_ request: WaylandRequest<ZwpLockedPointerV1Server>) {
        request.destroy()
    }

    func destroy(_ request: WaylandRequest<ZwpConfinedPointerV1Server>) {
        request.destroy()
    }

    func setCursorPositionHint(
        _ request: WaylandRequest<ZwpLockedPointerV1Server>, surface_x: Double, surface_y: Double
    ) {
        cursorPositionHint = (surface_x, surface_y)
    }

    func setRegion(
        _ request: WaylandRequest<ZwpLockedPointerV1Server>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {
        setRegion(region)
    }

    func setRegion(
        _ request: WaylandRequest<ZwpConfinedPointerV1Server>,
        region: WaylandBorrowedObject<WlRegionServer>?
    ) {
        setRegion(region)
    }

    private func setRegion(_ regionObject: WaylandBorrowedObject<WlRegionServer>?) {
        region = regionObject?.owner(as: WlRegion.self)?.snapshot()
    }
}
