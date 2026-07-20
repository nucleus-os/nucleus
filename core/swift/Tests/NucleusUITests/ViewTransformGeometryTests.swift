import Testing
@testable import NucleusUI

/// Transforms in hit testing and coordinate conversion.
///
/// `transform` was published to the backing layer and ignored by everything
/// else: a scaled view drew scaled and hit-tested at its original size, and a
/// rotated one drew rotated and hit-tested as an upright box. The step between a
/// view and its parent was open-coded in four places, none of which applied it.
@MainActor
@Suite(.uiContext) struct ViewTransformGeometryTests {
    private func makeView(_ frame: Rect) -> View {
        let view = View()
        view.frame = frame
        return view
    }

    private func expectClose(
        _ point: Point, _ x: Double, _ y: Double,
        _ comment: Comment? = nil, tolerance: Double = 0.001
    ) {
        #expect(abs(point.x - x) < tolerance && abs(point.y - y) < tolerance,
                comment ?? "expected (\(x), \(y)), got (\(point.x), \(point.y))")
    }

    // MARK: - The untransformed case is unchanged

    @Test func withoutATransformConversionIsATranslation() {
        let view = makeView(Rect(x: 10, y: 20, width: 100, height: 50))
        expectClose(view.convertFromParent(Point(x: 15, y: 25)), 5, 5)
        expectClose(view.convertToParent(Point(x: 5, y: 5)), 15, 25)
    }

    @Test func scrollOffsetStillShiftsContents() {
        let view = makeView(Rect(x: 0, y: 0, width: 100, height: 50))
        view.boundsOrigin = Point(x: 0, y: 30)
        expectClose(view.convertFromParent(Point(x: 10, y: 10)), 10, 40)
    }

    // MARK: - Scale

    /// A view scales about its centre, which is the anchor the renderer pivots
    /// on. The centre therefore maps to itself.
    @Test func aScaledViewTransformsAboutItsCentre() {
        let view = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        view.transform = .scale(x: 2, y: 2)

        expectClose(view.convertFromParent(Point(x: 50, y: 50)), 50, 50, "the centre is fixed")
        // A point 20 out from the centre in parent space is 10 out in local
        // space, because the view is drawn at twice size.
        expectClose(view.convertFromParent(Point(x: 70, y: 50)), 60, 50)
    }

    @Test func conversionRoundTrips() {
        let view = makeView(Rect(x: 13, y: 7, width: 80, height: 40))
        view.transform = .scale(x: 1.5, y: 0.5)

        let original = Point(x: 22, y: 9)
        let roundTripped = view.convertFromParent(view.convertToParent(original))
        expectClose(roundTripped, original.x, original.y)
    }

    /// The defect, at the level a user meets it: a view scaled up is hittable
    /// across the area it visibly covers.
    @Test func aScaledUpViewIsHittableWhereItIsDrawn() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 50, y: 50, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .scale(x: 2, y: 2)

        // Scaled 2x about its centre (100, 100), the child now covers
        // (0, 0)...(200, 200) in the parent. A point at (10, 10) is inside the
        // drawn view and outside its untransformed frame.
        #expect(parent.hitTest(Point(x: 10, y: 10)) === child,
                "hit where it is drawn, not where its frame was")
    }

    /// And the converse: scaled down, it stops being hittable outside itself.
    @Test func aScaledDownViewIsNotHittableBeyondItsDrawnArea() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 50, y: 50, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .scale(x: 0.5, y: 0.5)

        // Half size about the centre (100, 100) covers (75, 75)...(125, 125).
        #expect(parent.hitTest(Point(x: 100, y: 100)) === child, "the centre still hits")
        #expect(parent.hitTest(Point(x: 60, y: 60)) === parent,
                "inside the old frame, outside the drawn view")
    }

    // MARK: - Rotation

    /// A quarter turn about the centre. The corners of a square view land on
    /// each other, so a point near one corner maps to a point near another.
    @Test func aRotatedViewMapsThroughItsRotation() {
        let view = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        view.transform = .rotation(radians: .pi / 2)

        expectClose(view.convertFromParent(Point(x: 50, y: 50)), 50, 50, "the centre is fixed")
        // Rotating the *view* by +90° means the inverse maps a parent point back
        // by -90° about the centre.
        let mapped = view.convertFromParent(Point(x: 100, y: 50))
        expectClose(mapped, 50, 0)
    }

    /// A rotated view is not the axis-aligned box its frame describes. A square
    /// rotated 45° pulls in at the corners of that box.
    @Test func aRotatedViewIsNotHittableAtItsFrameCorners() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 50, y: 50, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .rotation(radians: .pi / 4)

        #expect(parent.hitTest(Point(x: 100, y: 100)) === child, "the centre hits")
        // The frame's corner is outside a 45°-rotated square inscribed in it.
        #expect(parent.hitTest(Point(x: 52, y: 52)) === parent,
                "the frame corner is outside the rotated view")
    }

    // MARK: - Degenerate transforms

    /// A view scaled to nothing is hittable nowhere rather than everywhere. The
    /// inverse does not exist, and inventing one would make it swallow input
    /// across its whole frame.
    @Test func aCollapsedViewIsNotHittable() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 50, y: 50, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .scale(x: 0, y: 0)

        #expect(parent.hitTest(Point(x: 100, y: 100)) === parent)
    }

    @Test func aSingularTransformHasNoInverse() {
        #expect(AffineTransform(a: 0, b: 0, c: 0, d: 0).inverted() == nil)
        #expect(AffineTransform(a: 1, b: 2, c: 2, d: 4).inverted() == nil, "parallel rows")
        #expect(AffineTransform.identity.inverted() == .identity)
    }

    // MARK: - Rectangles

    /// A rectangle under a scale does not keep its size. Passing the size
    /// through unchanged — which conversion used to do — cannot say that.
    @Test func convertingARectangleScalesIt() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .scale(x: 2, y: 2)

        let converted = parent.convert(
            Rect(x: 25, y: 25, width: 50, height: 50), from: child)
        #expect(abs(converted.size.width - 100) < 0.001, "a 50-wide rect at 2x is 100 wide")
        #expect(abs(converted.size.height - 100) < 0.001)
    }

    /// Under a rotation the result is the bounding box of the mapped corners,
    /// which is larger than the original — the honest answer for a rectangle
    /// that is no longer axis-aligned.
    @Test func convertingARectangleUnderRotationBoundsIt() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        parent.addSubview(child)
        child.transform = .rotation(radians: .pi / 4)

        let converted = parent.convert(
            Rect(x: 40, y: 40, width: 20, height: 20), from: child)
        // A 20x20 square rotated 45° bounds to 20√2 ≈ 28.28.
        #expect(abs(converted.size.width - 28.284) < 0.01)
        #expect(abs(converted.size.height - 28.284) < 0.01)
    }

    @Test func anUntransformedRectangleKeepsItsSize() {
        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = makeView(Rect(x: 10, y: 10, width: 100, height: 100))
        parent.addSubview(child)

        let converted = parent.convert(
            Rect(x: 5, y: 5, width: 30, height: 40), from: child)
        #expect(converted == Rect(x: 15, y: 15, width: 30, height: 40))
    }

    // MARK: - Event delivery

    /// The location a view receives must be in its own coordinates, through the
    /// transform — otherwise a scaled control computes the wrong caret offset or
    /// slider value from a click it correctly received.
    @Test func aDeliveredEventCarriesTransformedCoordinates() {
        final class Recorder: View, @unchecked Sendable {
            var received: Point?
            override func handleEvent(_ event: Event) -> EventHandling {
                received = event.location
                return .handled
            }
        }

        let parent = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = Recorder()
        child.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        parent.addSubview(child)
        child.transform = .scale(x: 2, y: 2)

        // The child covers (-50, -50)...(150, 150); (25, 25) in the parent is
        // 25 out from the centre, so 12.5 out in the child's own space.
        var event = Event(type: .pointerDown, location: Point(x: 25, y: 25),
                          timestampNanoseconds: 0)
        event.button = .left
        _ = parent.dispatchEvent(event)

        guard let received = child.received else {
            Issue.record("child did not receive the transformed event")
            return
        }
        expectClose(received, 37.5, 37.5)
    }
}
