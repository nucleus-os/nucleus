// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class XdgPopup {
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    weak var parent: XdgSurface?
    private weak var layerParent: WlSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    /// The resolved parent-local placement (the last configure's geometry).
    private(set) var placement = WlRect(x: 0, y: 0, width: 1, height: 1)
    private var positioner: XdgPositionerSnapshot?
    private(set) var popupDoneSent = false

    init(shell: XdgShell, xdgSurface: XdgSurface, parent: XdgSurface?) {
        self.shell = shell
        self.xdgSurface = xdgSurface
        self.parent = parent
    }

    package func bind(_ resource: UnsafeMutablePointer<wl_resource>) {
        self.resource = resource
        shell.registerPopup(self, resource: resource)
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
                5 /* invalid_positioner */,
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
        let width = Int32(clamping: Int(
            max(0, surface.committedLogicalWidth.rounded(.up))))
        let height = Int32(clamping: Int(
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
        placement = shell.delegate?.resolvePopup(
            self, positioner: positioner, base: base) ?? base
        if let resource {
            xdg_popup_send_configure(resource, placement.x, placement.y, placement.width, placement.height)
        }
        return placement
    }

    /// xdg_popup.popup_done — the grab was dismissed; the client tears the popup down.
    func sendPopupDone() {
        guard !popupDoneSent else { return }
        popupDoneSent = true
        if let resource { xdg_popup_send_popup_done(resource) }
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

    deinit {
        shell.unregisterPopup(self, resource: resource)
        xdgSurface?.roleObjectDestroyed(self)
    }
}

extension XdgPopup: XdgPopupRequests {
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard shell.canDestroyPopup(self, resource: resource) else {
            xdgSurface?.postWmError(
                2 /* not_the_topmost_popup */,
                "popup destruction must proceed topmost-first")
            return
        }
        shell.unregisterPopup(self, resource: resource)
        xdgSurface?.roleObjectDestroyed(self)
        wl_resource_destroy(resource)
    }

    func grab(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?, serial: UInt32
    ) {
        guard shell.delegate?.popupGrabRequested(
            self, seat: seat, serial: serial) == true
        else {
            xdgSurface?.postWmError(
                4 /* invalid_surface_state */,
                "popup grab serial or seat is not authorized")
            return
        }
    }

    func reposition(
        _ resource: UnsafeMutablePointer<wl_resource>,
        positioner positionerRes: UnsafeMutablePointer<wl_resource>?, token: UInt32
    ) {
        guard let positionerRes,
            let positioner = WaylandResource.owner(
                of: positionerRes, as: XdgPositioner.self),
            let snapshot = positioner.snapshot()
        else { return }
        guard validateCurrentParent(snapshot) else {
            xdgSurface?.postWmError(
                5 /* invalid_positioner */,
                "reposition parent configure is invalid")
            return
        }
        // repositioned(token) acks the reposition before the matching configure so
        // the client can correlate the new geometry.
        if let resource = self.resource { xdg_popup_send_repositioned(resource, token) }
        let placement = configure(positioner: snapshot)
        _ = xdgSurface?.sendConfigureSerial(
            roleState: .popup(placement), initial: false)
    }
}
import NucleusRenderModel
