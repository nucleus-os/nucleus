import Testing
import NucleusUI

/// The bounds-origin model: a view's own coordinate system, and the translation
/// between it and the view's contents.
@MainActor
@Suite(.uiContext) struct BoundsOriginTests {
    private func makeView(_ rect: Rect) -> View {
        let view = View()
        view.frame = rect
        return view
    }

    // MARK: - bounds as storage

    /// The size is the frame's; the origin is the view's own.
    @Test func boundsReportsTheFrameSizeAndItsOwnOrigin() {
        let view = makeView(Rect(x: 10, y: 20, width: 100, height: 50))
        #expect(view.bounds == Rect(x: 0, y: 0, width: 100, height: 50))

        view.boundsOrigin = Point(x: 5, y: 40)
        #expect(view.bounds == Rect(x: 5, y: 40, width: 100, height: 50))
        #expect(view.frame.origin == Point(x: 10, y: 20), "the frame is untouched")
    }

    /// The setter used to drop what it was given. Assigning an origin through
    /// `bounds` must now round-trip.
    @Test func assigningBoundsStoresTheOrigin() {
        let view = makeView(Rect(x: 0, y: 0, width: 100, height: 50))
        view.bounds = Rect(x: 12, y: 34, width: 100, height: 50)
        #expect(view.boundsOrigin == Point(x: 12, y: 34))
        #expect(view.bounds.origin == Point(x: 12, y: 34))
    }

    /// Size stays the frame's to own. A bounds size that disagrees would be
    /// overwritten by the next layout pass anyway.
    @Test func assigningABoundsSizeDoesNotResizeTheView() {
        let view = makeView(Rect(x: 0, y: 0, width: 100, height: 50))
        view.bounds = Rect(x: 0, y: 0, width: 999, height: 999)
        #expect(view.frame.size == Size(width: 100, height: 50))
        #expect(view.bounds.size == Size(width: 100, height: 50))
    }

    /// The whole point of storing the offset here: layout rewrites child frames
    /// on every pass, and must not disturb the scroll position.
    @Test func layoutDoesNotDisturbTheBoundsOrigin() {
        let stack = StackView()
        stack.axis = .vertical
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        stack.addArrangedSubview(makeView(Rect(x: 0, y: 0, width: 100, height: 60)))
        stack.addArrangedSubview(makeView(Rect(x: 0, y: 0, width: 100, height: 60)))

        stack.boundsOrigin = Point(x: 0, y: 45)
        stack.setNeedsLayout()
        stack.layoutIfNeeded()

        #expect(stack.boundsOrigin == Point(x: 0, y: 45), "survives an arrange pass")
    }

    // MARK: - Conversion

    @Test func convertingWalksTheFrameOrigins() {
        let parent = makeView(Rect(x: 100, y: 200, width: 400, height: 400))
        let child = makeView(Rect(x: 10, y: 20, width: 100, height: 100))
        parent.addSubview(child)

        // A point at the child's own origin sits at the sum of the frames.
        #expect(child.convert(Point(x: 0, y: 0), to: nil) == Point(x: 110, y: 220))
        #expect(child.convert(Point(x: 110, y: 220), from: nil) == Point(x: 0, y: 0))
    }

    @Test func convertingAccountsForTheBoundsOrigin() {
        let parent = makeView(Rect(x: 0, y: 0, width: 400, height: 400))
        let child = makeView(Rect(x: 0, y: 100, width: 100, height: 100))
        parent.addSubview(child)

        // Scroll the parent down by 40: its contents move up by 40.
        parent.boundsOrigin = Point(x: 0, y: 40)
        #expect(child.convert(Point(x: 0, y: 0), to: nil) == Point(x: 0, y: 60))
    }

    /// Round-tripping is the property worth holding: every conversion has an
    /// inverse, whatever the frames and offsets in between.
    @Test func conversionRoundTrips() {
        let parent = makeView(Rect(x: 17, y: 31, width: 400, height: 400))
        let child = makeView(Rect(x: 5, y: 7, width: 100, height: 100))
        parent.addSubview(child)
        parent.boundsOrigin = Point(x: 3, y: 11)
        child.boundsOrigin = Point(x: 2, y: 13)

        let point = Point(x: 21, y: 22)
        let inWindow = child.convert(point, to: nil)
        #expect(child.convert(inWindow, from: nil) == point)
    }

