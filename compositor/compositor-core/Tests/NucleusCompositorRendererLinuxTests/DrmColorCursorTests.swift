import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// + interleave + atomic-state population, and the cursor-plane placement math +
// pixel packing, against the behavior of the Zig GammaState / cursor.zig. The
// pure logic is hardware-independent; the fixture's best-effort real gamma blob
// create + cursor-prop discovery on a KMS node (which asserted nothing) is
// dropped.
@Suite struct DrmColorCursorTests {
    @Test func gammaStateMachine() {
        var g = GammaState()
        // Ramp of size 2: R=[1,2] G=[3,4] B=[5,6] → concatenated.
        g.stage(table: [1, 2, 3, 4, 5, 6], rampSize: 2)
        #expect(g.desiredRampSize == 2 && g.desiredTable?.count == 6, "gamma-stage")
        // Interleave: entry i = (R[i], G[i], B[i]).
        let lut = g.buildColorLut()
        #expect(lut?.count == 2 &&
                lut?[0] == DrmColorLut(red: 1, green: 3, blue: 5) &&
                lut?[1] == DrmColorLut(red: 2, green: 4, blue: 6), "gamma-interleave")

        // Snapshot / restore round-trips the staged state.
        let snap = g.snapshot()
        g.stage(table: nil, rampSize: 0)
        #expect(g.desiredTable == nil && g.buildColorLut() == nil, "gamma-clear")
        g.restorePrevious(snap)
        #expect(g.desiredRampSize == 2, "gamma-restore")

        // Session-resume staleness: cleared when no client, kept when alive.
        var g2 = g
        g2.clearOnSessionResumeIfStale(clientAlive: true)
        #expect(g2.desiredRampSize == 2, "gamma-resume-keeps-live")
        g2.clearOnSessionResumeIfStale(clientAlive: false)
        #expect(g2.desiredTable == nil && g2.desiredRampSize == 0, "gamma-resume-clears-stale")
    }

    @Test func colorPipelineAtomicState() {
        var g = GammaState()
        // Color-pipeline atomic-state population (optional props skipped at id 0).
        var builder = AtomicRequestBuilder()!
        let props = AtomicProps(
            connBroadcastRgb: 50, crtcGammaLut: 51, crtcDegammaLut: 0, crtcCtm: 52,
            planeColorRange: 53)
        g.stage(table: [1, 2, 3, 4, 5, 6], rampSize: 2)
        g.addToAtomicState(into: &builder, connectorId: 1, planeId: 2, crtcId: 3,
                           props: props, includePlaneState: true)
        // Broadcast RGB + COLOR_RANGE + GAMMA_LUT + CTM = 4 (DEGAMMA_LUT id 0 skipped).
        #expect(builder.count == 4, "gamma-atomic-skips-zero-prop")
        #expect(builder.entries.contains { $0.label == "plane.COLOR_RANGE" && $0.propertyId == 53 },
                "gamma-atomic-plane-state")
        // Without plane state, COLOR_RANGE is omitted.
        var builder2 = AtomicRequestBuilder()!
        g.addToAtomicState(into: &builder2, connectorId: 1, planeId: 2, crtcId: 3,
                           props: props, includePlaneState: false)
        #expect(builder2.count == 3 && !builder2.entries.contains { $0.label == "plane.COLOR_RANGE" },
                "gamma-atomic-no-plane-state")
    }

    @Test func cursorPlacement() {
        let rect = OutputRect(x: 0, y: 0, width: 1920, height: 1080)
        // In-bounds, scale 1, hotspot (4,4): crtc = cursor - hotspot.
        if let p = cursorPlanePlacement(rect: rect, fractionalScale: 1.0,
                                        cursorX: 100, cursorY: 200, hotspotX: 4, hotspotY: 4,
                                        width: 64, height: 64) {
            #expect(p.crtcX == 96 && p.crtcY == 196, "cursor-position")
            #expect(p.srcW == UInt64(64) << 16 && p.srcH == UInt64(64) << 16, "cursor-src-fixed-point")
            #expect(p.crtcW == 64 && p.crtcH == 64, "cursor-crtc-size")
        } else { Issue.record("cursor-position") }

        // Fractional scale 2.0 scales the device-pixel position.
        if let p = cursorPlanePlacement(rect: rect, fractionalScale: 2.0,
                                        cursorX: 100, cursorY: 50, hotspotX: 0, hotspotY: 0,
                                        width: 64, height: 64) {
            #expect(p.crtcX == 200 && p.crtcY == 100, "cursor-scale")
        } else { Issue.record("cursor-scale") }

        // Offset output rect: position is relative to the rect origin.
        let offset = OutputRect(x: 1920, y: 0, width: 1920, height: 1080)
        if let p = cursorPlanePlacement(rect: offset, fractionalScale: 1.0,
                                        cursorX: 2020, cursorY: 10, hotspotX: 0, hotspotY: 0,
                                        width: 64, height: 64) {
            #expect(p.crtcX == 100, "cursor-rect-relative")
        } else { Issue.record("cursor-rect-relative") }

        // Out of bounds → nil.
        #expect(cursorPlanePlacement(rect: rect, fractionalScale: 1.0,
                                     cursorX: 5000, cursorY: 10, hotspotX: 0, hotspotY: 0,
                                     width: 64, height: 64) == nil, "cursor-out-of-bounds")
        #expect(cursorPlanePlacement(rect: rect, fractionalScale: 1.0,
                                     cursorX: 10, cursorY: -5, hotspotX: 0, hotspotY: 0,
                                     width: 64, height: 64) == nil, "cursor-negative-oob")
    }

    @Test func cursorPixelPacking() {
        // 2x2 ARGB source into a 4-wide (stride 16) 2-tall dest: rows copied,
        // remainder zero.
        let src: [UInt8] = [
            1, 2, 3, 4,   5, 6, 7, 8,        // row 0: 2 px
            9, 10, 11, 12,  13, 14, 15, 16,  // row 1: 2 px
        ]
        let packed = packCursorPixels(source: src, sourceWidth: 2, sourceHeight: 2,
                                      destinationStride: 16, destinationWidth: 4, destinationHeight: 2)
        #expect(packed.count == 32, "pack-size")
        #expect(Array(packed[0..<8]) == [1, 2, 3, 4, 5, 6, 7, 8], "pack-row0")
        #expect(Array(packed[8..<16]) == [0, 0, 0, 0, 0, 0, 0, 0], "pack-row0-remainder-zero")
        #expect(Array(packed[16..<24]) == [9, 10, 11, 12, 13, 14, 15, 16], "pack-row1")
        // Larger source than dest clamps to dest dimensions.
        let big = [UInt8](repeating: 0xAB, count: 4 * 4 * 4)  // 4x4 px
        let clamped = packCursorPixels(source: big, sourceWidth: 4, sourceHeight: 4,
                                       destinationStride: 8, destinationWidth: 2, destinationHeight: 2)
        #expect(clamped.count == 16 && clamped.allSatisfy { $0 == 0xAB }, "pack-clamp-larger-source")
    }
}
