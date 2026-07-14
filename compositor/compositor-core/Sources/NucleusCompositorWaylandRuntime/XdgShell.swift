// xdg-shell on the router — the windowing protocols. xdg_wm_base is the global
// factory; xdg_positioner accumulates popup placement input; xdg_surface is the
// per-wl_surface configure hinge; xdg_toplevel and xdg_popup are the two roles.
//
// libwayland owns the wire/resource mechanics: object arguments arrive as live
// wl_resource pointers, so a popup's parent + positioner and a decoration's
// toplevel resolve directly through WaylandResource.owner — none of the retired
// per-client object maps (XdgWmBaseTable) are needed.
//
// This file owns the *protocol* half: the configure↔ack↔commit serial handshake,
// window-geometry tracking, the positioner's base anchor/gravity/offset math, and
// the wire events. The *policy* half — what size/states to configure a toplevel
// with, how a popup is constrained against its parent's output, and the window
// model a request mutates — is the XdgShellDelegate seam, wired to WindowManager /
// ConfigurePolicy at #12. The parity fixture stubs the delegate.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

// MARK: - Delegate seam (#12: WindowManager / ConfigurePolicy / PopupPolicy)

/// The toplevel size + states a configure carries. `states` holds raw
/// xdg_toplevel.state values in canonical order (the router serializes them into
/// the configure's wl_array).
struct XdgToplevelConfigure {
    var width: Int32 = 0
    var height: Int32 = 0
    var states: [UInt32] = []
}

/// A toplevel state/interaction request the window policy reacts to. Carries only
/// the protocol-decoded payload; the policy resolves it against the live window.
enum XdgToplevelRequest {
    case setTitle(String)
    case setAppId(String)
    case setParent(XdgToplevel?)
    case setMaximized(Bool)
    case setFullscreen(Bool)
    case setMinimized
    case setMinSize(width: Int32, height: Int32)
    case setMaxSize(width: Int32, height: Int32)
    case move(serial: UInt32)
    case resize(serial: UInt32, edges: UInt32)
    case showWindowMenu(serial: UInt32, x: Int32, y: Int32)
}

/// The policy seam for xdg-shell. The router drives the protocol; the delegate
/// supplies the windowing decisions. All methods run on the compositor turn.
protocol XdgShellDelegate: AnyObject {
    /// The configure to send for `toplevel`: `initial` is the first configure,
    /// sent in response to the surface's first (bufferless) commit; otherwise it
    /// is a re-plan triggered by a state request or a compositor change.
    func configure(for toplevel: XdgToplevel, initial: Bool) -> XdgToplevelConfigure
    /// The router minted and sent a configure (the size+states half then the
    /// xdg_surface.configure serial half). The driver records `serial` against the
    /// window so the ack→commit latch can match the pending configure. `initial`
    /// marks the first configure (sent on the surface's first bufferless commit).
    func toplevelConfigureSent(_ toplevel: XdgToplevel, serial: UInt32, initial: Bool)
    /// The client committed after acknowledging a configure. `hasBuffer` distinguishes
    /// map/re-layout from the null-buffer commit that unmaps the toplevel.
    func toplevelDidCommit(_ toplevel: XdgToplevel, ackedSerial: UInt32, hasBuffer: Bool)
    /// A toplevel request the window policy reacts to.
    func toplevelDidRequest(_ toplevel: XdgToplevel, _ request: XdgToplevelRequest)
    /// A toplevel's wire object is being destroyed; drop its window.
    func toplevelWillDestroy(_ toplevel: XdgToplevel)
    /// Refine a popup's positioner placement against its parent's output
    /// (flip/slide/resize). `base` is the router's unconstrained parent-local rect.
    func resolvePopup(_ popup: XdgPopup, base: WlRect) -> WlRect
}

