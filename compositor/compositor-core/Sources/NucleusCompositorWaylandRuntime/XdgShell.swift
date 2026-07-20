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
// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

// MARK: - WindowManager / ConfigurePolicy / PopupPolicy seam

/// The toplevel size + states a configure carries. `states` holds raw
/// xdg_toplevel.state values in canonical order (the router serializes them into
/// the configure's wl_array).
struct XdgToplevelConfigure: Equatable {
    var width: Int32 = 0
    var height: Int32 = 0
    var states: [UInt32] = []
}

enum XdgRoleConfigure: Equatable {
    case toplevel(XdgToplevelConfigure)
    case popup(WlRect)
}

struct XdgConfigureRecord: Equatable {
    let serial: UInt32
    let roleState: XdgRoleConfigure
    let initial: Bool
}

/// A toplevel state/interaction request the window policy reacts to. Carries only
/// the protocol-decoded payload; the policy resolves it against the live window.
enum XdgToplevelRequest {
    case setTitle(String)
    case setAppId(String)
    case setParent(XdgToplevel?)
    case setMaximized(Bool)
    case setFullscreen(Bool, outputID: UInt64?)
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
    /// Validate the request's seat and user-input serial before an interactive
    /// operation is forwarded to policy.
    func authorizeInteractiveRequest(
        _ toplevel: XdgToplevel,
        seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32
    ) -> Bool
    /// A toplevel's wire object is being destroyed; drop its window.
    func toplevelWillDestroy(_ toplevel: XdgToplevel)
    /// Refine a popup's positioner placement against its parent's output
    /// (flip/slide/resize). `base` is the router's unconstrained parent-local rect.
    func resolvePopup(
        _ popup: XdgPopup,
        positioner: XdgPositionerSnapshot,
        base: WlRect
    ) -> WlRect
    func popupGrabRequested(
        _ popup: XdgPopup,
        seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32
    ) -> Bool
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
        guard surface.claimXdgConstruction() else {
            swift_wayland_resource_post_error(
                resource, surface.hasRole ? 0 /* role */ : 4 /* invalid_surface_state */,
                "wl_surface already has an XDG construction or committed state")
            return
        }
        let xdgSurface = XdgSurface(
            shell: shell, surface: surface, wmBaseResource: resource)
        guard let xres = id.create(vtable: XdgSurfaceServer.vtable, owner: xdgSurface)
        else {
            surface.releaseXdgConstruction()
            return
        }
        xdgSurface.bind(xres)
        surface.bindXdgConstructionRole(xdgSurface)
    }

    func pong(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {}  // liveness ack — no state to track
}

final class XdgShell {
    private final class WeakPopup {
        weak var popup: XdgPopup?
        init(_ popup: XdgPopup) { self.popup = popup }
    }
    private final class WeakToplevel {
        weak var toplevel: XdgToplevel?
        init(_ toplevel: XdgToplevel) { self.toplevel = toplevel }
    }

    weak var delegate: XdgShellDelegate?
    private var display: OpaquePointer?
    private var popupStacks: [UInt: [WeakPopup]] = [:]
    private var toplevels: [WeakToplevel] = []

    func register(in router: NucleusWaylandRouter) {
        display = router.display.display
        // Version 3 is implemented through positioner snapshots, parent configure
        // correlation, and reactive popup repositioning.
        router.addGlobal(
            interface: swift_wayland_iface_xdg_wm_base(), version: 3, impl: self, bind: Self.bind)
    }

    func nextSerial() -> UInt32 {
        guard let display else { return 0 }
        return wl_display_next_serial(display)
    }

    func registerPopup(_ popup: XdgPopup, resource: UnsafeMutablePointer<wl_resource>) {
        let key = UInt(bitPattern: wl_resource_get_client(resource))
        popupStacks[key, default: []].removeAll { $0.popup == nil }
        popupStacks[key, default: []].append(WeakPopup(popup))
    }

    func canDestroyPopup(
        _ popup: XdgPopup,
        resource: UnsafeMutablePointer<wl_resource>
    ) -> Bool {
        let key = UInt(bitPattern: wl_resource_get_client(resource))
        popupStacks[key, default: []].removeAll { $0.popup == nil }
        return popupStacks[key]?.last?.popup === popup
    }

    func unregisterPopup(
        _ popup: XdgPopup,
        resource: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let resource else { return }
        let key = UInt(bitPattern: wl_resource_get_client(resource))
        popupStacks[key]?.removeAll {
            $0.popup == nil || $0.popup === popup
        }
        if popupStacks[key]?.isEmpty == true { popupStacks[key] = nil }
    }