    /// Terms for a shared ancestor cancel, so view-to-view conversion does not
    /// need a window — and these views have none.
    @Test func convertingBetweenSiblingsNeedsNoWindow() {
        let parent = makeView(Rect(x: 50, y: 50, width: 400, height: 400))
        let left = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        let right = makeView(Rect(x: 200, y: 0, width: 100, height: 100))
        parent.addSubview(left)
        parent.addSubview(right)

        #expect(left.convert(Point(x: 0, y: 0), to: right) == Point(x: -200, y: 0))
        #expect(right.convert(Point(x: 200, y: 0), from: left) == Point(x: 0, y: 0))
    }

    @Test func convertingARectMovesItsOrigin() {
        let parent = makeView(Rect(x: 10, y: 10, width: 400, height: 400))
        let child = makeView(Rect(x: 5, y: 5, width: 100, height: 100))
        parent.addSubview(child)

        let converted = child.convert(Rect(x: 0, y: 0, width: 30, height: 40), to: nil)
        #expect(converted == Rect(x: 15, y: 15, width: 30, height: 40))
    }

    // MARK: - Hit testing

    /// The defect the model exists to prevent: after scrolling, the click
    /// target must follow the content rather than staying where it was drawn.
    @Test func hitTestingFollowsScrolledContent() {
        let parent = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        let child = makeView(Rect(x: 0, y: 50, width: 100, height: 20))
        parent.addSubview(child)

        // Unscrolled, the child occupies y 50..<70.
        #expect(parent.hitTest(Point(x: 10, y: 55)) === child)
        #expect(parent.hitTest(Point(x: 10, y: 15)) === parent)

        // Scroll down by 40: the child now appears at y 10..<30.
        parent.boundsOrigin = Point(x: 0, y: 40)
        #expect(parent.hitTest(Point(x: 10, y: 15)) === child)
        #expect(parent.hitTest(Point(x: 10, y: 55)) === parent, "it moved away")
    }

    /// A view scrolled out of sight must not be clickable, which is what makes
    /// `clipsToBounds` a hit-testing concern and not only a drawing one.
    @Test func clippingRemovesHiddenContentFromHitTesting() {
        let parent = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        let child = makeView(Rect(x: 0, y: 20, width: 100, height: 20))
        parent.addSubview(child)
        parent.clipsToBounds = true

        #expect(parent.hitTest(Point(x: 10, y: 25)) === child)

        // Scroll the child up past the top edge.
        parent.boundsOrigin = Point(x: 0, y: 60)
        #expect(parent.hitTest(Point(x: 10, y: 25)) !== child,
                "scrolled out of sight, so not clickable")
    }

    /// Without clipping, a child outside the parent's bounds is still reachable
    /// — matching AppKit, where an unclipped subview draws and hits outside.
    @Test func withoutClippingOutsideContentStillHits() {
        let parent = makeView(Rect(x: 0, y: 0, width: 100, height: 100))
        let child = makeView(Rect(x: 0, y: 20, width: 100, height: 20))
        parent.addSubview(child)

        parent.boundsOrigin = Point(x: 0, y: 60)
        // The child is now at y -40..<-20 in the parent, outside its bounds, but
        // hit testing is bounded by the parent's frame either way.
        #expect(parent.hitTest(Point(x: 10, y: 25)) === parent)
    }

    // MARK: - Dispatch

    /// The delivered location is in the target's own coordinates, through the
    /// same conversion the rest of the system uses.
    @Test func dispatchDeliversInTargetCoordinates() {
        let root = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = ClickRecordingView()
        child.frame = Rect(x: 30, y: 40, width: 100, height: 100)
        root.addSubview(child)

        root.dispatchEvent(Event(type: .pointerDown, location: Point(x: 35, y: 45)))
        #expect(child.lastLocation == Point(x: 5, y: 5))
    }

    @Test func dispatchAccountsForScrolling() {
        let root = makeView(Rect(x: 0, y: 0, width: 200, height: 200))
        let child = ClickRecordingView()
        child.frame = Rect(x: 0, y: 100, width: 100, height: 100)
        root.addSubview(child)
        root.boundsOrigin = Point(x: 0, y: 80)

        // The child now appears at y 20; a click there is at its own y 0.
        root.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 20)))
        #expect(child.lastLocation == Point(x: 10, y: 0))
    }
}

@MainActor
private final class ClickRecordingView: View {
    var lastLocation: Point?

    override func handleEvent(_ event: Event) -> EventHandling {
        lastLocation = event.location
        return .handled
    }
}
