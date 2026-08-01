// ConfigurePolicy by the production router.

import NucleusRenderModel
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
@safe final class XdgPopup {
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    weak var parent: XdgSurface?
    private weak var layerParent: WlSurface?
    private let resource: WaylandResourceHandle<XdgPopupServer>
    /// The resolved parent-local placement (the last configure's geometry).
    private(set) var placement = WlRect(x: 0, y: 0, width: 1, height: 1)
    private var positioner: XdgPositionerSnapshot?
    private(set) var popupDoneSent = false

    init(
        resource: WaylandResourceHandle<XdgPopupServer>,
        shell: XdgShell,
        xdgSurface: XdgSurface,
        parent: XdgSurface?
    ) {
        self.resource = resource
        self.shell = shell
        self.xdgSurface = xdgSurface
        self.parent = parent
    }

    package func installed() {
        shell.registerPopup(self, clientID: resource.clientID)
    }

    var grabOriginSurface: WlSurface? {
        parent?.surface ?? layerParent
    }

    var hasValidParent: Bool {
        grabOriginSurface != nil
    }

    func adoptLayerParent(_ surface: WlSurface?) {
        guard let surface, let positioner,
            validateLayerParent(surface, positioner: positioner)
        else {
            xdgSurface?.postWmError(
                .invalidPositioner,
                "positioner is not valid for the layer-surface parent")
            return
        }
        layerParent = surface
        reconfigureUnderNewParent()
    }

    private func validateLayerParent(
        _ surface: WlSurface,
        positioner: XdgPositionerSnapshot
    ) -> Bool {
        guard positioner.parentConfigureSerial == nil,
            surface.hasCurrentBuffer
        else { return false }
        let width = Int32(
            clamping: Int(
                max(0, surface.committedLogicalWidth.rounded(.up))))
        let height = Int32(
            clamping: Int(
                max(0, surface.committedLogicalHeight.rounded(.up))))
        return positioner.isValid(
            parentWidth: width, parentHeight: height)
    }

    private func validateCurrentParent(
        _ positioner: XdgPositionerSnapshot
    ) -> Bool {
        if let parent {
            return parent.validatePositionerParentConfigure(positioner)
        }
        if let layerParent {
            return validateLayerParent(
                layerParent, positioner: positioner)
        }
        return false
    }

    /// Resolve `positioner` into a placement and send xdg_popup.configure. The
    /// caller pairs it with the xdg_surface.configure serial.
    @discardableResult
    func configure(positioner: XdgPositionerSnapshot) -> WlRect {
        self.positioner = positioner
        let base = positioner.resolve()
        placement =
            shell.delegate?.resolvePopup(
                self, positioner: positioner, base: base) ?? base
        resource.sendConfigure(
            x: placement.x, y: placement.y,
            width: placement.width, height: placement.height)
        return placement
    }

    /// xdg_popup.popup_done — the grab was dismissed; the client tears the popup down.
    func sendPopupDone() {
        guard !popupDoneSent else { return }
        popupDoneSent = true
        resource.sendPopupDone()
    }

    /// Re-resolve the current placement and send it under a fresh xdg_surface
    /// serial, including when a layer surface adopts the popup or output geometry
    /// changes.
    func reconfigureUnderNewParent() {
        guard let positioner else { return }
        let placement = configure(positioner: positioner)
        _ = xdgSurface?.sendConfigureSerial(
            roleState: .popup(placement), initial: false)
    }

    func reconfigureIfReactive() {
        guard positioner?.reactive == true else { return }
        reconfigureUnderNewParent()
    }

    isolated deinit {
        shell.unregisterPopup(self, clientID: resource.clientID)
        xdgSurface?.roleObjectDestroyed(self)
    }
}

extension XdgPopup: XdgPopupRequests {
    func destroy(_ request: WaylandRequest<XdgPopupServer>) {
        guard
            shell.canDestroyPopup(
                self,
                clientID: request.clientID)
        else {
            xdgSurface?.postWmError(
                .notTheTopmostPopup,
                "popup destruction must proceed topmost-first")
            return
        }
        shell.unregisterPopup(self, clientID: request.clientID)
        xdgSurface?.roleObjectDestroyed(self)
        request.destroy()
    }

    func grab(
        _ request: WaylandRequest<XdgPopupServer>, seat: WaylandBorrowedObject<WlSeatServer>,
        serial: UInt32
    ) {
        guard let seatOwner = seat.owner(as: SeatBinding.self)?.seat,
            let seatClientID = seat.clientID,
            shell.delegate?.popupGrabRequested(
                self,
                seat: seatOwner,
                seatClientID: seatClientID,
                serial: serial) == true
        else {
            xdgSurface?.postWmError(
                .invalidSurfaceState,
                "popup grab serial or seat is not authorized")
            return
        }
    }

    func reposition(
        _ request: WaylandRequest<XdgPopupServer>,
        positioner positionerRes: WaylandBorrowedObject<XdgPositionerServer>, token: UInt32
    ) {
        guard let positioner = positionerRes.owner(as: XdgPositioner.self),
            let snapshot = positioner.snapshot()
        else { return }
        guard validateCurrentParent(snapshot) else {
            xdgSurface?.postWmError(
                .invalidPositioner,
                "reposition parent configure is invalid")
            return
        }
        // repositioned(token) acks the reposition before the matching configure so
        // the client can correlate the new geometry.
        resource.sendRepositioned(token: token)
        let placement = configure(positioner: snapshot)
        _ = xdgSurface?.sendConfigureSerial(
            roleState: .popup(placement), initial: false)
    }
}
