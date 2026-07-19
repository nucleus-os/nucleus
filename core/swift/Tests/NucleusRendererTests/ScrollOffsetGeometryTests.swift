import Testing
@testable import NucleusRenderer
import NucleusRenderModel

/// The renderer half of the bounds-origin model: a layer's scroll offset shifts
/// its children and nothing else.
///
/// This is the only place scrolling exists in the renderer. A scroll is one
/// property update on one layer, and no descendant re-records its drawing.
@Suite struct ScrollOffsetGeometryTests {
    private func makeLayer(scroll: Point2D = Point2D()) -> Layer {
        var layer = Layer(id: 1, kind: .container)
        layer.model.properties.scrollOffset = scroll
        return layer
    }

    /// A point that maps a translation out of the matrix, so the tests can read
    /// the offset the children will actually be composed with.
    private func mappedOrigin(_ matrix: M44) -> (Float, Float) {
        let r = matrix.mapRect(0, 0, 1, 1)
        return (r.x, r.y)
    }

    @Test func anUnscrolledLayerPassesItsMatrixThrough() {
        let world = M44.translate(30, 40, 0)
        let child = layerContentMatrix(world, makeLayer())
        #expect(mappedOrigin(child) == mappedOrigin(world))
    }

    /// Scrolling down by 40 moves the contents up by 40 — the offset subtracts.
    @Test func scrollingShiftsChildrenOppositeTheOffset() {
        let world = M44.translate(0, 100, 0)
        let child = layerContentMatrix(world, makeLayer(scroll: Point2D(x: 0, y: 40)))
        let (x, y) = mappedOrigin(child)
        #expect(x == 0)
        #expect(y == 60, "100 - 40")
    }

    @Test func bothAxesShift() {
        let world = M44.translate(200, 200, 0)
        let child = layerContentMatrix(world, makeLayer(scroll: Point2D(x: 25, y: 75)))
        let (x, y) = mappedOrigin(child)
        #expect(x == 175)
        #expect(y == 125)
    }

    /// The layer's own content, borders, and shadow compose against the
    /// unscrolled matrix: a scrolling view's frame and chrome stay put while
    /// what it contains moves.
    @Test func theLayersOwnMatrixIsNotTheScrolledOne() {
        let world = M44.translate(0, 100, 0)
        let layer = makeLayer(scroll: Point2D(x: 0, y: 40))
        let child = layerContentMatrix(world, layer)
        #expect(mappedOrigin(child) != mappedOrigin(world),
                "children move")
        #expect(mappedOrigin(world) == (0, 100),
                "and the layer's own matrix is untouched")
    }
}