extension XdgShellDelegate {
    func configure(for toplevel: XdgToplevel, initial: Bool) -> XdgToplevelConfigure {
        XdgToplevelConfigure()
    }
    func toplevelConfigureSent(_ toplevel: XdgToplevel, serial: UInt32, initial: Bool) {}
    func toplevelDidCommit(_ toplevel: XdgToplevel, ackedSerial: UInt32, hasBuffer: Bool) {}
    func toplevelDidRequest(_ toplevel: XdgToplevel, _ request: XdgToplevelRequest) {}
    func toplevelWillDestroy(_ toplevel: XdgToplevel) {}
    func resolvePopup(_ popup: XdgPopup, base: WlRect) -> WlRect { base }
}

// MARK: - xdg_wm_base global

/// Owner bound to each xdg_wm_base resource (Rule 9). Routes its requests back to
/// the shared XdgShell.
final class XdgWmBaseBinding {
    unowned let shell: XdgShell
    init(_ shell: XdgShell) { self.shell = shell }
}

// The xdg_wm_base request handlers, recovered by XdgWmBaseServer.vtable from the
// per-resource XdgWmBaseBinding owner and forwarded to the shared XdgShell.
extension XdgWmBaseBinding: XdgWmBaseRequests {
    func createPositioner(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        _ = id.create(vtable: XdgPositionerServer.vtable, owner: XdgPositioner())
    }

    func getXdgSurface(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface surfaceRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surfaceRes,
            let surface = WaylandResource.owner(of: surfaceRes, as: WlSurface.self)
        else { return }
        let xdgSurface = XdgSurface(shell: shell, surface: surface)
        guard let xres = id.create(vtable: XdgSurfaceServer.vtable, owner: xdgSurface)
        else { return }
        xdgSurface.bind(xres)
    }

    func pong(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {}  // liveness ack — no state to track
}

final class XdgShell {
    weak var delegate: XdgShellDelegate?
    private var display: OpaquePointer?

    func register(in router: NucleusWaylandRouter) {
        display = router.display.display
        router.addGlobal(
            interface: swift_wayland_iface_xdg_wm_base(), version: 7, impl: self, bind: Self.bind)
    }

    func nextSerial() -> UInt32 {
        guard let display else { return 0 }
        return wl_display_next_serial(display)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgShell.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_xdg_wm_base(), version: Int32(version),
            id: id, vtable: XdgWmBaseServer.vtable, owner: XdgWmBaseBinding(me))
    }
}

// MARK: - xdg_positioner

/// Accumulates popup placement input. `resolve()` computes the unconstrained
/// parent-local rect from anchor/gravity/offset; the delegate constrains it.
final class XdgPositioner {
    var sizeW: Int32 = 0
    var sizeH: Int32 = 0
    var anchorRect = WlRect(x: 0, y: 0, width: 0, height: 0)
    var anchor: UInt32 = 0
    var gravity: UInt32 = 0
    var constraintAdjustment: UInt32 = 0
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var reactive = false
    var parentWidth: Int32 = 0
    var parentHeight: Int32 = 0

    /// The unconstrained placement: the anchor point on the anchor rect, shifted by
    /// the gravity direction, plus the offset. (xdg_positioner anchor/gravity enums:
    /// none=0, top=1, bottom=2, left=3, right=4, top_left=5, bottom_left=6,
    /// top_right=7, bottom_right=8.)
    func resolve() -> WlRect {
        let w = max(1, sizeW)
        let h = max(1, sizeH)
        let isLeft: (UInt32) -> Bool = { $0 == 3 || $0 == 5 || $0 == 6 }
        let isRight: (UInt32) -> Bool = { $0 == 4 || $0 == 7 || $0 == 8 }
        let isTop: (UInt32) -> Bool = { $0 == 1 || $0 == 5 || $0 == 7 }
        let isBottom: (UInt32) -> Bool = { $0 == 2 || $0 == 6 || $0 == 8 }

        var ax = anchorRect.x + anchorRect.width / 2
        if isLeft(anchor) { ax = anchorRect.x }
        else if isRight(anchor) { ax = anchorRect.x + anchorRect.width }
        var ay = anchorRect.y + anchorRect.height / 2
        if isTop(anchor) { ay = anchorRect.y }
        else if isBottom(anchor) { ay = anchorRect.y + anchorRect.height }

        var x = ax - w / 2
        if isLeft(gravity) { x = ax - w }
        else if isRight(gravity) { x = ax }
        var y = ay - h / 2
        if isTop(gravity) { y = ay - h }
        else if isBottom(gravity) { y = ay }

        return WlRect(x: x + offsetX, y: y + offsetY, width: w, height: h)
    }

}

