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
// Drag sessions stay in WlDataDeviceManager and are advanced by InputDispatch's
// live hit-testing and button path. Generated dispatch enters the main actor before
// the manager invokes this typed policy seam.

import WaylandServerC
import WaylandServer
internal import NucleusCompositorServer

@MainActor
final class RouterDataDeviceDriver {
    private let compositor: WlCompositor
    private unowned let server: NucleusCompositorServer

    init(compositor: WlCompositor, server: NucleusCompositorServer) {
        self.compositor = compositor
        self.server = server
    }

    /// Whether `clientKey` owns the surface that currently holds keyboard focus.
    /// Resolves the focused surface id (NucleusCompositorServer.seatFocus — the single focus
    /// truth the seat driver mirrors into) to its WlSurface and compares the
    /// surface's libwayland client key against `clientKey`.
    private func clientIsFocused(_ clientKey: WaylandClientID) -> Bool {
        let focused = server.seatFocus.keyboardSurfaceID
        guard focused != 0,
            let surface = compositor.surface(id: UInt32(truncatingIfNeeded: focused)),
            let sres = unsafe surface.resource,
            let client = unsafe wl_resource_get_client(sres)
        else { return false }
        return unsafe WlSeat.clientKey(client) == clientKey
    }
}

extension RouterDataDeviceDriver: DataDeviceDelegate {
    func dataDeviceClientFocused(_ clientKey: WaylandClientID) -> Bool {
        clientIsFocused(clientKey)
    }

}