    func reconfigureReactivePopups(parent: XdgSurface) {
        let popups = popupStacks.values.flatMap { $0.compactMap(\.popup) }
        for popup in popups where popup.parent === parent {
            popup.reconfigureIfReactive()
        }
    }

    /// Output geometry, scale, work-area, or membership changed. Re-plan mapped
    /// toplevels and reactive popups from the same new topology snapshot.
    func outputTopologyChanged() {
        toplevels.removeAll { $0.toplevel == nil }
        for toplevel in toplevels.compactMap(\.toplevel)
        where toplevel.isMapped {
            toplevel.xdgSurface?.configureToplevel(
                initial: false)
        }
        let popups = popupStacks.values.flatMap {
            $0.compactMap(\.popup)
        }
        for popup in popups {
            popup.reconfigureIfReactive()
        }
    }

    func dismissPopups(parent: XdgSurface) {
        let descendants = popupStacks.values
            .flatMap { $0.compactMap(\.popup) }
            .filter { $0.parent === parent }
        for popup in descendants.reversed() {
            if let childSurface = popup.xdgSurface {
                dismissPopups(parent: childSurface)
            }
            popup.sendPopupDone()
        }
    }

    func registerToplevel(_ toplevel: XdgToplevel) {
        toplevels.removeAll { $0.toplevel == nil }
        toplevels.append(WeakToplevel(toplevel))
    }

    func unregisterToplevel(_ toplevel: XdgToplevel) {
        toplevels.removeAll {
            $0.toplevel == nil || $0.toplevel === toplevel
        }
    }

    /// Preserve the transient hierarchy when a mapped parent disappears: every
    /// direct child is reparented to the disappearing toplevel's own mapped
    /// parent, exactly as xdg-shell specifies.
    func toplevelDidUnmap(_ toplevel: XdgToplevel) {
        toplevels.removeAll { $0.toplevel == nil }
        let replacement = toplevel.protocolParent?.isMapped == true
            ? toplevel.protocolParent
            : nil
        for child in toplevels.compactMap(\.toplevel)
        where child.protocolParent === toplevel {
            child.applyProtocolParent(replacement)
        }
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
    var parentConfigureSerial: UInt32?

    var isComplete: Bool {
        sizeW > 0 && sizeH > 0
            && anchorRect.width > 0 && anchorRect.height > 0
    }

    func snapshot() -> XdgPositionerSnapshot? {
        guard isComplete else { return nil }
        return XdgPositionerSnapshot(
            sizeW: sizeW, sizeH: sizeH,
            anchorRect: anchorRect,
            anchor: anchor, gravity: gravity,
            constraintAdjustment: constraintAdjustment,
            offsetX: offsetX, offsetY: offsetY,
            reactive: reactive,
            parentWidth: parentWidth, parentHeight: parentHeight,
            parentConfigureSerial: parentConfigureSerial)
    }

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

struct XdgPositionerSnapshot: Equatable {
    let sizeW: Int32
    let sizeH: Int32
    let anchorRect: WlRect
    let anchor: UInt32
    let gravity: UInt32
    let constraintAdjustment: UInt32
    let offsetX: Int32
    let offsetY: Int32
    let reactive: Bool
    let parentWidth: Int32
    let parentHeight: Int32
    let parentConfigureSerial: UInt32?

    func resolve() -> WlRect {
        let positioner = XdgPositioner()
        positioner.sizeW = sizeW
        positioner.sizeH = sizeH
        positioner.anchorRect = anchorRect
        positioner.anchor = anchor
        positioner.gravity = gravity
        positioner.constraintAdjustment = constraintAdjustment
        positioner.offsetX = offsetX
        positioner.offsetY = offsetY
        return positioner.resolve()
    }

    /// Validate the parent-relative geometry contract at the point the snapshot
    /// is consumed. The anchor rectangle must stay inside the parent window
    /// geometry, and the unconstrained child must intersect or touch it.
    func isValid(parentWidth: Int32, parentHeight: Int32) -> Bool {
        guard parentWidth > 0, parentHeight > 0,
              anchorRect.x >= 0, anchorRect.y >= 0 else { return false }
        let anchorMaxX = Int64(anchorRect.x) + Int64(anchorRect.width)
        let anchorMaxY = Int64(anchorRect.y) + Int64(anchorRect.height)
        guard anchorMaxX <= Int64(parentWidth),
              anchorMaxY <= Int64(parentHeight) else { return false }

        let child = resolve()
        let childMaxX = Int64(child.x) + Int64(child.width)
        let childMaxY = Int64(child.y) + Int64(child.height)
        return Int64(child.x) <= Int64(parentWidth)
            && childMaxX >= 0
            && Int64(child.y) <= Int64(parentHeight)
            && childMaxY >= 0
    }
}

extension XdgPositioner: XdgPositionerRequests {
    func setSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(resource, 0, "positioner size must be positive")
            return
        }
        sizeW = width; sizeH = height
    }

