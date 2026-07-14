import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// Converted from DrmAtomicFixture (Phase 10a.3): the Swift atomic property
// discovery + the `hasRequired` validation gates (mirroring
// `kms_atomic_props.zig`) and the AtomicRequestBuilder's typed-entry recording +
// diagnostic dump — all hardware-independent. The fixture's best-effort real
// `drmModeAtomicReq` alloc + test-commit (which asserted nothing) is dropped.
@Suite struct DrmAtomicTests {
    static func e(_ id: UInt32, _ name: String) -> DrmPropertyEntry {
        DrmPropertyEntry(id: id, value: 0, name: name)
    }

    @Test func propertyDiscovery() {
        // Synthetic per-object property tables, named exactly as KMS exposes them.
        let connector = [Self.e(10, "CRTC_ID"), Self.e(11, "Broadcast RGB")]
        let crtc = [Self.e(20, "ACTIVE"), Self.e(21, "MODE_ID"), Self.e(22, "OUT_FENCE_PTR"), Self.e(23, "VRR_ENABLED")]
        let plane = [
            Self.e(30, "FB_ID"), Self.e(31, "CRTC_ID"),
            Self.e(32, "SRC_X"), Self.e(33, "SRC_Y"), Self.e(34, "SRC_W"), Self.e(35, "SRC_H"),
            Self.e(36, "CRTC_X"), Self.e(37, "CRTC_Y"), Self.e(38, "CRTC_W"), Self.e(39, "CRTC_H"),
            Self.e(40, "IN_FENCE_FD"),
        ]

        let props = AtomicPropsDiscovery.discover(connector: connector, crtc: crtc, plane: plane)

        // Discovery routed each name to the right field (and the right object).
        #expect(props.connCrtcId == 10, "discover-conn-crtc-id")
        #expect(props.crtcActive == 20 && props.crtcModeId == 21, "discover-crtc")
        #expect(props.planeFbId == 30 && props.planeCrtcH == 39, "discover-plane")
        // plane CRTC_ID (31) and connector CRTC_ID (10) don't cross over.
        #expect(props.planeCrtcId == 31, "discover-no-object-crossover")
        // Absent property → 0 sentinel.
        #expect(props.crtcCtm == 0 && props.planeColorRange == 0, "discover-absent-zero")

        // Required-set gates: this pipeline has every required prop.
        #expect(props.hasRequired, "has-required-true")
        #expect(props.primaryPlaneProps.hasRequired, "plane-has-required-true")
        // Drop the plane's FB_ID → no longer satisfies the required set.
        var missing = props
        missing.planeFbId = 0
        #expect(!missing.hasRequired, "has-required-false-on-missing-fb")
        // IN_FENCE_FD / COLOR_RANGE are optional — absence doesn't fail the gate.
        var noOptional = props
        noOptional.planeInFenceFd = 0
        noOptional.planeColorRange = 0
        #expect(noOptional.hasRequired, "has-required-true-without-optional")
    }

    @Test func requestBuilder() {
        let connector = [Self.e(10, "CRTC_ID"), Self.e(11, "Broadcast RGB")]
        let crtc = [Self.e(20, "ACTIVE"), Self.e(21, "MODE_ID"), Self.e(22, "OUT_FENCE_PTR"), Self.e(23, "VRR_ENABLED")]
        let plane = [
            Self.e(30, "FB_ID"), Self.e(31, "CRTC_ID"),
            Self.e(32, "SRC_X"), Self.e(33, "SRC_Y"), Self.e(34, "SRC_W"), Self.e(35, "SRC_H"),
            Self.e(36, "CRTC_X"), Self.e(37, "CRTC_Y"), Self.e(38, "CRTC_W"), Self.e(39, "CRTC_H"),
            Self.e(40, "IN_FENCE_FD"),
        ]
        let props = AtomicPropsDiscovery.discover(connector: connector, crtc: crtc, plane: plane)

        // AtomicRequestBuilder: typed-entry recording + labelled diagnostic dump.
        guard var builder = AtomicRequestBuilder() else {
            Issue.record("builder-alloc")
            return
        }
        builder.add(objectId: 1, propertyId: props.crtcActive, value: 1, label: "crtc.ACTIVE")
        builder.add(objectId: 1, propertyId: props.crtcModeId, value: 0xab, label: "crtc.MODE_ID")
        builder.add(objectId: 2, propertyId: props.planeFbId, value: 0xff, label: "plane.FB_ID")
        #expect(builder.count == 3, "builder-records-entries")
        #expect(builder.entries[1] == AtomicRequestBuilder.Entry(
                    objectId: 1, propertyId: props.crtcModeId, value: 0xab, label: "crtc.MODE_ID"),
                "builder-entry-typed")
        let lines = builder.diagnosticLines()
        #expect(lines.count == 3 && lines[2] == "atomic[2]: plane.FB_ID obj=2 prop=30 value=0xff",
                "builder-diagnostic-dump")
    }
}
