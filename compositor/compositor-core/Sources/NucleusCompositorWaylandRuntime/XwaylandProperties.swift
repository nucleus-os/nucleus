// Xwayland ICCCM/EWMH property reply parsing.
//
// Parses an `xcb_get_property_reply_t` buffer into XwaylandSurface fields. These
// are decoupled from the window-model bitmasks: they populate the surface's raw
// fields (strings, hint structs, raw atom lists). The atom↔NetState/WindowType
// classification (which maps those raw atom lists to the model) is the separate,
// model-coupled half ported alongside the XWM.
//
// XwaylandPropertyIO owns the connection-bound subscribe/refresh/writeback
// mechanics; this file is the pure reply→state parsing.

import NucleusCompositorXcbC

typealias PropReply = UnsafePointer<xcb_get_property_reply_t>

/// Copy a STRING / UTF8_STRING / COMPOUND_TEXT property (format 8) into a String,
/// or nil if empty / not an 8-bit property.
func parseTextProperty(_ reply: PropReply) -> String? {
    guard reply.pointee.format == 8, reply.pointee.value_len > 0,
          let raw = xcb_get_property_value(reply) else { return nil }
    let bytes = UnsafeRawBufferPointer(start: raw, count: Int(reply.pointee.value_len))
    return String(decoding: bytes, as: UTF8.self)
}

/// WM_CLASS: two NUL-terminated strings back-to-back, `instance\0class\0`
/// (ICCCM §4.1.2.5).
func parseWmClass(_ reply: PropReply) -> (instance: String?, className: String?) {
    guard reply.pointee.format == 8, reply.pointee.value_len > 0,
          let raw = xcb_get_property_value(reply) else { return (nil, nil) }
    let b = Array(UnsafeRawBufferPointer(start: raw, count: Int(reply.pointee.value_len)))

    let split = b.firstIndex(of: 0) ?? b.count
    let instance = split > 0 ? String(decoding: b[0..<split], as: UTF8.self) : nil

    let classStart = split < b.count ? split + 1 : b.count
    var classEnd = b.count
    if classStart < b.count, let nul = b[classStart...].firstIndex(of: 0) {
        classEnd = nul
    }
    let className = classEnd > classStart ? String(decoding: b[classStart..<classEnd], as: UTF8.self) : nil
    return (instance, className)
}

/// A single CARDINAL (u32) — _NET_WM_PID, _NET_WM_USER_TIME,
/// _NET_WM_SYNC_REQUEST_COUNTER. Nil if not a non-empty 32-bit property.
func parseCardinal(_ reply: PropReply) -> UInt32? {
    guard reply.pointee.format == 32, reply.pointee.value_len > 0,
          let raw = xcb_get_property_value(reply) else { return nil }
    return raw.loadUnaligned(as: UInt32.self)
}

/// _MOTIF_WM_HINTS: flags bit 1 (DECORATIONS present) with a 0 decorations field
/// (vals[2]) means the client wants no decorations.
func parseMotifDecorationsOff(_ reply: PropReply) -> Bool {
    guard reply.pointee.format == 32, reply.pointee.value_len >= 5,
          let raw = xcb_get_property_value(reply) else { return false }
    let flags = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
    let decorations = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self) // vals[2]
    let MWM_HINTS_DECORATIONS: UInt32 = 1 << 1
    return (flags & MWM_HINTS_DECORATIONS) != 0 && decorations == 0
}

/// An ATOM list (_NET_WM_WINDOW_TYPE, _NET_WM_STATE). Returns nil to mean "leave
/// the existing value unchanged" (type mismatch / wrong format), [] to clear, or
/// the parsed atoms.
func parseAtomList(_ reply: PropReply) -> [xcb_atom_t]? {
    let type = reply.pointee.type
    guard type == XCB_ATOM_ATOM.rawValue || type == XCB_ATOM_NONE.rawValue else { return nil }
    if type == XCB_ATOM_ATOM.rawValue && reply.pointee.format != 32 { return nil }
    if type == XCB_ATOM_NONE.rawValue || reply.pointee.value_len == 0 { return [] }
    guard let raw = xcb_get_property_value(reply) else { return [] }
    let count = Int(reply.pointee.value_len)
    var out = [xcb_atom_t](repeating: 0, count: count)
    for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: xcb_atom_t.self) }
    return out
}

/// WM_PROTOCOLS: an ATOM list mapped to the bits the compositor honors. Returns
/// nil to leave the existing value unchanged (type/format mismatch).
func parseProtocols(_ reply: PropReply, _ atoms: AtomTable) -> WmProtocols? {
    let type = reply.pointee.type
    guard type == XCB_ATOM_ATOM.rawValue || type == XCB_ATOM_NONE.rawValue else { return nil }
    if type == XCB_ATOM_ATOM.rawValue && reply.pointee.format != 32 { return nil }

    var p = WmProtocols()
    if type != XCB_ATOM_NONE.rawValue, reply.pointee.value_len > 0, let raw = xcb_get_property_value(reply) {
        let count = Int(reply.pointee.value_len)
        for i in 0..<count {
            let a = raw.loadUnaligned(fromByteOffset: i * 4, as: xcb_atom_t.self)
            if a == atoms[.WM_DELETE_WINDOW] { p.deleteWindow = true }
            else if a == atoms[.WM_TAKE_FOCUS] { p.takeFocus = true }
            else if a == atoms[._NET_WM_PING] { p.ping = true }
            else if a == atoms[._NET_WM_SYNC_REQUEST] { p.syncRequest = true }
        }
    }
    return p
}

