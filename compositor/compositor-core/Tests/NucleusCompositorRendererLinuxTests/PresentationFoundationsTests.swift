import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// Converted from PresentationFoundationsFixture (Phase 9.1): the presentation
// foundations — geometry helpers, timing constants, and the fixed-capacity
// per-output rect table (update-in-place, FIFO eviction keeping the newest
// findable, swap-remove). Fully hardware-independent.
//
// `PresentationTiming` is not compiled into the NucleusRenderer module (a name
// collision keeps it out); it is compiled into this test target alongside this
// suite (see PresentationTiming.swift).
@Suite struct PresentationFoundationsTests {
    @Test func geometryHelpers() {
        let pr = PhysicalRect(x: 10, y: 20, width: 100, height: 50)
        #expect(pr.maxX == 110 && pr.maxY == 70, "physical-rect-max")
        #expect(!pr.isEmpty, "physical-rect-nonempty")
        #expect(PhysicalRect(x: 0, y: 0, width: 0, height: 5).isEmpty, "physical-rect-empty")
        let lr = LogicalRect(x: 1.5, y: 2.5, width: 4, height: 8)
        #expect(lr.maxX == 5.5 && lr.maxY == 10.5, "logical-rect-max")
    }

    @Test func timingConstants() {
        #expect(PresentationTimingConstants.tileSpringOmega == 26.0, "timing-omega")
        #expect(PresentationTimingConstants.tileMotionSettleEps == 0.75, "timing-settle-eps")
        #expect(PresentationTimingConstants.tileMotionMaxS == 0.6, "timing-max-s")
        #expect(PresentationTimingConstants.tileSettleEps == 1.0, "timing-settle")
        #expect(PresentationTimingConstants.tileSettleGraceS == 0.5, "timing-grace")
        #expect(PresentationTimingConstants.lifecycleOpenDurationS == 0.18, "timing-open")
        #expect(PresentationTimingConstants.lifecycleCloseDurationS == 0.16, "timing-close")
        #expect(PresentationTimingConstants.tileContentCrossfadeEnabled, "timing-crossfade")
    }

    @Test func syncobjDefaultDeadlineIsNotAlreadyExpired() {
        #expect(DrmSyncobj.nonExpiringDeadlineNs == Int64.max)
        #expect(DrmSyncobj.nonExpiringDeadlineNs > 0)
    }

    @Test func perOutputUpdateInPlace() {
        var per = PerOutputRenderRects<UInt64, PhysicalRect>()
        let r0 = PhysicalRect(x: 0, y: 0, width: 10, height: 10)
        let r1 = PhysicalRect(x: 1, y: 1, width: 20, height: 20)
        per.put(7, r0)
        per.put(7, r1)
        #expect(per.count == 1, "per-update-count")
        #expect(per.get(7) == r1, "per-update-value")
    }

    @Test func perOutputFifoEviction() {
        var per = PerOutputRenderRects<UInt64, PhysicalRect>()
        let r = PhysicalRect(x: 0, y: 0, width: 1, height: 1)
        for i in 0..<UInt64(maxTrackedPresentedOutputs) { per.put(i, r) }
        #expect(per.count == maxTrackedPresentedOutputs, "per-full-count")
        let overflow: UInt64 = 9999
        per.put(overflow, r)
        #expect(per.count == maxTrackedPresentedOutputs, "per-overflow-count")
        #expect(per.get(overflow) != nil, "per-overflow-findable")
        #expect(per.get(0) == nil, "per-evicts-oldest")
        #expect(per.get(UInt64(maxTrackedPresentedOutputs - 1)) != nil, "per-keeps-recent")
    }

    @Test func perOutputRemove() {
        var per = PerOutputRenderRects<UInt64, PhysicalRect>()
        let r = PhysicalRect(x: 0, y: 0, width: 1, height: 1)
        per.put(3, r)
        per.put(4, r)
        per.remove(3)
        #expect(per.get(3) == nil, "per-remove-gone")
        #expect(per.get(4) != nil, "per-remove-keeps-other")
        #expect(per.count == 1, "per-remove-count")
    }
}
