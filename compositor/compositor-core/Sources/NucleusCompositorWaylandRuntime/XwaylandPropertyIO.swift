// Connection-bound ICCCM/EWMH property mechanics — the writeback/refresh half.
// The pure reply→state parsing lives in
// XwaylandProperties.swift; this file owns the XCB I/O that subscribes to,
// fetches, and publishes the tracked window properties over a live connection.
// The Swift XWM drives these operations on its owned XCB connection.

@unsafe import Glibc
@unsafe import NucleusCompositorXcbC

/// ICCCM WM_STATE values (§4.1.3.1).
enum WmStateValue: UInt32 {
    case withdrawn = 0
    case normal = 1
    case iconic = 3
}

/// Every property the XWM caches on an XwaylandSurface. Single source of truth for
/// both the tracked-atom membership check and the batched initial fetch.
let trackedPropertyAtoms: [AtomId] = [
    .WM_NAME, ._NET_WM_NAME, .WM_CLASS, .WM_NORMAL_HINTS, .WM_HINTS,
    .WM_TRANSIENT_FOR, .WM_PROTOCOLS, ._NET_WM_PID, ._NET_STARTUP_ID,
    ._MOTIF_WM_HINTS, ._NET_WM_WINDOW_TYPE, ._NET_WM_STATE,
    ._NET_WM_USER_TIME, ._NET_WM_SYNC_REQUEST_COUNTER,
]

/// X11 properties consumed by the compositor are bounded protocol metadata, not
/// bulk-transfer channels. Request the complete value up to this limit and
/// reject larger values instead of parsing a silent prefix.
private let maximumTrackedPropertyBytes: UInt32 = 64 * 1_024
private let maximumTrackedPropertyWords =
    maximumTrackedPropertyBytes / UInt32(MemoryLayout<UInt32>.size)

@unsafe private func completePropertyReply(
    _ reply: UnsafePointer<xcb_get_property_reply_t>
) -> Bool {
    unsafe reply.pointee.bytes_after == 0
}

/// Subscribe to PropertyNotify on a freshly-created X11 window.
@unsafe func subscribeWindow(_ conn: OpaquePointer, _ window: xcb_window_t) {
    var mask: [UInt32] = [XCB_EVENT_MASK_PROPERTY_CHANGE.rawValue]
    _ = unsafe xcb_change_window_attributes(conn, window, XCB_CW_EVENT_MASK.rawValue, &mask)
}

/// Initial batched property fetch. One GetProperty per tracked atom with a single
/// flush, then replies collected in order.
@unsafe func refreshTracked(_ conn: OpaquePointer, _ atoms: AtomTable, _ surface: XwaylandSurface) {
    var cookies: [xcb_get_property_cookie_t] = []
    cookies.reserveCapacity(trackedPropertyAtoms.count)
    for id in trackedPropertyAtoms {
        unsafe cookies.append(
            xcb_get_property(
                conn, 0, surface.windowID, atoms[id],
                xcb_atom_t(XCB_ATOM_ANY.rawValue), 0,
                maximumTrackedPropertyWords))
    }
    _ = unsafe xcb_flush(conn)
    for (i, id) in trackedPropertyAtoms.enumerated() {
        if let reply = unsafe xcb_get_property_reply(conn, cookies[i], nil) {
            if unsafe completePropertyReply(UnsafePointer(reply)) {
                unsafe readSurfaceProperty(
                    atoms, surface, atoms[id], UnsafePointer(reply))
            }
            unsafe free(reply)
        }
    }
}

/// Refresh a single property from a PropertyNotify.
@unsafe func refreshOne(
    _ conn: OpaquePointer, _ atoms: AtomTable, _ surface: XwaylandSurface, _ atom: xcb_atom_t
) {
    guard atom != 0, isTrackedAtom(atoms, atom) else { return }
    let cookie = unsafe xcb_get_property(
        conn, 0, surface.windowID, atom,
        xcb_atom_t(XCB_ATOM_ANY.rawValue), 0,
        maximumTrackedPropertyWords)
    guard let reply = unsafe xcb_get_property_reply(conn, cookie, nil) else { return }
    defer { unsafe free(reply) }
    guard unsafe completePropertyReply(UnsafePointer(reply)) else { return }
    unsafe readSurfaceProperty(atoms, surface, atom, UnsafePointer(reply))
}

func isTrackedAtom(_ atoms: AtomTable, _ atom: xcb_atom_t) -> Bool {
    for id in trackedPropertyAtoms where atoms[id] == atom { return true }
    return false
}

/// ICCCM WM_STATE writeback. Called on map, unmap/withdraw, or minimize.
@unsafe func setWmState(
    _ conn: OpaquePointer, _ atoms: AtomTable, _ surface: XwaylandSurface, _ state: WmStateValue
) {
    var data: [UInt32] = [state.rawValue, 0 /* XCB_NONE */]
    _ = unsafe xcb_change_property(
        conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), surface.windowID,
        atoms[.WM_STATE], atoms[.WM_STATE], 32, 2, &data)
    _ = unsafe xcb_flush(conn)
}

/// Write an ATOM-list property (format 32, type ATOM). Empty list clears it.
@unsafe func writeAtomListProperty(
    _ conn: OpaquePointer, _ atoms: AtomTable, _ window: xcb_window_t,
    _ property: xcb_atom_t, _ values: [xcb_atom_t]
) {
    values.withUnsafeBytes { raw in
        _ = unsafe xcb_change_property(
            conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), window, property,
            atoms[.ATOM], 32, UInt32(values.count),
            values.isEmpty ? nil : raw.baseAddress)
    }
}
