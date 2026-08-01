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

internal import NucleusCompositorWindowManager
import WaylandServer
import WaylandServerC
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
    let serial: XdgConfigureSerial
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
@MainActor
protocol XdgShellDelegate: AnyObject {
    /// The configure to send for `toplevel`: `initial` is the first configure,
    /// sent in response to the surface's first (bufferless) commit; otherwise it
    /// is a re-plan triggered by a state request or a compositor change.
    func configure(for toplevel: XdgToplevel, initial: Bool) -> XdgToplevelConfigure
    /// The router minted and sent a configure (the size+states half then the
    /// xdg_surface.configure serial half). The driver records `serial` against the
    /// window so the ack→commit latch can match the pending configure. `initial`
    /// marks the first configure (sent on the surface's first bufferless commit).
    func toplevelConfigureSent(
        _ toplevel: XdgToplevel,
        serial: XdgConfigureSerial,
        initial: Bool)
    /// The client committed after acknowledging a configure. `hasBuffer` distinguishes
    /// map/re-layout from the null-buffer commit that unmaps the toplevel.
    func toplevelDidCommit(
        _ toplevel: XdgToplevel,
        ackedSerial: XdgConfigureSerial,
        hasBuffer: Bool)
    /// A toplevel request the window policy reacts to.
    func toplevelDidRequest(_ toplevel: XdgToplevel, _ request: XdgToplevelRequest)
    /// Validate the request's seat and user-input serial before an interactive
    /// operation is forwarded to policy.
    func authorizeInteractiveRequest(
        _ toplevel: XdgToplevel,
        seat: WlSeat,
        seatClientID: WaylandClientID,
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
        seat: WlSeat,
        seatClientID: WaylandClientID,
        serial: UInt32
    ) -> Bool
}

// MARK: - xdg_wm_base global

/// Owner bound to each xdg_wm_base resource (Rule 9). Routes its requests back to
/// the shared XdgShell.
@MainActor
@safe final class XdgShell {
    weak var delegate: (any XdgShellDelegate)?
    private let display: WaylandDisplay
    private var popupStacks: [WaylandClientID: WeakObjectList<XdgPopup>] = [:]
    private var toplevels = WeakObjectList<XdgToplevel>()
    private var nextToplevelRawID: UInt64 = 1

    init(display: WaylandDisplay) {
        self.display = display
    }

    func nextSerial() -> XdgConfigureSerial {
        XdgConfigureSerial(rawValue: display.nextSerial())
    }

    func mintToplevelID() -> XdgToplevelID {
        precondition(
            nextToplevelRawID != UInt64.max,
            "XDG toplevel identity space exhausted")
        let id = XdgToplevelID(nextToplevelRawID)
        nextToplevelRawID += 1
        return id
    }

    func registerPopup(
        _ popup: XdgPopup,
        clientID: WaylandClientID?
    ) {
        guard let key = clientID else { return }
        popupStacks[key, default: WeakObjectList()].append(popup)
    }

    func canDestroyPopup(
        _ popup: XdgPopup,
        clientID: WaylandClientID?
    ) -> Bool {
        guard let key = clientID else { return false }
        return popupStacks[key]?.last === popup
    }

    func unregisterPopup(
        _ popup: XdgPopup,
        clientID: WaylandClientID?
    ) {
        guard let key = clientID else { return }
        popupStacks[key]?.remove(popup)
        if popupStacks[key]?.isEmpty == true { popupStacks[key] = nil }
    }

    func reconfigureReactivePopups(parent: XdgSurface) {
        for popup in livePopups() where popup.parent === parent {
            popup.reconfigureIfReactive()
        }
    }

    /// Output geometry, scale, work-area, or membership changed. Re-plan mapped
    /// toplevels and reactive popups from the same new topology snapshot.
    func outputTopologyChanged() {
        for toplevel in toplevels.liveValues()
        where toplevel.isMapped {
            toplevel.xdgSurface?.configureToplevel(
                initial: false)
        }
        for popup in livePopups() {
            popup.reconfigureIfReactive()
        }
    }

    func dismissPopups(parent: XdgSurface) {
        let descendants = livePopups()
            .filter { $0.parent === parent }
        for popup in descendants.reversed() {
            if let childSurface = popup.xdgSurface {
                dismissPopups(parent: childSurface)
            }
            popup.sendPopupDone()
        }
    }

    func registerToplevel(_ toplevel: XdgToplevel) {
        toplevels.append(toplevel)
    }

    func unregisterToplevel(_ toplevel: XdgToplevel) {
        toplevels.remove(toplevel)
    }

    /// Preserve the transient hierarchy when a mapped parent disappears: every
    /// direct child is reparented to the disappearing toplevel's own mapped
    /// parent, exactly as xdg-shell specifies.
    func toplevelDidUnmap(_ toplevel: XdgToplevel) {
        let replacement =
            toplevel.protocolParent?.isMapped == true
            ? toplevel.protocolParent
            : nil
        for child in toplevels.liveValues()
        where child.protocolParent === toplevel {
            child.applyProtocolParent(replacement)
        }
    }

    private func livePopups() -> [XdgPopup] {
        var result: [XdgPopup] = []
        for key in Array(popupStacks.keys) {
            result.append(contentsOf: popupStacks[key]?.liveValues() ?? [])
            if popupStacks[key]?.isEmpty == true {
                popupStacks[key] = nil
            }
        }
        return result
    }

}

// MARK: - xdg_surface

/// The configure hinge for one wl_surface. Sends the xdg_surface.configure serial
/// half of each configure cycle, tracks the acked serial + window geometry, and —
/// as the surface's WlSurfaceRole — drives the role's initial configure on the
/// first commit and the ack→commit latch on later commits.
