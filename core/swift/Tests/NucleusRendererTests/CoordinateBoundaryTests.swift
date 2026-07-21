import NucleusTypes
import Testing
@testable import NucleusRenderer

@Suite
struct CoordinateBoundaryTests {
    @Test func logicalProjectionRejectsNonFiniteGeometryAndSaturatesFiniteOverflow() {
        let transform = GlobalToOutputTransform(
            outputLogicalOriginX: 0,
            outputLogicalOriginY: 0,
            scale: 2)

        #expect(transform.rect(GlobalLogicalRect(
            x: .nan,
            y: 0,
            width: 10,
            height: 10)) == OutputPixelRect())
        #expect(GlobalToOutputTransform(
            outputLogicalOriginX: 0,
            outputLogicalOriginY: 0,
            scale: .infinity).rect(GlobalLogicalRect(
                x: 1,
                y: 2,
                width: 3,
                height: 4)) == OutputPixelRect())

        let saturated = transform.rect(GlobalLogicalRect(
            x: .greatestFiniteMagnitude,
            y: -.greatestFiniteMagnitude,
            width: .greatestFiniteMagnitude,
            height: -1))
        #expect(saturated == OutputPixelRect(
            x: .max,
            y: .min,
            width: .max,
            height: 0))
    }

    @Test func physicalRectEndpointsUseWideArithmetic() {
        let rect = OutputPixelRect(
            x: .max,
            y: .min,
            width: .max,
            height: .max)
        #expect(rect.maxX == Int64(Int32.max) + Int64(UInt32.max))
        #expect(rect.maxY == Int64(Int32.min) + Int64(UInt32.max))
    }

    @Test func damageCoverageAndOverlapRemainTotalAtIntegerExtremes() throws {
        let full = PhysicalRect(
            x: 0,
            y: 0,
            width: .max,
            height: .max)
        #expect(damageBoundsCoverTarget(full, .max, .max))

        let crossing = PhysicalRect(
            x: Int32.max - 1,
            y: Int32.max - 1,
            width: 10,
            height: 10)
        let inner = PhysicalRect(
            x: .max,
            y: .max,
            width: 1,
            height: 1)
        #expect(regionOverlapsRect([inner], crossing))

        let clamped = try #require(clampDamageRectToTarget(
            PhysicalRect(
                x: .max,
                y: .max,
                width: .max,
                height: .max),
            .max,
            .max))
        #expect(clamped.x == .max)
        #expect(clamped.y == .max)
        #expect(clamped.width == UInt32(Int32.max) + 1)
        #expect(clamped.height == UInt32(Int32.max) + 1)
    }
}
