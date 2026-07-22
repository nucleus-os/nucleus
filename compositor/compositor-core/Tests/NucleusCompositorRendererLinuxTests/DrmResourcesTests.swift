import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// matching the Zig `mode_introspection.zig` implements (find id / value by name,
// 0/nil on miss) against synthetic property entries — hardware-independent. The
// fixture's best-effort real `drmMode*` owner + property enumeration (which
// asserted nothing on a host with no KMS master) is dropped.
@Suite struct DrmResourcesTests {
    static func entry(_ id: UInt32, _ value: UInt64, _ name: String) -> DrmPropertyEntry {
        DrmPropertyEntry(id: id, value: value, name: name)
    }

    @Test func propertyNameMatching() {
        // A synthetic CRTC property table (id, value, name), as
        // drmModeObjectGetProperties + drmModeGetProperty would project it.
        let entries = [
            Self.entry(31, 1, "ACTIVE"),
            Self.entry(32, 0, "MODE_ID"),
            Self.entry(33, 0xdead, "GAMMA_LUT"),
            Self.entry(34, 2, "VRR_ENABLED"),
        ]

        // find id by name (present) → the matching id.
        #expect(DrmProperties.findId(in: entries, name: "MODE_ID") == 32, "find-id-present")
        // find id by name (absent) → 0 (the Zig "missing" sentinel).
        #expect(DrmProperties.findId(in: entries, name: "CTM") == 0, "find-id-absent-zero")
        // find value by name (present) → the value.
        #expect(DrmProperties.findValue(in: entries, name: "GAMMA_LUT") == 0xdead, "find-value-present")
        // find value by name (absent) → nil (distinct from value 0).
        #expect(DrmProperties.findValue(in: entries, name: "CTM") == nil, "find-value-absent-nil")
        // value 0 is returned as 0, not conflated with absent.
        #expect(DrmProperties.findValue(in: entries, name: "MODE_ID") == 0, "find-value-zero-present")
        // first-match wins on duplicate names (libdrm can list a name twice).
        let dups = [Self.entry(40, 7, "DUP"), Self.entry(41, 9, "DUP")]
        #expect(DrmProperties.findId(in: dups, name: "DUP") == 40, "find-id-first-match")
    }
}
