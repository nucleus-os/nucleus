import Testing
@testable import NucleusRenderModel

@Suite("Region algebra")
struct RegionTests {
    @Test("union coalesces adjacent coverage")
    func unionCoalesces() {
        var region = Region(RegionRect(x: 0, y: 0, width: 10, height: 10))
        region.formUnion(RegionRect(x: 10, y: 0, width: 10, height: 10))

        #expect(region.rectangles == [RegionRect(x: 0, y: 0, width: 20, height: 10)])
    }

    @Test("subtract produces exact disjoint coverage")
    func subtractIsExact() {
        var region = Region(RegionRect(x: 0, y: 0, width: 20, height: 20))
        region.subtract(RegionRect(x: 5, y: 5, width: 10, height: 10))

        #expect(region.contains(x: 2, y: 2))
        #expect(!region.contains(x: 10, y: 10))
        #expect(region.contains(x: 18, y: 18))
        #expect(region.rectangleCount == 4)
    }

    @Test("later union fills subtracted coverage")
    func unionFillsHole() {
        var region = Region(RegionRect(x: 0, y: 0, width: 20, height: 20))
        let hole = RegionRect(x: 5, y: 5, width: 10, height: 10)
        region.subtract(hole)
        region.formUnion(hole)

        #expect(region.rectangles == [RegionRect(x: 0, y: 0, width: 20, height: 20)])
        #expect(region.contains(RegionRect(x: 0, y: 0, width: 20, height: 20)))
    }

    @Test("intersection clips coverage")
    func intersectionClips() {
        let lhs = Region(RegionRect(x: -10, y: -10, width: 20, height: 20))
        let rhs = Region(RegionRect(x: 0, y: 0, width: 20, height: 20))

        #expect(lhs.intersection(rhs).rectangles == [RegionRect(x: 0, y: 0, width: 10, height: 10)])
    }

    @Test("damage complexity fallback remains conservative")
    func conservativeFallback() {
        let region = Region(rectangles: [
            RegionRect(x: 0, y: 0, width: 2, height: 2),
            RegionRect(x: 10, y: 10, width: 2, height: 2),
        ])
        let simplified = region.conservative(maxRectangles: 1)

        #expect(simplified.rectangles == [RegionRect(x: 0, y: 0, width: 12, height: 12)])
    }
}
