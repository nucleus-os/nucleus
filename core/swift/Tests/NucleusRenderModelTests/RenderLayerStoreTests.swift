@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderLayerStoreTests {
    @Test func renderLayerStore() {
        // appendUniqueLayerID dedups.
        var ids: [UInt64] = []
        appendUniqueLayerID(&ids, 1)
        appendUniqueLayerID(&ids, 2)
        appendUniqueLayerID(&ids, 1)
        #expect(ids == [1, 2], "append-unique-dedups")

        // pushDisplacement: full-extent push in the entry direction, min 1.
        let b = Rect(x: 0, y: 0, w: 100, h: 40)
        #expect(pushDisplacement(.fromLeft, bounds: b) == Point2D(x: -100, y: 0), "push-left")
        #expect(pushDisplacement(.fromRight, bounds: b) == Point2D(x: 100, y: 0), "push-right")
        #expect(pushDisplacement(.fromTop, bounds: b) == Point2D(x: 0, y: -40), "push-top")
        #expect(pushDisplacement(.fromBottom, bounds: b) == Point2D(x: 0, y: 40), "push-bottom")
        // Zero-size bounds clamp the magnitude to 1.
        #expect(pushDisplacement(.fromLeft, bounds: Rect()) == Point2D(x: -1, y: 0), "push-min-magnitude")

        // offsetRect translates, keeps size.
        #expect(offsetRect(b, Point2D(x: 5, y: -3)) == Rect(x: 5, y: -3, w: 100, h: 40), "offset")

        // unionRect bounds both.
        let u = unionRect(Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 20, y: 5, w: 10, h: 10))
        #expect(u == Rect(x: 0, y: 0, w: 30, h: 15), "union")

        // rectHasArea.
        #expect(rectHasArea(Rect(x: 0, y: 0, w: 1, h: 1)) && !rectHasArea(Rect(x: 0, y: 0, w: 0, h: 5)),
              "has-area")

        // intersectRect: overlap → rect, disjoint → nil, edge-touch → nil.
        #expect(intersectRect(Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 5, y: 5, w: 10, h: 10)) ==
              Rect(x: 5, y: 5, w: 5, h: 5), "intersect-overlap")
        #expect(intersectRect(Rect(x: 0, y: 0, w: 5, h: 5), Rect(x: 10, y: 10, w: 5, h: 5)) == nil,
              "intersect-disjoint")
        #expect(intersectRect(Rect(x: 0, y: 0, w: 5, h: 5), Rect(x: 5, y: 0, w: 5, h: 5)) == nil,
              "intersect-edge-touch")

        // unionMaybeRect: ignores empty, accumulates.
        var acc: Rect? = nil
        unionMaybeRect(&acc, Rect(x: 0, y: 0, w: 0, h: 5)) // empty → ignored
        #expect(acc == nil, "union-maybe-ignores-empty")
        unionMaybeRect(&acc, Rect(x: 0, y: 0, w: 10, h: 10))
        unionMaybeRect(&acc, Rect(x: 20, y: 0, w: 10, h: 10))
        #expect(acc == Rect(x: 0, y: 0, w: 30, h: 10), "union-maybe-accumulates")

        // lerpRect: clamped endpoints + midpoint.
        let from = Rect(x: 0, y: 0, w: 0, h: 0)
        let to = Rect(x: 10, y: 20, w: 100, h: 200)
        #expect(lerpRect(from, to, 0) == from, "lerp-0")
        #expect(lerpRect(from, to, 1) == to, "lerp-1")
        #expect(lerpRect(from, to, 0.5) == Rect(x: 5, y: 10, w: 50, h: 100), "lerp-mid")
        #expect(lerpRect(from, to, 2) == to, "lerp-clamps-high")

        // clipExtentRect: none passes, empty rejects, rect intersects.
        let r = Rect(x: 0, y: 0, w: 10, h: 10)
        #expect(clipExtentRect(.none, r) == r, "clip-none-passes")
        #expect(clipExtentRect(.empty, r) == nil, "clip-empty-rejects")
        #expect(clipExtentRect(.rect(Rect(x: 5, y: 0, w: 10, h: 10)), r) == Rect(x: 5, y: 0, w: 5, h: 10),
              "clip-rect-intersects")
        #expect(clipExtentRect(.none, Rect(x: 0, y: 0, w: 0, h: 0)) == nil, "clip-empty-area-nil")

        // accumulateExtentClip propagation.
        #expect(accumulateExtentClip(.empty, localClip: r) == .empty, "accum-empty-absorbing")
        #expect(accumulateExtentClip(.none, localClip: nil) == .none, "accum-none-no-local")
        #expect(accumulateExtentClip(.none, localClip: r) == .rect(r), "accum-none-adopts-local")
        let parent = Rect(x: 0, y: 0, w: 10, h: 10)
        #expect(accumulateExtentClip(.rect(parent), localClip: nil) == .rect(parent),
              "accum-rect-keeps-parent")
        #expect(accumulateExtentClip(.rect(parent), localClip: Rect(x: 5, y: 0, w: 10, h: 10)) ==
              .rect(Rect(x: 5, y: 0, w: 5, h: 10)), "accum-rect-intersects")
        #expect(accumulateExtentClip(.rect(parent), localClip: Rect(x: 100, y: 100, w: 5, h: 5)) == .empty,
              "accum-rect-no-overlap-empty")
    }
}
