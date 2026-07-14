import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// Converted from LayerGeometryFixture (Phase 9.4): the presentation geometry
// port — M44 mapping/concatenation, the local-composition matrix + clip rescale,
// rounded-clip accumulation down the tree, and logical→target-physical
// projection. Fully hardware-independent.
@Suite struct LayerGeometryTests {
    static func approx(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) <= eps }
    static func approxD(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

    @Test func m44Mapping() {
        let p = M44.identity.mapPoint(3, 4)
        #expect(Self.approx(p.x, 3) && Self.approx(p.y, 4), "m44-identity-map")
        let t = M44.translate(10, 20, 0).mapPoint(3, 4)
        #expect(Self.approx(t.x, 13) && Self.approx(t.y, 24), "m44-translate-map")
        let s = M44.scale(2, 3, 1).mapPoint(5, 7)
        #expect(Self.approx(s.x, 10) && Self.approx(s.y, 21), "m44-scale-map")
        // concat: apply scale first then translate.
        let m = M44.translate(10, 0, 0).concat(M44.scale(2, 1, 1))
        #expect(Self.approx(m.mapPoint(5, 0).x, 20), "m44-concat-map")
        #expect(M44.identity.is2DAffine && M44.translate(1, 2, 0).is2DAffine, "m44-is2daffine")
        // mapRect of a translate.
        let r = M44.translate(5, 6, 0).mapRect(0, 0, 10, 20)
        #expect(Self.approx(r.x, 5) && Self.approx(r.y, 6) && Self.approx(r.w, 10) && Self.approx(r.h, 20), "m44-maprect")
        // from3x3 identity behaves as identity.
        let id3 = M44.from3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(Self.approx(id3.mapPoint(7, 8).x, 7) && Self.approx(id3.mapPoint(7, 8).y, 8), "m44-from3x3")
    }

    @Test func localCompositionMatrix() {
        // anchor cancels for identity transform.
        let m = ComposeHelpers.localCompositionMatrix(
            position: Point2D(x: 10, y: 20), anchorPoint: Point2D(x: 0.5, y: 0.5),
            transform: M44.identity, presentationTransform: nil, width: 100, height: 50)
        #expect(Self.approx(m.mapPoint(0, 0).x, 10) && Self.approx(m.mapPoint(0, 0).y, 20), "compose-anchor-cancels")
        // scaling about the center keeps the center fixed (relative to pivot).
        let s = ComposeHelpers.localCompositionMatrix(
            position: Point2D(x: 0, y: 0), anchorPoint: Point2D(x: 0.5, y: 0.5),
            transform: M44.scale(2, 2, 1), presentationTransform: nil, width: 100, height: 50)
        #expect(Self.approx(s.mapPoint(50, 25).x, 50) && Self.approx(s.mapPoint(50, 25).y, 25), "compose-scale-center-fixed")
    }

    @Test func scaledClipForBounds() {
        // doubles rect + radii on a 2× bounds growth.
        let clip = ClipOp(rect: (0, 0, 100, 50), radii: (8, 8, 8, 8), antiAlias: true,
                          transform: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let scaled = ComposeHelpers.scaledClipForBounds(
            clip: clip, modelBounds: Bounds(w: 100, h: 50), effectiveBounds: Bounds(w: 200, h: 100))!
        #expect(float4Equal(scaled.rect, (0, 0, 200, 100)), "clip-scale-rect")
        #expect(float4Equal(scaled.radii, (16, 16, 16, 16)), "clip-scale-radii")
    }

    @Test func layerClipRectMapping() {
        // layerClipRect maps a layer's own clip into world space.
        var layer = Layer(id: 1, kind: .container)
        layer.model.properties.bounds = Bounds(w: 100, h: 50)
        layer.model.properties.clip = ClipOp(rect: (10, 10, 30, 20), radii: (4, 4, 4, 4),
                                             antiAlias: true, transform: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let rc = layerClipRect(layer, M44.identity)!
        #expect(Self.approxD(rc.rect.x, 10) && Self.approxD(rc.rect.y, 10) &&
                Self.approxD(rc.rect.width, 30) && Self.approxD(rc.rect.height, 20), "layer-clip-rect")
        #expect(float4Equal(rc.radii, (4, 4, 4, 4)), "layer-clip-radii")
    }

    @Test func accumulateClipDownTree() {
        // accumulateClip folds parent ∩ child; clipLayerRect trims to it.
        let parent = ClipState.rect(RoundedClip(rect: LogicalRect(x: 0, y: 0, width: 100, height: 100)))
        var layer = Layer(id: 2, kind: .container)
        layer.model.properties.bounds = Bounds(w: 100, h: 100)
        layer.model.properties.clip = ClipOp(rect: (50, 50, 100, 100), radii: (0, 0, 0, 0),
                                             antiAlias: false, transform: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let acc = accumulateClip(parent, layer, M44.identity)
        let r = clipRect(acc)!
        #expect(Self.approxD(r.x, 50) && Self.approxD(r.y, 50) && Self.approxD(r.width, 50) && Self.approxD(r.height, 50), "accumulate-clip")
        let trimmed = clipLayerRect(acc, LogicalRect(x: 0, y: 0, width: 200, height: 200))!
        #expect(Self.approxD(trimmed.width, 50) && Self.approxD(trimmed.height, 50), "clip-layer-rect")
        // a disjoint child clip empties the state.
        var disjoint = Layer(id: 3, kind: .container)
        disjoint.model.properties.bounds = Bounds(w: 100, h: 100)
        disjoint.model.properties.clip = ClipOp(rect: (500, 500, 50, 50), radii: (0, 0, 0, 0),
                                                antiAlias: false, transform: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        if case .empty = accumulateClip(parent, disjoint, M44.identity) { #expect(true, "accumulate-empty") }
        else { #expect(Bool(false), "accumulate-empty") }
    }

    @Test func intersectionHelpers() {
        let a = LogicalRect(x: 0, y: 0, width: 100, height: 100)
        let b = LogicalRect(x: 50, y: 50, width: 100, height: 100)
        #expect(intersectLogicalRects(a, b) == LogicalRect(x: 50, y: 50, width: 50, height: 50), "intersect")
        #expect(Self.approxD(rectIntersectionArea(a, b), 2500), "intersect-area")
        #expect(intersectLogicalRects(a, LogicalRect(x: 200, y: 200, width: 10, height: 10)) == nil, "intersect-disjoint")
    }

    @Test func logicalToTargetPhysicalProjection() {
        let target = RenderTarget(
            outputId: 1, logicalRect: LogicalRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: PixelSize(width: 200, height: 200), scale: 1, fractionalScale: 2,
            overlayUsableArea: UsableArea(x: 0, y: 0, w: 100, h: 100))
        #expect(Self.approxD(logicalToTargetPhysicalX(target, 10), 20), "logical-to-physical-x")
        #expect(Self.approxD(logicalToTargetPhysicalY(target, 15), 30), "logical-to-physical-y")
        let pr = physicalDamageRectFromLogicalRect(
            target, LogicalRect(x: 10, y: 20, width: 30, height: 40))
        #expect(pr == PhysicalRect(x: 20, y: 40, width: 60, height: 80), "logical-rect-to-physical")
        #expect(logicalRectIntersectsTarget(target, 50, 50, 10, 10), "rect-intersects-target")
        #expect(!logicalRectIntersectsTarget(target, 500, 500, 10, 10), "rect-misses-target")
    }
}