extension XdgPositioner: XdgPositionerRequests {
    func setSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        sizeW = width; sizeH = height
    }

    func setAnchorRect(
        _ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32
    ) {
        anchorRect = WlRect(x: x, y: y, width: width, height: height)
    }

    func setAnchor(_ resource: UnsafeMutablePointer<wl_resource>, anchor: UInt32) {
        self.anchor = anchor
    }

    func setGravity(_ resource: UnsafeMutablePointer<wl_resource>, gravity: UInt32) {
        self.gravity = gravity
    }

    func setConstraintAdjustment(
        _ resource: UnsafeMutablePointer<wl_resource>, constraint_adjustment: UInt32
    ) {
        constraintAdjustment = constraint_adjustment
    }

    func setOffset(_ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32) {
        offsetX = x; offsetY = y
    }

    func setReactive(_ resource: UnsafeMutablePointer<wl_resource>) {
        reactive = true
    }

    func setParentSize(
        _ resource: UnsafeMutablePointer<wl_resource>, parent_width: Int32, parent_height: Int32
    ) {
        parentWidth = parent_width; parentHeight = parent_height
    }

    func setParentConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {}  // reactive repositioning is a #12 refinement
}

// MARK: - xdg_surface

/// The configure hinge for one wl_surface. Sends the xdg_surface.configure serial
/// half of each configure cycle, tracks the acked serial + window geometry, and —
/// as the surface's WlSurfaceRole — drives the role's initial configure on the
/// first commit and the ack→commit latch on later commits.
final class XdgSurface: WlSurfaceRole {
    unowned let shell: XdgShell
    weak var surface: WlSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?

    private(set) var ackedSerial: UInt32 = 0
    var windowGeometry: WlRect?
    weak var toplevel: XdgToplevel?
    weak var popup: XdgPopup?
    private var roleAssigned = false

    init(shell: XdgShell, surface: WlSurface) {
        self.shell = shell
        self.surface = surface
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Send the xdg_surface.configure(serial) half; returns the serial used.
    @discardableResult
    func sendConfigureSerial() -> UInt32 {
        let serial = shell.nextSerial()
        if let resource { xdg_surface_send_configure(resource, serial) }
        return serial
    }

    /// Send a full toplevel configure cycle: the toplevel size+states half under a
    /// fresh serial, then the xdg_surface.configure serial.
    func configureToplevel(initial: Bool) {
        guard let toplevel else { return }
        let plan = shell.delegate?.configure(for: toplevel, initial: initial) ?? XdgToplevelConfigure()
        toplevel.sendConfigure(plan)
        let serial = sendConfigureSerial()
        shell.delegate?.toplevelConfigureSent(toplevel, serial: serial, initial: initial)
    }

    // MARK: WlSurfaceRole

    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {
        if isInitial {
            // The first (bufferless) commit elicits the initial configure. A
            // toplevel sends it now; a popup was already configured at get_popup.
            if toplevel != nil { configureToplevel(initial: true) }
        } else if let toplevel {
            shell.delegate?.toplevelDidCommit(
                toplevel, ackedSerial: ackedSerial, hasBuffer: surface.hasCurrentBuffer)
        }
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }

}

// MARK: xdg_surface requests

extension XdgSurface: XdgSurfaceRequests {
    func getToplevel(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        guard let surface else { return }
        guard !roleAssigned, surface.assignRole(self) else {
            swift_wayland_resource_post_error(resource, 2 /* already_constructed */, "xdg_surface already has a role")
            return
        }
        roleAssigned = true
        let toplevel = XdgToplevel(shell: shell, xdgSurface: self)
        guard let tres = id.create(vtable: XdgToplevelServer.vtable, owner: toplevel)
        else { return }
        toplevel.bind(tres)
        self.toplevel = toplevel
        // The initial configure is sent at the surface's first commit (xdg-shell
        // requires the configure follow the first commit, not the role request).
    }

