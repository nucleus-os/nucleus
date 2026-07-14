// Parity fixture for the Swift atom table (XwaylandAtoms.swift). Tests the enum
// set + names + the forward/reverse table logic — none of which needs a live X
// server (interning round-trips are exercised at integration). Pins the ported
// atom set against the Zig source-of-truth count and the load-bearing names.

import Glibc
import NucleusCompositorXcbC

@main
enum XwaylandAtomsFixture {
    // The exact atom count at the time of the Zig-to-Swift port.
    // Drift (an atom added/removed on one side) must be a deliberate, matched edit.
    static let expectedCount = 77

    static func fail(_ msg: String) -> Never {
        print("FAIL xwayland-atoms: \(msg)")
        exit(1)
    }

    static func main() {
        let names = AtomId.allCases.map { $0.rawValue }

        if names.count != expectedCount {
            fail("count=\(names.count) expected=\(expectedCount)")
        }

        // The implicit String raw value is the verbatim wire name (incl. leading _).
        if AtomId._NET_WM_STATE.wireName != "_NET_WM_STATE"
            || AtomId.WL_SURFACE_SERIAL.rawValue != "WL_SURFACE_SERIAL"
        {
            fail("wire name mismatch")
        }

        // No duplicate atom names.
        if Set(names).count != names.count {
            fail("duplicate atom names")
        }

        // Load-bearing atoms must be present (pairing, ICCCM, EWMH, Motif, XSETTINGS).
        let critical = [
            "WL_SURFACE_SERIAL", "WM_PROTOCOLS", "WM_DELETE_WINDOW", "WM_STATE",
            "_NET_WM_STATE", "_NET_WM_WINDOW_TYPE", "_NET_ACTIVE_WINDOW",
            "_NET_SUPPORTING_WM_CHECK", "_MOTIF_WM_HINTS", "_XSETTINGS_SETTINGS",
            "_XWAYLAND_ALLOW_COMMITS",
        ]
        for name in critical where !names.contains(name) {
            fail("missing atom \(name)")
        }

        // Forward set + reverse classification round-trip (synthetic atom ids).
        var table = AtomTable()
        table[._NET_WM_STATE] = 42
        table[.WM_PROTOCOLS] = 7
        if table[._NET_WM_STATE] != 42 || table[.WM_PROTOCOLS] != 7 {
            fail("forward lookup")
        }
        if table.id(of: 42) != ._NET_WM_STATE || table.id(of: 7) != .WM_PROTOCOLS {
            fail("reverse lookup")
        }
        // Unset reads 0; 0 and unknown atoms classify as nil.
        if table[._NET_WM_PID] != 0 || table.id(of: 0) != nil || table.id(of: 999) != nil {
            fail("default/unknown handling")
        }

        print("OK xwayland-atoms count=\(names.count) reverse=ok")
    }
}
