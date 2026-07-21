// SeatDelivery — the callable Swift seam from the input dispatch to the router
// WlSeat, by surface wire id. This is the direct-call form of the seat half of
// RouterInputBridge's seat-delivery seam: the dispatch calls
// these directly rather than through the thunks. Enter/leave key on
// the focused surface; the per-event sends resolve that surface to its client key
// (the router keys device resources by wl_client).
//
// All entries resolve through RouterHost.shared.runtime and no-op before it is
// constructed. Single-threaded on the compositor main actor.

import WaylandServerC

@MainActor
enum SeatDelivery {
    static var seat: WlSeat? { RouterHost.shared.runtime?.seat }

    static func surface(_ id: UInt64) -> WlSurface? {
        RouterHost.shared.runtime?.compositor.surface(id: UInt32(truncatingIfNeeded: id))
    }

    static func clientKey(_ surface: WlSurface) -> UInt? {
        guard let sres = surface.resource, let c = wl_resource_get_client(sres) else { return nil }
        return WlSeat.clientKey(c)
    }

    private static func pointerDeliverySurface(_ id: UInt64) -> WlSurface? {
        guard let target = surface(id) else { return nil }
        return seat?.popupGrabDeliverySurface(fallback: target) ?? target
    }

    // MARK: - pointer

    static func pointerEnter(surfaceID: UInt64, x: Double, y: Double) {
        guard let s = pointerDeliverySurface(surfaceID), let seat else { return }
        _ = seat.pointerEnter(s, surfaceX: x, surfaceY: y)
    }

    static func pointerLeave(surfaceID: UInt64) {
        guard let s = pointerDeliverySurface(surfaceID), let seat else { return }
        seat.pointerLeave(s)
    }

    /// One pointer-motion sample to the focused surface: the seat emits
    /// relative_motion (always) and absolute motion (unless a locked constraint
    /// suppresses it). `x`/`y` are surface-local absolute; the d* deltas are the
    /// raw/accelerated motion the relative-pointer protocol reports.
    static func pointerMotionRaw(
        surfaceID: UInt64, timeMsec: UInt32, surfaceX: Double, surfaceY: Double,
        dx: Double, dy: Double, dxUnaccel: Double, dyUnaccel: Double
    ) {
        guard let s = pointerDeliverySurface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.pointerMotionRaw(
            s, clientKey: key, timeMsec: timeMsec, surfaceX: surfaceX, surfaceY: surfaceY,
            dx: dx, dy: dy, dxUnaccel: dxUnaccel, dyUnaccel: dyUnaccel)
    }

    /// Returns the button event serial (0 if undelivered), for interactive-grab serials.
    static func pointerButton(surfaceID: UInt64, timeMsec: UInt32, button: UInt32, state: UInt32) -> UInt32 {
        guard let original = surface(surfaceID), let seat else { return 0 }
        if state != 0, seat.dismissPopupGrabIfOutside(original) { return 0 }
        let s = seat.popupGrabDeliverySurface(fallback: original)
        guard let key = clientKey(s) else { return 0 }
        return seat.pointerButton(
            clientKey: key, surface: s, timeMsec: timeMsec,
            button: button, state: state)
    }

    static func pointerAxis(
        surfaceID: UInt64, timeMsec: UInt32, axis: UInt32, delta: Double, value120: Int32, source: UInt32
    ) {
        guard let s = pointerDeliverySurface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.pointerAxis(clientKey: key, timeMsec: timeMsec, axis: axis, delta: delta,
                         value120: value120, source: source)
    }

    static func pointerFrame(surfaceID: UInt64) {
        guard let s = pointerDeliverySurface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.pointerFrame(clientKey: key)
    }

    /// The active pointer-constraint kind on `surfaceID` (0 none, 1 locked, 2 confined).
    static func pointerConstraintKind(surfaceID: UInt64) -> UInt32 {
        guard let s = surface(surfaceID), let constraints = RouterHost.shared.runtime?.pointerConstraints
        else { return 0 }
        switch constraints.activeConstraintKind(for: s) {
        case .locked: return 1
        case .confined: return 2
        case nil: return 0
        }
    }

    // MARK: - keyboard

    static func keyboardEnter(surfaceID: UInt64) {
        guard let s = surface(surfaceID), let seat else { return }
        seat.keyboardEnter(s)
    }

    static func keyboardLeave(surfaceID: UInt64) {
        guard let s = surface(surfaceID), let seat else { return }
        seat.keyboardLeave(s)
    }

    static func keyboardKey(surfaceID: UInt64, timeMsec: UInt32, keycode: UInt32, keyState: UInt32) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        if keycode == 1, keyState != 0 {
            seat.cancelPopupGrabs()
            return
        }
        seat.keyboardKey(clientKey: key, timeMsec: timeMsec, keycode: keycode, keyState: keyState)
    }

    static func keyboardModifiers(
        surfaceID: UInt64, depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32
    ) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.keyboardModifiers(clientKey: key, depressed: depressed, latched: latched,
                               locked: locked, group: group)
    }

    /// Whether `surfaceID` currently owns an active keyboard-shortcuts inhibitor.
    static func isInhibited(surfaceID: UInt64) -> Bool {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return false }
        return seat.isInhibited(clientKey: key, surfaceId: UInt32(truncatingIfNeeded: surfaceID))
    }

    // MARK: - touch

    static func touchDown(
        surfaceID: UInt64, timeMsec: UInt32, id: Int32, x: Double, y: Double
    ) {
        guard let original = surface(surfaceID), let seat else { return }
        if seat.dismissPopupGrabIfOutside(original) { return }
        let s = seat.popupGrabDeliverySurface(fallback: original)
        _ = seat.touchDown(s, timeMsec: timeMsec, id: id, surfaceX: x, surfaceY: y)
    }

    static func touchUp(surfaceID: UInt64, timeMsec: UInt32, id: Int32) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.touchUp(clientKey: key, timeMsec: timeMsec, id: id)
    }

    static func touchMotion(
        surfaceID: UInt64, timeMsec: UInt32, id: Int32, x: Double, y: Double
    ) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.touchMotion(clientKey: key, timeMsec: timeMsec, id: id, x: x, y: y)
    }

    static func touchFrame(surfaceID: UInt64) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.touchFrame(clientKey: key)
    }

    static func touchCancel(surfaceID: UInt64) {
        guard let s = surface(surfaceID), let key = clientKey(s), let seat else { return }
        seat.touchCancel(clientKey: key)
    }
}
