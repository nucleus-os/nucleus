// X11 atom interning table.
//
// Batched InternAtom round-trip at XWM startup (one cookie per atom, all replies
// flushed in one pump). Covers the standard XWM/EWMH atoms plus the
// xwayland_shell_v1 `WL_SURFACE_SERIAL` atom.
//
// Phase 6 step 2: a pure-data port, compiled and unit-tested (the enum set +
// names) but not yet wired into the live XWM — the existing atom table stays
// authoritative until the step-4 cutover.

import Glibc
import NucleusCompositorXcbC

// Each case's implicit `String` raw value equals its name verbatim — including
// leading underscores — which is exactly the X11 atom's wire name, so no separate
// name table is needed.
enum AtomId: String, CaseIterable {
    // Pairing (xwayland_shell_v1).
    case WL_SURFACE_SERIAL
    /// Legacy pairing atom; interned only for diagnostic logging so we can
    /// identify when Xwayland falls back to the pre-shell_v1 path.
    case WL_SURFACE_ID

    // Core ICCCM.
    case WM_PROTOCOLS
    case WM_DELETE_WINDOW
    case WM_TAKE_FOCUS
    case WM_STATE
    case WM_CHANGE_STATE
    case WM_NORMAL_HINTS
    case WM_HINTS
    case WM_CLIENT_MACHINE
    case WM_S0
    case WM_WINDOW_ROLE
    case WM_NAME
    case WM_CLASS
    case WM_TRANSIENT_FOR

    // Encoded string types.
    case UTF8_STRING
    case COMPOUND_TEXT
    case TEXT
    case STRING
    case CARDINAL
    case ATOM

    // EWMH / NetWM root + per-window properties.
    case _NET_ACTIVE_WINDOW
    case _NET_CLIENT_LIST
    case _NET_CLIENT_LIST_STACKING
    case _NET_CLOSE_WINDOW
    case _NET_CURRENT_DESKTOP
    case _NET_DESKTOP_GEOMETRY
    case _NET_DESKTOP_VIEWPORT
    case _NET_MOVERESIZE_WINDOW
    case _NET_NUMBER_OF_DESKTOPS
    case _NET_SUPPORTED
    case _NET_SUPPORTING_WM_CHECK
    case _NET_WORKAREA
    case _NET_WM_CM_S0
    case _NET_WM_NAME
    case _NET_WM_ICON_NAME
    case _NET_WM_PID
    case _NET_WM_STATE
    case _NET_WM_WINDOW_TYPE
    case _NET_STARTUP_ID
    case _NET_WM_MOVERESIZE
    case _NET_WM_STRUT_PARTIAL
    case _NET_WM_USER_TIME

    // Window type values.
    case _NET_WM_WINDOW_TYPE_COMBO
    case _NET_WM_WINDOW_TYPE_DESKTOP
    case _NET_WM_WINDOW_TYPE_DIALOG
    case _NET_WM_WINDOW_TYPE_DND
    case _NET_WM_WINDOW_TYPE_DOCK
    case _NET_WM_WINDOW_TYPE_DROPDOWN_MENU
    case _NET_WM_WINDOW_TYPE_MENU
    case _NET_WM_WINDOW_TYPE_NORMAL
    case _NET_WM_WINDOW_TYPE_NOTIFICATION
    case _NET_WM_WINDOW_TYPE_POPUP_MENU
    case _NET_WM_WINDOW_TYPE_SPLASH
    case _NET_WM_WINDOW_TYPE_TOOLBAR
    case _NET_WM_WINDOW_TYPE_TOOLTIP
    case _NET_WM_WINDOW_TYPE_UTILITY

    // State values.
    case _NET_WM_STATE_ABOVE
    case _NET_WM_STATE_BELOW
    case _NET_WM_STATE_DEMANDS_ATTENTION
    case _NET_WM_STATE_FOCUSED
    case _NET_WM_STATE_FULLSCREEN
    case _NET_WM_STATE_HIDDEN
    case _NET_WM_STATE_MAXIMIZED_HORZ
    case _NET_WM_STATE_MAXIMIZED_VERT
    case _NET_WM_STATE_MODAL
    case _NET_WM_STATE_SKIP_PAGER
    case _NET_WM_STATE_SKIP_TASKBAR
    case _NET_WM_STATE_STICKY

    // WM_PROTOCOLS values beyond WM_DELETE_WINDOW / WM_TAKE_FOCUS.
    case _NET_WM_PING
    case _NET_WM_SYNC_REQUEST
    /// Per-window XSync counter XID, set by clients that implement the sync
    /// protocol. WM bumps a value on each configure; the client sets the counter
    /// to that value once it has drawn the configured size.
    case _NET_WM_SYNC_REQUEST_COUNTER

    // Motif hints (decorations).
    case _MOTIF_WM_HINTS

    // Xwayland-specific: compositor consent to map.
    case _XWAYLAND_ALLOW_COMMITS

    // Root resource database (X resources, including Xft.dpi).
    case RESOURCE_MANAGER

    // XSETTINGS protocol — modern per-screen settings (DPI, theme, etc.) used by
    // GTK / Qt / Xft clients. `_XSETTINGS_S0` is the selection atom; the settings
    // payload lives on `_XSETTINGS_SETTINGS`.
    case _XSETTINGS_S0
    case _XSETTINGS_SETTINGS

    /// The X11 atom wire name (the case name verbatim).
    var wireName: String { rawValue }
}

/// Resolved atom ids, indexed by `AtomId`. Forward (`AtomId` → atom) for emitting
/// properties; reverse (atom → `AtomId`) for classifying an incoming PropertyNotify
/// or ClientMessage by its known atom. An unresolved atom reads back as 0.
struct AtomTable {
    private var forward: [xcb_atom_t]
    private var reverse: [xcb_atom_t: AtomId]

    init() {
        forward = [xcb_atom_t](repeating: 0, count: AtomId.allCases.count)
        reverse = [:]
    }

    subscript(_ id: AtomId) -> xcb_atom_t {
        get { forward[Self.index(id)] }
        set {
            forward[Self.index(id)] = newValue
            if newValue != 0 { reverse[newValue] = id }
        }
    }

    /// Classify a raw atom as one of our known `AtomId`s, or nil if unknown.
    func id(of atom: xcb_atom_t) -> AtomId? {
        atom == 0 ? nil : reverse[atom]
    }

    private static func index(_ id: AtomId) -> Int {
        AtomId.allCases.firstIndex(of: id)!
    }
}

/// Batch-intern every `AtomId` on `conn`: send all InternAtom requests (single
/// flush) then collect replies. A failed reply leaves that atom at 0.
func internAllAtoms(_ conn: OpaquePointer) -> AtomTable {
    var cookies: [(AtomId, xcb_intern_atom_cookie_t)] = []
    cookies.reserveCapacity(AtomId.allCases.count)
    for id in AtomId.allCases {
        let name = id.wireName
        let cookie = name.withCString { ptr in
            xcb_intern_atom(conn, 0 /* only_if_exists=0: create if absent */, UInt16(name.utf8.count), ptr)
        }
        cookies.append((id, cookie))
    }
    _ = xcb_flush(conn)

    var table = AtomTable()
    for (id, cookie) in cookies {
        if let reply = xcb_intern_atom_reply(conn, cookie, nil) {
            table[id] = reply.pointee.atom
            free(reply)
        } else {
            table[id] = 0
        }
    }
    return table
}
