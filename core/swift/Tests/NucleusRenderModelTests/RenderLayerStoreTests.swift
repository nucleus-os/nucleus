import Testing

@testable import NucleusRenderModel

@MainActor
@Suite struct RenderLayerStoreTests {
    @Test func renderLayerStore() {
        // appendUniqueLayerID dedups.
        var ids: [UInt64] = []
        appendUniqueLayerID(&ids, 1)
        appendUniqueLayerID(&ids, 2)
        appendUniqueLayerID(&ids, 1)
        #expect(ids == [1, 2], "append-unique-dedups")

        let b = RenderRect(x: 0, y: 0, w: 100, h: 40)

        // offsetRect translates, keeps size.
        #expect(
            offsetRect(b, Point2D(x: 5, y: -3)) == RenderRect(x: 5, y: -3, w: 100, h: 40), "offset")

        // unionRect bounds both.
        let u = unionRect(
            RenderRect(x: 0, y: 0, w: 10, h: 10), RenderRect(x: 20, y: 5, w: 10, h: 10))
        #expect(u == RenderRect(x: 0, y: 0, w: 30, h: 15), "union")

        // rectHasArea.
        #expect(
            rectHasArea(RenderRect(x: 0, y: 0, w: 1, h: 1))
                && !rectHasArea(RenderRect(x: 0, y: 0, w: 0, h: 5)),
            "has-area")

        // intersectRect: overlap → rect, disjoint → nil, edge-touch → nil.
        #expect(
            intersectRect(
                RenderRect(x: 0, y: 0, w: 10, h: 10), RenderRect(x: 5, y: 5, w: 10, h: 10))
                == RenderRect(x: 5, y: 5, w: 5, h: 5), "intersect-overlap")
        #expect(
            intersectRect(RenderRect(x: 0, y: 0, w: 5, h: 5), RenderRect(x: 10, y: 10, w: 5, h: 5))
                == nil,
            "intersect-disjoint")
        #expect(
            intersectRect(RenderRect(x: 0, y: 0, w: 5, h: 5), RenderRect(x: 5, y: 0, w: 5, h: 5))
                == nil,
            "intersect-edge-touch")

        // unionMaybeRect: ignores empty, accumulates.
        var acc: RenderRect? = nil
        unionMaybeRect(&acc, RenderRect(x: 0, y: 0, w: 0, h: 5))  // empty → ignored
        #expect(acc == nil, "union-maybe-ignores-empty")
        unionMaybeRect(&acc, RenderRect(x: 0, y: 0, w: 10, h: 10))
        unionMaybeRect(&acc, RenderRect(x: 20, y: 0, w: 10, h: 10))
        #expect(acc == RenderRect(x: 0, y: 0, w: 30, h: 10), "union-maybe-accumulates")

        // lerpRect: clamped endpoints + midpoint.
        let from = RenderRect(x: 0, y: 0, w: 0, h: 0)
        let to = RenderRect(x: 10, y: 20, w: 100, h: 200)
        #expect(lerpRect(from, to, 0) == from, "lerp-0")
        #expect(lerpRect(from, to, 1) == to, "lerp-1")
        #expect(lerpRect(from, to, 0.5) == RenderRect(x: 5, y: 10, w: 50, h: 100), "lerp-mid")
        #expect(lerpRect(from, to, 2) == to, "lerp-clamps-high")

        // clipExtentRect: none passes, empty rejects, rect intersects.
        let r = RenderRect(x: 0, y: 0, w: 10, h: 10)
        #expect(clipExtentRect(.none, r) == r, "clip-none-passes")
        #expect(clipExtentRect(.empty, r) == nil, "clip-empty-rejects")
        #expect(
            clipExtentRect(.rect(RenderRect(x: 5, y: 0, w: 10, h: 10)), r)
                == RenderRect(x: 5, y: 0, w: 5, h: 10),
            "clip-rect-intersects")
        #expect(
            clipExtentRect(.none, RenderRect(x: 0, y: 0, w: 0, h: 0)) == nil, "clip-empty-area-nil")

        // accumulateExtentClip propagation.
        #expect(accumulateExtentClip(.empty, localClip: r) == .empty, "accum-empty-absorbing")
        #expect(accumulateExtentClip(.none, localClip: nil) == .none, "accum-none-no-local")
        #expect(accumulateExtentClip(.none, localClip: r) == .rect(r), "accum-none-adopts-local")
        let parent = RenderRect(x: 0, y: 0, w: 10, h: 10)
        #expect(
            accumulateExtentClip(.rect(parent), localClip: nil) == .rect(parent),
            "accum-rect-keeps-parent")
        #expect(
            accumulateExtentClip(.rect(parent), localClip: RenderRect(x: 5, y: 0, w: 10, h: 10))
                == .rect(RenderRect(x: 5, y: 0, w: 5, h: 10)), "accum-rect-intersects")
        #expect(
            accumulateExtentClip(.rect(parent), localClip: RenderRect(x: 100, y: 100, w: 5, h: 5))
                == .empty,
            "accum-rect-no-overlap-empty")
    }
}
