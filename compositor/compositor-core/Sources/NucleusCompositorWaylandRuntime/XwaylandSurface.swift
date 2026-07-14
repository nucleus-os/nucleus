// XwaylandSurface — the X11 window-state record.
//
// Caches X11-side window state (geometry, class, WM_* hints, _NET_WM_* props,
// WM_PROTOCOLS bitset). Pure device/protocol state with no upward edges; the
// router xwayland driver pairs it with the Swift window model by surface object
// id. A reference type: it has identity (keyed by `windowID` in the XWM's window
// map) and the property parsers mutate it in place. ARC reclaims its owned
// strings + atom lists — no manual free.
//
// There is no XWM back-reference (a convenience for issuing XCB calls); the
// parsers take the connection + atoms explicitly.

import NucleusCompositorXcbC

/// ICCCM/EWMH WM_PROTOCOLS bits the compositor cares about. Parsed from the
/// WM_PROTOCOLS property. The bit order (delete_window=0 … sync_request=3) that
/// `protocolMask` depends on.
struct WmProtocols: Equatable {
    var deleteWindow = false
    var takeFocus = false
    var ping = false
    var syncRequest = false
}

/// WM_NORMAL_HINTS size constraints + resize steps (ICCCM §4.1.2.3). Zero = unset.
struct SizeHints: Equatable {
    var minWidth: UInt16 = 0
    var minHeight: UInt16 = 0
    var maxWidth: UInt16 = 0
    var maxHeight: UInt16 = 0
    var baseWidth: UInt16 = 0
    var baseHeight: UInt16 = 0
    var incWidth: UInt16 = 0
    var incHeight: UInt16 = 0
}

/// ICCCM WM_HINTS — we surface only `input` (willing to receive SetInputFocus;
/// defaults true per ICCCM §4.1.7) and `urgent`.
struct WmHints: Equatable {
    var input = true
    var urgent = false
}

final class XwaylandSurface {
    /// X11 window id. Primary key in the XWM window map.
    let windowID: xcb_window_t
    /// Pairing serial (xwayland_shell_v1.set_serial). Nil until learned.
    var serial: UInt64?
    /// Router model window id, set once this X window is paired with its router
    /// wl_surface (Xwayland is a router client). 0 until paired.
    var routerWindowID: UInt64 = 0

    // ── X11-side geometry (client-requested). Compositor-authoritative position
    //    lives on the paired Window once paired.
    var x: Int16 = 0
    var y: Int16 = 0
    var width: UInt16 = 0
    var height: UInt16 = 0
    let overrideRedirect: Bool
    /// Raw X11 MapNotify/UnmapNotify state for ICCCM/EWMH bookkeeping;
    /// compositor visibility is owned by the paired Window.
    var x11Mapped = false

    // ── Property cache. Populated lazily on PropertyNotify / before map.
    var title: String?
    var className: String?
    var instance: String?
    var startupID: String?
    var pid: UInt32?
    var transientFor: xcb_window_t?
    var protocols = WmProtocols()
    var hints = WmHints()
    var sizeHints = SizeHints()
    var windowTypes: [xcb_atom_t] = []
    var states: [xcb_atom_t] = []
    var userTime: UInt32 = 0
    /// Client requested no decorations via _MOTIF_WM_HINTS. Advisory.
    var decorationsOff = false

    // ── _NET_WM_SYNC_REQUEST protocol state.
    /// Counter XID from _NET_WM_SYNC_REQUEST_COUNTER (an `xcb_sync_counter_t`,
    /// itself a uint32 XID). 0 = client doesn't use the sync protocol.
    var syncCounter: UInt32 = 0
    /// Next value handed to the client in a _NET_WM_SYNC_REQUEST; must always grow.
    var pendingSyncValue: Int64 = 0

    init(windowID: xcb_window_t, overrideRedirect: Bool) {
        self.windowID = windowID
        self.overrideRedirect = overrideRedirect
    }
}