    func getPopup(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        parent parentRes: UnsafeMutablePointer<wl_resource>?,
        positioner positionerRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let surface, let positionerRes,
            let positioner = WaylandResource.owner(of: positionerRes, as: XdgPositioner.self)
        else { return }
        guard !roleAssigned, surface.assignRole(self) else {
            swift_wayland_resource_post_error(resource, 2 /* already_constructed */, "xdg_surface already has a role")
            return
        }
        roleAssigned = true
        let parent = parentRes.flatMap { WaylandResource.owner(of: $0, as: XdgSurface.self) }
        let popup = XdgPopup(shell: shell, xdgSurface: self, parent: parent)
        guard let pres = id.create(vtable: XdgPopupServer.vtable, owner: popup)
        else { return }
        popup.bind(pres)
        self.popup = popup
        // A popup is configured immediately (placement is known at creation), then
        // the xdg_surface serial pairs it. The first commit maps it.
        popup.configure(positioner: positioner)
        sendConfigureSerial()
    }

    func setWindowGeometry(
        _ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32
    ) {
        windowGeometry = WlRect(x: x, y: y, width: width, height: height)
    }

    func ackConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {
        ackedSerial = serial
    }
}

// MARK: - xdg_toplevel

/// A toplevel window role. Owns its protocol identity; the window model + configure
/// policy live behind the XdgShellDelegate. A request mutates no window state here:
/// it is decoded and handed to the delegate, then a re-plan configure is sent for
/// state-changing requests.
final class XdgToplevel {
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    /// The most recent window geometry the surface declared (visible content rect).
    var windowGeometry: WlRect? { xdgSurface?.windowGeometry }

    init(shell: XdgShell, xdgSurface: XdgSurface) {
        self.shell = shell
        self.xdgSurface = xdgSurface
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Send xdg_toplevel.configure(width, height, states) — the states serialized
    /// into the configure's wl_array as little-endian u32s.
    func sendConfigure(_ plan: XdgToplevelConfigure) {
        guard let resource else { return }
        var states = wl_array()
        wl_array_init(&states)
        for state in plan.states {
            if let slot = wl_array_add(&states, MemoryLayout<UInt32>.size) {
                slot.assumingMemoryBound(to: UInt32.self).pointee = state
            }
        }
        xdg_toplevel_send_configure(resource, plan.width, plan.height, &states)
        wl_array_release(&states)
    }

    /// Ask the client to close (xdg_toplevel.close).
    func sendClose() {
        if let resource { xdg_toplevel_send_close(resource) }
    }

    private func request(_ r: XdgToplevelRequest, replan: Bool) {
        shell.delegate?.toplevelDidRequest(self, r)
        if replan { xdgSurface?.configureToplevel(initial: false) }
    }

    deinit { shell.delegate?.toplevelWillDestroy(self) }
}

extension XdgToplevel: XdgToplevelRequests {
    func setParent(
        _ resource: UnsafeMutablePointer<wl_resource>, parent parentRes: UnsafeMutablePointer<wl_resource>?
    ) {
        let parent = parentRes.flatMap { WaylandResource.owner(of: $0, as: XdgToplevel.self) }
        request(.setParent(parent), replan: false)
    }

