// Parity fixture for the Xwayland property parsers (XwaylandProperties.swift).
// Synthesizes xcb_get_property_reply_t buffers in memory (no X server) and checks
// the parsed XwaylandSurface fields. The byte-level parsers (text, class, cardinal,
// motif, atom-list, protocols) are tested exhaustively; the xcb-icccm-helper
// parsers (size/wm hints, transient) are smoked for defaults-on-empty plus one
// positive WM_NORMAL_HINTS case — upstream icccm is itself tested, so full
// positive parity is left to integration with real X clients.

import Glibc
import NucleusCompositorXcbC

@main
enum XwaylandPropertiesFixture {
    static func fail(_ msg: String) -> Never {
        print("FAIL xwayland-properties: \(msg)")
        exit(1)
    }

    /// Synthesize a property reply: a zeroed xcb_get_property_reply_t header
    /// followed by `value` bytes (xcb_get_property_value returns the bytes right
    /// after the struct). `value_len` is set in element units (format/8).
    static func withReply(type: xcb_atom_t, format: UInt8, value: [UInt8], _ body: (PropReply) -> Void) {
        let stride = MemoryLayout<xcb_get_property_reply_t>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: stride + value.count,
            alignment: MemoryLayout<xcb_get_property_reply_t>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: stride + value.count)
        let reply = raw.bindMemory(to: xcb_get_property_reply_t.self, capacity: 1)
        reply.pointee.response_type = 1
        reply.pointee.format = format
        reply.pointee.type = type
        let unit = format >= 8 ? Int(format) / 8 : 1
        reply.pointee.value_len = UInt32(value.count / unit)
        if !value.isEmpty {
            value.withUnsafeBytes { (raw + stride).copyMemory(from: $0.baseAddress!, byteCount: value.count) }
        }
        body(UnsafePointer(reply))
    }

    static func u32le(_ vals: [UInt32]) -> [UInt8] {
        var b: [UInt8] = []
        for v in vals {
            b.append(UInt8(v & 0xff)); b.append(UInt8((v >> 8) & 0xff))
            b.append(UInt8((v >> 16) & 0xff)); b.append(UInt8((v >> 24) & 0xff))
        }
        return b
    }

    static func main() {
        // ── text / class ──────────────────────────────────────────────────────
        withReply(type: XCB_ATOM_STRING.rawValue, format: 8, value: Array("hello".utf8)) {
            if parseTextProperty($0) != "hello" { fail("text") }
        }
        withReply(type: XCB_ATOM_STRING.rawValue, format: 8, value: []) {
            if parseTextProperty($0) != nil { fail("text empty") }
        }
        withReply(type: XCB_ATOM_STRING.rawValue, format: 8, value: Array("xterm\u{0}XTerm\u{0}".utf8)) {
            let (inst, cls) = parseWmClass($0)
            if inst != "xterm" || cls != "XTerm" { fail("wm_class = (\(inst ?? "nil"), \(cls ?? "nil"))") }
        }

        // ── cardinal ──────────────────────────────────────────────────────────
        withReply(type: XCB_ATOM_CARDINAL.rawValue, format: 32, value: u32le([12345])) {
            if parseCardinal($0) != 12345 { fail("cardinal") }
        }
        withReply(type: XCB_ATOM_CARDINAL.rawValue, format: 8, value: [1]) {
            if parseCardinal($0) != nil { fail("cardinal wrong format") }
        }

        // ── motif decorations ─────────────────────────────────────────────────
        // flags = MWM_HINTS_DECORATIONS(2), decorations field (vals[2]) = 0 → off.
        withReply(type: XCB_ATOM_CARDINAL.rawValue, format: 32, value: u32le([2, 0, 0, 0, 0])) {
            if !parseMotifDecorationsOff($0) { fail("motif off") }
        }
        withReply(type: XCB_ATOM_CARDINAL.rawValue, format: 32, value: u32le([2, 0, 1, 0, 0])) {
            if parseMotifDecorationsOff($0) { fail("motif on") }
        }

        // ── atom list (type gating) ───────────────────────────────────────────
        withReply(type: XCB_ATOM_ATOM.rawValue, format: 32, value: u32le([10, 20, 30])) {
            if parseAtomList($0) != [10, 20, 30] { fail("atom list") }
        }
        withReply(type: XCB_ATOM_NONE.rawValue, format: 0, value: []) {
            if parseAtomList($0) != [] { fail("atom list none → clear") }
        }
        withReply(type: XCB_ATOM_STRING.rawValue, format: 8, value: [1]) {
            if parseAtomList($0) != nil { fail("atom list type mismatch → unchanged") }
        }

        // ── WM_PROTOCOLS classification ───────────────────────────────────────
        var atoms = AtomTable()
        atoms[.WM_DELETE_WINDOW] = 100
        atoms[.WM_TAKE_FOCUS] = 101
        atoms[._NET_WM_PING] = 102
        atoms[._NET_WM_SYNC_REQUEST] = 103
        withReply(type: XCB_ATOM_ATOM.rawValue, format: 32, value: u32le([100, 102])) {
            let p = parseProtocols($0, atoms)
            if p != WmProtocols(deleteWindow: true, takeFocus: false, ping: true, syncRequest: false) {
                fail("protocols \(String(describing: p))")
            }
        }

        // ── readSurfaceProperty dispatch into a surface ───────────────────────
        atoms[.WM_NAME] = 200
        atoms[._NET_WM_NAME] = 201
        atoms[.WM_CLASS] = 202
        atoms[._NET_WM_PID] = 203
        let surface = XwaylandSurface(windowID: 0x42, overrideRedirect: false)
        withReply(type: XCB_ATOM_STRING.rawValue, format: 8, value: Array("Editor".utf8)) {
            readSurfaceProperty(atoms, surface, 201, $0) // _NET_WM_NAME
        }
        withReply(type: XCB_ATOM_CARDINAL.rawValue, format: 32, value: u32le([4242])) {
            readSurfaceProperty(atoms, surface, 203, $0) // _NET_WM_PID
        }
        if surface.title != "Editor" || surface.pid != 4242 {
            fail("dispatch title=\(surface.title ?? "nil") pid=\(String(describing: surface.pid))")
        }

        // ── icccm-helper parsers: default on empty + one positive size-hints ──
        withReply(type: XCB_ATOM_NONE.rawValue, format: 0, value: []) {
            if parseNormalHints($0) != SizeHints() { fail("normal hints empty") }
            if parseWmHints($0) != WmHints() { fail("wm hints empty") }
            if parseTransientFor($0) != nil { fail("transient empty") }
        }
        // WM_NORMAL_HINTS wire layout: 18 longs. flags at [0]; min_w/min_h at [5..6],
        // max_w/max_h at [7..8] (after the 4 obsolete x/y/w/h fields).
        let P_MIN: UInt32 = 1 << 4
        let P_MAX: UInt32 = 1 << 5
        var hints = [UInt32](repeating: 0, count: 18)
        hints[0] = P_MIN | P_MAX
        hints[5] = 100; hints[6] = 200; hints[7] = 300; hints[8] = 400
        withReply(type: XCB_ATOM_WM_SIZE_HINTS.rawValue, format: 32, value: u32le(hints)) {
            let sh = parseNormalHints($0)
            if sh.minWidth != 100 || sh.minHeight != 200 || sh.maxWidth != 300 || sh.maxHeight != 400 {
                fail("size hints \(sh)")
            }
        }

        print("OK xwayland-properties parsers=ok dispatch=ok")
    }
}
