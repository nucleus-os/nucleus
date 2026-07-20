import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct XdgPositionerTests {
    private func snapshot(
        anchor: WlRect,
        offsetX: Int32 = 0,
        offsetY: Int32 = 0
    ) -> XdgPositionerSnapshot {
        XdgPositionerSnapshot(
            sizeW: 20,
            sizeH: 10,
            anchorRect: anchor,
            anchor: 8,
            gravity: 6,
            constraintAdjustment: 0,
            offsetX: offsetX,
            offsetY: offsetY,
            reactive: false,
            parentWidth: 0,
            parentHeight: 0,
            parentConfigureSerial: nil)
    }

    @Test func anchorMustRemainInsideParentGeometry() {
        #expect(snapshot(
            anchor: WlRect(x: 90, y: 40, width: 10, height: 10)
        ).isValid(parentWidth: 100, parentHeight: 50))
        #expect(!snapshot(
            anchor: WlRect(x: 91, y: 40, width: 10, height: 10)
        ).isValid(parentWidth: 100, parentHeight: 50))
        #expect(!snapshot(
            anchor: WlRect(x: -1, y: 0, width: 1, height: 1)
        ).isValid(parentWidth: 100, parentHeight: 50))
    }

    @Test func childMustIntersectOrTouchParent() {
        #expect(snapshot(
            anchor: WlRect(x: 90, y: 40, width: 10, height: 10),
            offsetX: 0
        ).isValid(parentWidth: 100, parentHeight: 50))
        #expect(!snapshot(
            anchor: WlRect(x: 90, y: 40, width: 10, height: 10),
            offsetX: 21
        ).isValid(parentWidth: 100, parentHeight: 50))
    }
}