/// WM_NORMAL_HINTS (ICCCM §4.1.2.3), via the xcb-icccm helper.
func parseNormalHints(_ reply: PropReply) -> SizeHints {
    var dest = SizeHints()
    var hints = xcb_size_hints_t()
    guard xcb_icccm_get_wm_size_hints_from_reply(&hints, UnsafeMutablePointer(mutating: reply)) != 0 else { return dest }

    func u16(_ v: Int32) -> UInt16 { UInt16(max(0, v)) }
    if hints.flags & XCB_ICCCM_SIZE_HINT_P_MIN_SIZE.rawValue != 0 {
        dest.minWidth = u16(hints.min_width); dest.minHeight = u16(hints.min_height)
    }
    if hints.flags & XCB_ICCCM_SIZE_HINT_P_MAX_SIZE.rawValue != 0 {
        dest.maxWidth = u16(hints.max_width); dest.maxHeight = u16(hints.max_height)
    }
    if hints.flags & XCB_ICCCM_SIZE_HINT_BASE_SIZE.rawValue != 0 {
        dest.baseWidth = u16(hints.base_width); dest.baseHeight = u16(hints.base_height)
    }
    if hints.flags & XCB_ICCCM_SIZE_HINT_P_RESIZE_INC.rawValue != 0 {
        dest.incWidth = u16(hints.width_inc); dest.incHeight = u16(hints.height_inc)
    }
    return dest
}

/// WM_HINTS (ICCCM §4.1.2.4) — we surface only `input` and `urgent`.
func parseWmHints(_ reply: PropReply) -> WmHints {
    var dest = WmHints()
    var hints = xcb_icccm_wm_hints_t()
    guard xcb_icccm_get_wm_hints_from_reply(&hints, UnsafeMutablePointer(mutating: reply)) != 0 else { return dest }

    // xcb_icccm_wm_hints_t.flags is int32_t (unlike size hints' uint32_t).
    let flags = UInt32(bitPattern: hints.flags)
    if flags & XCB_ICCCM_WM_HINT_INPUT.rawValue != 0 { dest.input = hints.input != 0 }
    if flags & XCB_ICCCM_WM_HINT_X_URGENCY.rawValue != 0 { dest.urgent = true }
    return dest
}

/// WM_TRANSIENT_FOR — a single parent WINDOW id, or nil.
func parseTransientFor(_ reply: PropReply) -> xcb_window_t? {
    var parent = xcb_window_t(0)
    // The icccm transient helper takes a non-const reply (it does not mutate it).
    if xcb_icccm_get_wm_transient_for_from_reply(&parent, UnsafeMutablePointer(mutating: reply)) != 0 && parent != 0 {
        return parent
    }
    return nil
}

/// Dispatch a (non-nil) property reply for `atom` into `surface`.
func readSurfaceProperty(_ atoms: AtomTable, _ surface: XwaylandSurface, _ atom: xcb_atom_t, _ reply: PropReply) {
    if atom == atoms[._NET_WM_NAME] || atom == atoms[.WM_NAME] {
        // _NET_WM_NAME (UTF-8) wins; WM_NAME only fills in if no title yet.
        let isNet = atom == atoms[._NET_WM_NAME]
        if isNet || surface.title == nil { surface.title = parseTextProperty(reply) }
    } else if atom == atoms[.WM_CLASS] {
        let (inst, cls) = parseWmClass(reply)
        surface.instance = inst
        surface.className = cls
    } else if atom == atoms[.WM_NORMAL_HINTS] {
        surface.sizeHints = parseNormalHints(reply)
    } else if atom == atoms[.WM_HINTS] {
        surface.hints = parseWmHints(reply)
    } else if atom == atoms[.WM_TRANSIENT_FOR] {
        surface.transientFor = parseTransientFor(reply)
    } else if atom == atoms[.WM_PROTOCOLS] {
        if let p = parseProtocols(reply, atoms) { surface.protocols = p }
    } else if atom == atoms[._NET_WM_PID] {
        surface.pid = parseCardinal(reply)
    } else if atom == atoms[._NET_STARTUP_ID] {
        surface.startupID = parseTextProperty(reply)
    } else if atom == atoms[._MOTIF_WM_HINTS] {
        surface.decorationsOff = parseMotifDecorationsOff(reply)
    } else if atom == atoms[._NET_WM_WINDOW_TYPE] {
        if let list = parseAtomList(reply) { surface.windowTypes = list }
    } else if atom == atoms[._NET_WM_STATE] {
        if let list = parseAtomList(reply) { surface.states = list }
    } else if atom == atoms[._NET_WM_USER_TIME] {
        if let t = parseCardinal(reply) { surface.userTime = t }
    } else if atom == atoms[._NET_WM_SYNC_REQUEST_COUNTER] {
        surface.syncCounter = parseCardinal(reply) ?? 0
    }
}