    func setAnchorRect(
        _ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32
    ) {
        guard width >= 0, height >= 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "anchor rectangle dimensions must not be negative")
            return
        }
        anchorRect = WlRect(x: x, y: y, width: width, height: height)
    }

    func setAnchor(_ resource: UnsafeMutablePointer<wl_resource>, anchor: UInt32) {
        guard anchor <= 8 else {
            swift_wayland_resource_post_error(resource, 0, "invalid positioner anchor")
            return
        }
        self.anchor = anchor
    }

    func setGravity(_ resource: UnsafeMutablePointer<wl_resource>, gravity: UInt32) {
        guard gravity <= 8 else {
            swift_wayland_resource_post_error(resource, 0, "invalid positioner gravity")
            return
        }
        self.gravity = gravity
    }

    func setConstraintAdjustment(
        _ resource: UnsafeMutablePointer<wl_resource>, constraint_adjustment: UInt32
    ) {
        guard constraint_adjustment & ~UInt32(0x3f) == 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "invalid constraint-adjustment mask")
            return
        }
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
        guard parent_width > 0, parent_height > 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "parent size must be positive")
            return
        }
        parentWidth = parent_width; parentHeight = parent_height
    }

    func setParentConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {
        parentConfigureSerial = serial
    }
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
    private let wmBaseResource: UnsafeMutablePointer<wl_resource>

    private let configureLedger = XdgConfigureLedger()
    var lastConsumedConfigure: XdgConfigureRecord? {
        configureLedger.lastConsumed
    }
    private var pendingWindowGeometry: WlRect?
    private var pendingWindowGeometrySet = false
    private(set) var windowGeometry: WlRect?
    weak var toplevel: XdgToplevel?
    weak var popup: XdgPopup?
    private var roleAssigned = false
    private var mapped = false
    private var needsInitialConfigure = true
    var isMapped: Bool { mapped }
    var hasSentInitialConfigure: Bool {
        !needsInitialConfigure
    }

    init(
        shell: XdgShell,
        surface: WlSurface,
        wmBaseResource: UnsafeMutablePointer<wl_resource>
    ) {
        self.shell = shell
        self.surface = surface
        self.wmBaseResource = wmBaseResource
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    deinit {
        surface?.releaseXdgConstruction()
    }

    /// Send and ledger one complete configure record.
    @discardableResult
    func sendConfigureSerial(
        roleState: XdgRoleConfigure,
        initial: Bool
    ) -> UInt32 {
        let serial = shell.nextSerial()
        if let resource { xdg_surface_send_configure(resource, serial) }
        configureLedger.append(XdgConfigureRecord(
            serial: serial, roleState: roleState, initial: initial))
        return serial
    }

    /// Send a full toplevel configure cycle: the toplevel size+states half under a
    /// fresh serial, then the xdg_surface.configure serial.
    func configureToplevel(initial: Bool) {
        guard let toplevel else { return }
        toplevel.decoration?.sendConfigureIfNeeded()
        let plan = shell.delegate?.configure(for: toplevel, initial: initial) ?? XdgToplevelConfigure()
        toplevel.sendConfigure(plan)
        let serial = sendConfigureSerial(
            roleState: .toplevel(plan), initial: initial)
        shell.delegate?.toplevelConfigureSent(toplevel, serial: serial, initial: initial)
        shell.reconfigureReactivePopups(parent: self)
    }

    func hasConfigure(serial: UInt32) -> Bool {
        configureLedger.contains(serial: serial)
    }

    func validatePositionerParentConfigure(
        _ snapshot: XdgPositionerSnapshot
    ) -> Bool {
        if let serial = snapshot.parentConfigureSerial,
            !hasConfigure(serial: serial)
        {
            return false
        }
        let width = windowGeometry?.width
            ?? Int32(clamping: Int(
                max(0, surface?.committedLogicalWidth.rounded(.up) ?? 0)))
        let height = windowGeometry?.height
            ?? Int32(clamping: Int(
                max(0, surface?.committedLogicalHeight.rounded(.up) ?? 0)))
        return mapped && snapshot.isValid(
            parentWidth: width, parentHeight: height)
    }

    func roleObjectDestroyed(_ object: AnyObject) {
        if toplevel === object { toplevel = nil }
        if popup === object { popup = nil }
    }

    func postWmError(_ code: UInt32, _ message: String) {
        swift_wayland_resource_post_error(wmBaseResource, code, message)
    }

    // MARK: WlSurfaceRole

    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool {
        guard roleAssigned else {
            postWmError(
                1 /* not_constructed */,
                "xdg_surface must be given a role before wl_surface.commit")
            return false
        }
        guard context.willHaveBuffer, !mapped else { return true }
        if let popup, !popup.hasValidParent {
            postWmError(
                3 /* invalid_popup_parent */,
                "popup must be adopted by a valid parent before mapping")
            return false
        }
        guard configureLedger.acknowledged != nil else {
            if let resource {
                swift_wayland_resource_post_error(
                    resource, 3 /* unconfigured_buffer */,
                    "buffer committed before an initial configure was acknowledged")
            }
            return false
        }
        return true
    }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial _: Bool) {
        if pendingWindowGeometrySet {
            windowGeometry = clampedWindowGeometry(
                pendingWindowGeometry, surface: surface)
            pendingWindowGeometrySet = false
        }
        if !surface.hasCurrentBuffer {
            if mapped {
                mapped = false
                shell.dismissPopups(parent: self)
                if let toplevel {
                    shell.toplevelDidUnmap(toplevel)
                    shell.delegate?.toplevelDidCommit(
                        toplevel,
                        ackedSerial: lastConsumedConfigure?.serial ?? 0,
                        hasBuffer: false)
                }
                configureLedger.resetForUnmap()
                needsInitialConfigure = true
            }
            if needsInitialConfigure, toplevel != nil {
                configureToplevel(initial: true)
                needsInitialConfigure = false
            } else if needsInitialConfigure, let popup {
                popup.reconfigureUnderNewParent()
                needsInitialConfigure = false
            }
            return
        }
        _ = configureLedger.consumeAcknowledged()
        mapped = true
        if let toplevel, let consumed = lastConsumedConfigure {
            shell.delegate?.toplevelDidCommit(
                toplevel,
                ackedSerial: consumed.serial,
                hasBuffer: true)
        }
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }

    private func clampedWindowGeometry(
        _ geometry: WlRect?, surface: WlSurface
    ) -> WlRect? {
        guard let geometry else { return nil }
        let surfaceWidth = Int32(clamping: Int(
            max(1, surface.committedLogicalWidth.rounded(.up))))
        let surfaceHeight = Int32(clamping: Int(
            max(1, surface.committedLogicalHeight.rounded(.up))))
        let x = min(max(geometry.x, 0), surfaceWidth - 1)
        let y = min(max(geometry.y, 0), surfaceHeight - 1)
        let width = min(geometry.width, surfaceWidth - x)
        let height = min(geometry.height, surfaceHeight - y)
        return WlRect(
            x: x, y: y,
            width: max(1, width), height: max(1, height))
    }

}