    func setTitle(_ resource: UnsafeMutablePointer<wl_resource>, title: UnsafePointer<CChar>?) {
        request(.setTitle(title.map { String(cString: $0) } ?? ""), replan: false)
    }

    func setAppId(_ resource: UnsafeMutablePointer<wl_resource>, app_id: UnsafePointer<CChar>?) {
        request(.setAppId(app_id.map { String(cString: $0) } ?? ""), replan: false)
    }

    func showWindowMenu(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32, x: Int32, y: Int32
    ) {
        request(.showWindowMenu(serial: serial, x: x, y: y), replan: false)
    }

    func move(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?, serial: UInt32
    ) {
        request(.move(serial: serial), replan: false)
    }

    func resize(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32, edges: UInt32
    ) {
        request(.resize(serial: serial, edges: edges), replan: false)
    }

    func setMaxSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        request(.setMaxSize(width: width, height: height), replan: false)
    }

    func setMinSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        request(.setMinSize(width: width, height: height), replan: false)
    }

    func setMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMaximized(true), replan: true)
    }

    func unsetMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMaximized(false), replan: true)
    }

    func setFullscreen(
        _ resource: UnsafeMutablePointer<wl_resource>, output: UnsafeMutablePointer<wl_resource>?
    ) {
        request(.setFullscreen(true), replan: true)
    }

    func unsetFullscreen(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setFullscreen(false), replan: true)
    }

    func setMinimized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMinimized, replan: false)
    }
}

// MARK: - xdg_popup

/// A popup role: positioned relative to its parent at creation, mapped on first
/// commit. grab/reposition are handled here; the dismissal (popup_done) is driven
/// by the seat grab at #12.
final class XdgPopup {
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    weak var parent: XdgSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    /// The resolved parent-local placement (the last configure's geometry).
    private(set) var placement = WlRect(x: 0, y: 0, width: 1, height: 1)

    init(shell: XdgShell, xdgSurface: XdgSurface, parent: XdgSurface?) {
        self.shell = shell
        self.xdgSurface = xdgSurface
        self.parent = parent
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Resolve `positioner` into a placement and send xdg_popup.configure. The
    /// caller pairs it with the xdg_surface.configure serial.
    func configure(positioner: XdgPositioner) {
        let base = positioner.resolve()
        placement = shell.delegate?.resolvePopup(self, base: base) ?? base
        if let resource {
            xdg_popup_send_configure(resource, placement.x, placement.y, placement.width, placement.height)
        }
    }

    /// xdg_popup.popup_done — the grab was dismissed; the client tears the popup down.
    func sendPopupDone() {
        if let resource { xdg_popup_send_popup_done(resource) }
    }

    /// Re-send the current placement configure under a fresh xdg_surface serial,
    /// for a layer surface adopting this popup (zwlr_layer_surface_v1.get_popup).
    /// Re-resolving the placement against the layer surface's geometry is a #12
    /// policy refinement; the protocol mechanic is the cross-global re-configure.
    func reconfigureUnderNewParent() {
        if let resource {
            xdg_popup_send_configure(resource, placement.x, placement.y, placement.width, placement.height)
        }
        xdgSurface?.sendConfigureSerial()
    }

}

extension XdgPopup: XdgPopupRequests {
    func grab(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?, serial: UInt32
    ) {}  // modal grab is wired to the seat at #12

    func reposition(
        _ resource: UnsafeMutablePointer<wl_resource>,
        positioner positionerRes: UnsafeMutablePointer<wl_resource>?, token: UInt32
    ) {
        guard let positionerRes,
            let positioner = WaylandResource.owner(of: positionerRes, as: XdgPositioner.self)
        else { return }
        // repositioned(token) acks the reposition before the matching configure so
        // the client can correlate the new geometry.
        if let resource = self.resource { xdg_popup_send_repositioned(resource, token) }
        configure(positioner: positioner)
        xdgSurface?.sendConfigureSerial()
    }
}
