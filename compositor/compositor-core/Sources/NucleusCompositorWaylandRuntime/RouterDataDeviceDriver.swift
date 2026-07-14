// The data-device policy driver: answers the router's clipboard/drag delegate from
// the authoritative Swift focus model. The router owns the protocol mechanics
// (mime accumulation, offer minting, the receive→send data pipe, selection
// bookkeeping); compositor policy decides only *who* a selection reaches and how a
// drag grab runs.
//
// Selection delivery is keyed on keyboard focus: a client learns the current
// selection when it gains focus and when the selection changes while it holds
// focus. This driver answers "is this client focused" by resolving the one focus
// truth (NucleusCompositorServer.seatFocus's keyboard surface id) back to its libwayland
// client and comparing client keys.
//
// The drag path (`start_drag`) hands a grab + hit-testing to compositor policy
// that lives outside the runtime module (NucleusCompositorShell), so it is wired at the
// cutover and inert here.
//
// Dormant until the swap: constructed only when the router goes live. Isolation:
// the manager invokes the focus predicate from nonisolated @convention(c) request
// handlers on the compositor's main-actor thread, so the method is nonisolated and
// re-enters the actor with MainActor.assumeIsolated, crossing only the Sendable
// client key.

import WaylandServerC
import NucleusCompositorServer

@MainActor
final class RouterDataDeviceDriver {
    private let compositor: WlCompositor

    init(compositor: WlCompositor) {
        self.compositor = compositor
    }

    /// Whether `clientKey` owns the surface that currently holds keyboard focus.
    /// Resolves the focused surface id (NucleusCompositorServer.seatFocus — the single focus
    /// truth the seat driver mirrors into) to its WlSurface and compares the
    /// surface's libwayland client key against `clientKey`.
    private func clientIsFocused(_ clientKey: UInt) -> Bool {
        let focused = NucleusCompositorServer.shared.seatFocus.keyboardSurfaceID
        guard focused != 0,
            let surface = compositor.surface(id: UInt32(truncatingIfNeeded: focused)),
            let sres = surface.resource,
            let client = wl_resource_get_client(sres)
        else { return false }
        return WlSeat.clientKey(client) == clientKey
    }
}

extension RouterDataDeviceDriver: DataDeviceDelegate {
    nonisolated func dataDeviceClientFocused(_ clientKey: UInt) -> Bool {
        MainActor.assumeIsolated { self.clientIsFocused(clientKey) }
    }

    /// `start_drag` hands the drag grab + hit-testing to compositor policy in
    /// NucleusCompositorShell, which the runtime module does not depend on; wired at the cut.
    nonisolated func dataDeviceStartDrag(
        source _: WlDataSource?, origin _: WlSurface?, icon _: WlSurface?, serial _: UInt32
    ) {}
}