// MARK: xdg_surface requests

extension XdgSurface: XdgSurfaceRequests {
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard toplevel == nil, popup == nil else {
            swift_wayland_resource_post_error(
                resource, 6 /* defunct_role_object */,
                "destroy the XDG role object before xdg_surface")
            return
        }
        surface?.releaseXdgConstruction()
        wl_resource_destroy(resource)
    }

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
            let positioner = WaylandResource.owner(
                of: positionerRes, as: XdgPositioner.self)
        else { return }
        guard let snapshot = positioner.snapshot() else {
            swift_wayland_resource_post_error(
                wmBaseResource, 5 /* invalid_positioner */,
                "positioner is incomplete")
            return
        }
        guard !roleAssigned, surface.assignRole(self) else {
            swift_wayland_resource_post_error(resource, 2 /* already_constructed */, "xdg_surface already has a role")
            return
        }
        roleAssigned = true
        let parent = parentRes.flatMap { WaylandResource.owner(of: $0, as: XdgSurface.self) }
        guard parent?.validatePositionerParentConfigure(snapshot) ?? true else {
            swift_wayland_resource_post_error(
                wmBaseResource, 5 /* invalid_positioner */,
                "positioner is not valid for the mapped parent geometry")
            return
        }
        let popup = XdgPopup(shell: shell, xdgSurface: self, parent: parent)
        guard let pres = id.create(vtable: XdgPopupServer.vtable, owner: popup)
        else { return }
        popup.bind(pres)
        self.popup = popup
        // A popup is configured immediately (placement is known at creation), then
        // the xdg_surface serial pairs it. The first commit maps it.
        let placement = popup.configure(positioner: snapshot)
        _ = sendConfigureSerial(
            roleState: .popup(placement), initial: true)
        needsInitialConfigure = false
    }

    func setWindowGeometry(
        _ resource: UnsafeMutablePointer<wl_resource>, x: Int32, y: Int32, width: Int32, height: Int32
    ) {
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(
                resource, 5 /* invalid_size */,
                "window geometry must have positive dimensions")
            return
        }
        pendingWindowGeometry = WlRect(
            x: x, y: y, width: width, height: height)
        pendingWindowGeometrySet = true
    }

    func ackConfigure(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32) {
        do {
            try configureLedger.acknowledge(serial: serial)
        } catch {
            swift_wayland_resource_post_error(
                resource, 4 /* invalid_serial */,
                "configure serial was not outstanding on this xdg_surface")
            return
        }
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
    private var minWidth: Int32 = 0
    private var minHeight: Int32 = 0
    private var maxWidth: Int32 = 0
    private var maxHeight: Int32 = 0
    weak var protocolParent: XdgToplevel?
    weak var decoration: XdgToplevelDecoration?
    var isMapped: Bool { xdgSurface?.isMapped == true }

    init(shell: XdgShell, xdgSurface: XdgSurface) {
        self.shell = shell
        self.xdgSurface = xdgSurface
        shell.registerToplevel(self)
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

    func applyProtocolParent(_ parent: XdgToplevel?) {
        protocolParent = parent
        request(.setParent(parent), replan: false)
    }

    private func wouldCreateParentCycle(_ parent: XdgToplevel) -> Bool {
        var ancestor: XdgToplevel? = parent
        while let current = ancestor {
            if current === self { return true }
            ancestor = current.protocolParent
        }
        return false
    }

    deinit {
        shell.toplevelDidUnmap(self)
        shell.unregisterToplevel(self)
        xdgSurface?.roleObjectDestroyed(self)
        shell.delegate?.toplevelWillDestroy(self)
    }
}

extension XdgToplevel: XdgToplevelRequests {
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        shell.toplevelDidUnmap(self)
        xdgSurface?.roleObjectDestroyed(self)
        wl_resource_destroy(resource)
    }

    func setParent(
        _ resource: UnsafeMutablePointer<wl_resource>, parent parentRes: UnsafeMutablePointer<wl_resource>?
    ) {
        let requested = parentRes.flatMap {
            WaylandResource.owner(of: $0, as: XdgToplevel.self)
        }
        if let requested, requested === self || wouldCreateParentCycle(requested) {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidParent,
                "parent must not be the toplevel or one of its descendants"
            ).post()
            return
        }
        applyProtocolParent(requested?.isMapped == true ? requested : nil)
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
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.showWindowMenu(serial: serial, x: x, y: y), replan: false)
    }

    func move(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?, serial: UInt32
    ) {
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.move(serial: serial), replan: false)
    }

    func resize(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32, edges: UInt32
    ) {
        let validEdges: Set<UInt32> = [1, 2, 4, 5, 6, 8, 9, 10]
        guard validEdges.contains(edges) else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidResizeEdge,
                "invalid resize edge"
            ).post()
            return
        }
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.resize(serial: serial, edges: edges), replan: false)
    }

    func setMaxSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (width == 0 || width >= minWidth),
            (height == 0 || height >= minHeight)
        else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidSize,
                "maximum size conflicts with minimum size"
            ).post()
            return
        }
        maxWidth = width
        maxHeight = height
        request(.setMaxSize(width: width, height: height), replan: false)
    }

    func setMinSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (maxWidth == 0 || width <= maxWidth),
            (maxHeight == 0 || height <= maxHeight)
        else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidSize,
                "minimum size conflicts with maximum size"
            ).post()
            return
        }
        minWidth = width
        minHeight = height
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
        request(
            .setFullscreen(
                true, outputID: WlOutput.from(output)?.outputId),
            replan: true)
    }

    func unsetFullscreen(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setFullscreen(false, outputID: nil), replan: true)
    }

    func setMinimized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMinimized, replan: false)
    }
}

// MARK: - xdg_popup

/// A popup role: positioned relative to its parent at creation, mapped on first
/// commit. Grab routing, outside/Escape dismissal, and reposition are driven by
/// the live seat and output topology.
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

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) {
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
