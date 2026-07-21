// Applies window-model focus decisions to the live router seat. The window driver
// calls this (on the compositor turn's main actor) when a toplevel maps, is
// activated, or is destroyed; it sends the wl_keyboard leave/enter pair on the
// router's WlSeat and mirrors the focus into the authoritative NucleusCompositorServer.seatFocus
// so policy, the foreign-toplevel projection, and the keyboard-shortcuts-inhibit gate
// all read one focus truth.
//
// Focus is tracked by surface wire id (a Sendable token), not by holding the
// WlSurface: the surfaces are re-resolved by id through the compositor at the moment
// the wire event is sent, so no non-Sendable router object is ever stored across an
// isolation boundary. Pointer focus is driven separately by the input feed; this
// driver owns only keyboard focus, which follows window activation.

import NucleusCompositorServer
import WaylandServerC

@MainActor
final class RouterSeatDriver {
    private let seat: WlSeat
    private let compositor: WlCompositor
    /// The wire id of the surface that currently holds keyboard focus (0 = none).
    private var focusedSurfaceId: UInt32 = 0

    init(seat: WlSeat, compositor: WlCompositor) {
        self.seat = seat
        self.compositor = compositor
    }

    func authorizeUserIntent(
        serial: UInt32,
        seatResourceBits: UInt,
        surfaceID: UInt32
    ) -> Bool {
        seat.authorize(
            serial: serial,
            seatResource: UnsafeMutablePointer<wl_resource>(
                bitPattern: seatResourceBits),
            surface: compositor.surface(id: surfaceID),
            kinds: [.pointerButton, .touchDown])
    }

    func beginPopupGrab(_ popup: XdgPopup) {
        seat.beginPopupGrab(popup)
    }

    /// Move keyboard focus to the surface with `newId` (0 clears it). Resolves the
    /// previously- and newly-focused surfaces by id through the compositor, sends
    /// wl_keyboard.leave then .enter, and records the focus in NucleusCompositorServer.seatFocus.
    func setKeyboardFocus(toSurfaceId newId: UInt32) {
        if focusedSurfaceId == newId { return }
        if focusedSurfaceId != 0, let prev = compositor.surface(id: focusedSurfaceId) {
            seat.keyboardLeave(prev)
        }
        focusedSurfaceId = newId
        if newId != 0, let surface = compositor.surface(id: newId) {
            seat.keyboardEnter(surface)
            NucleusCompositorServer.shared.seatFocus.setKeyboardFocus(surfaceID: UInt64(newId))
        } else {
            NucleusCompositorServer.shared.seatFocus.clearKeyboardFocus()
        }
    }

    /// Drop keyboard focus if the surface with `surfaceId` holds it (its window is
    /// unmapping/destroying). No leave is sent — the client is tearing down — only
    /// the model focus is cleared so a stale surface id never lingers as the focus.
    func surfaceUnmapped(surfaceId: UInt32) {
        guard surfaceId != 0, focusedSurfaceId == surfaceId else { return }
        focusedSurfaceId = 0
        seat.textInputManager?.focusedSurfaceDestroyed(
            surfaceID: surfaceId)
        NucleusCompositorServer.shared.seatFocus.clearKeyboardFocus()
    }
}
