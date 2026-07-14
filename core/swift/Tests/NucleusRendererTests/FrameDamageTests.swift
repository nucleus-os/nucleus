import Testing
@testable import NucleusRenderer

@Suite struct FrameDamageTests {
    @Test func stableTextureHandleWithNewContentDamagesItsVisibleFootprint() {
        let rect = PhysicalRect(x: 40, y: 30, width: 320, height: 180)
        let previous = [
            UInt64(7): LayerFrameSnapshot(
                rect: rect, visualSignature: 99,
                structural: false, contentDamaged: false)
        ]
        let plan = FramePlan()
        plan.reset(FrameInfo())
        plan.recordLayerSnapshot(
            7,
            LayerFrameSnapshot(
                rect: rect, visualSignature: 99,
                structural: false, contentDamaged: true))

        let damage = FrameDriver.planFrameDamage(
            plan: plan, previous: previous,
            forceFull: false, width: 1920, height: 1080)

        #expect(damage.rects == [rect])
        #expect(damage.bounds == rect)
        #expect(!damage.full)
    }

    @Test func clearedContentDamageDoesNotRedamageAnUnchangedLayer() {
        let rect = PhysicalRect(x: 40, y: 30, width: 320, height: 180)
        let previous = [
            UInt64(7): LayerFrameSnapshot(
                rect: rect, visualSignature: 99,
                structural: false, contentDamaged: true)
        ]
        let plan = FramePlan()
        plan.reset(FrameInfo())
        plan.recordLayerSnapshot(
            7,
            LayerFrameSnapshot(
                rect: rect, visualSignature: 99,
                structural: false, contentDamaged: false))

        let damage = FrameDriver.planFrameDamage(
            plan: plan, previous: previous,
            forceFull: false, width: 1920, height: 1080)

        #expect(damage.rects.isEmpty)
        #expect(damage.bounds == nil)
        #expect(!damage.full)
    }
}
