import Testing
@testable import NucleusUI

/// Wheel detents, and the two different things scrolling has to serve.
///
/// Content scrolling wants raw distance, so a list tracks a touchpad exactly.
/// Discrete stepping — volume, workspace cycling — wants notches, and a notch
/// must mean the same thing from a ratcheted wheel, a free-spinning
/// high-resolution one, or a touchpad. Conflating the two is what makes shell
/// widgets feel wrong.
@Suite(.uiContext) struct ScrollDetentTests {
    // MARK: - Whole detents

    /// A ratcheted wheel: one event, one notch.
    @Test func aWheelNotchIsOneStep() {
        var accumulator = ScrollDetentAccumulator()
        #expect(accumulator.accumulate(detents: 1, distance: 0, source: .wheel) == 1)
        #expect(accumulator.accumulate(detents: -1, distance: 0, source: .wheel) == -1)
    }

    /// A high-resolution wheel sends fractions of a notch, and they must accrue
    /// to a whole one before anything steps.
    @Test func fractionalDetentsAccrue() {
        var accumulator = ScrollDetentAccumulator()
        // Four sub-notch events at a quarter each.
        #expect(accumulator.accumulate(detents: 0.25, distance: 0, source: .wheel) == 0)
        #expect(accumulator.accumulate(detents: 0.25, distance: 0, source: .wheel) == 0)
        #expect(accumulator.accumulate(detents: 0.25, distance: 0, source: .wheel) == 0)
        #expect(accumulator.accumulate(detents: 0.25, distance: 0, source: .wheel) == 1,
                "the fourth completes the notch")
        #expect(accumulator.accumulate(detents: 0.25, distance: 0, source: .wheel) == 0,
                "and the next one starts over")
    }

    /// A compositor may scale the delta — niri's scroll-factor does — but the
    /// notch the user felt is still one notch.
    @Test func aWheelIsCappedAtOneStepPerEvent() {
        var accumulator = ScrollDetentAccumulator()
        #expect(accumulator.accumulate(detents: 5, distance: 0, source: .wheel) == 1)
        #expect(accumulator.accumulate(detents: -5, distance: 0, source: .wheel) == -1)
    }

    /// A touchpad is not capped: a fast flick should step more than once.
    @Test func aContinuousSourceIsNotCapped() {
        var accumulator = ScrollDetentAccumulator()
        let distance = ScrollDetentAccumulator.continuousDistancePerDetent * 3
        #expect(accumulator.accumulate(detents: 0, distance: distance, source: .finger) == 3)
    }

    /// A touchpad reports distance, not notches, so a threshold is the only way
    /// to derive steps from it.
    @Test func continuousDistanceAccruesToDetents() {
        var accumulator = ScrollDetentAccumulator()
        let half = ScrollDetentAccumulator.continuousDistancePerDetent / 2
        #expect(accumulator.accumulate(detents: 0, distance: half, source: .finger) == 0)
        #expect(accumulator.accumulate(detents: 0, distance: half, source: .finger) == 1)
    }

    /// Reversing starts over. Otherwise scrolling up then down feels dead for a
    /// notch, because the accumulated positive fraction has to be spent first.
    @Test func reversingDirectionDiscardsTheRemainder() {
        var accumulator = ScrollDetentAccumulator()
        _ = accumulator.accumulate(detents: 0.9, distance: 0, source: .wheel)
        #expect(accumulator.pendingFraction > 0.5, "most of a notch is pending")

        #expect(accumulator.accumulate(detents: -0.9, distance: 0, source: .wheel) == 0)
        #expect(accumulator.pendingFraction < 0, "the pending fraction reversed with it")
    }

    @Test func aResetForgetsThePartialDetent() {
        var accumulator = ScrollDetentAccumulator()
        _ = accumulator.accumulate(detents: 0.9, distance: 0, source: .wheel)
        accumulator.reset()
        #expect(accumulator.pendingFraction == 0)
        #expect(accumulator.accumulate(detents: 0.5, distance: 0, source: .wheel) == 0,
                "half a notch from a clean start is not a step")
    }

    @Test func nothingScrolledIsNoStep() {
        var accumulator = ScrollDetentAccumulator()
        #expect(accumulator.accumulate(detents: 0, distance: 0, source: .wheel) == 0)
    }

    /// The device's own detent report wins over the distance when it has one.
    @Test func reportedDetentsBeatDerivedOnes() {
        var accumulator = ScrollDetentAccumulator()
        // A large distance alongside a small detent report: the report is the
        // authority, so this is a fraction of a notch rather than many.
        #expect(accumulator.accumulate(detents: 0.5, distance: 1000, source: .wheel) == 0)
    }

    // MARK: - Content distance

    private func scrollEvent(
        deltaY: Double = 0, detentsY: Double = 0, source: ScrollSource
    ) -> Event {
        Event(
            type: .scrollWheel, location: .zero, timestampNanoseconds: 0,
            scrollDeltaY: deltaY, scrollSource: source, scrollDetentsY: detentsY)
    }

    /// A touchpad's distance is used as given. Scaling it makes content lag the
    /// finger, which is immediately visible.
    @Test func aTouchpadScrollsByItsOwnDistance() {
        let event = scrollEvent(deltaY: 37, source: .finger)
        #expect(event.scrollDistance(lineHeight: 40).y == 37)
    }

    /// A wheel reports notches, so the view decides what a notch is worth.
    @Test func aWheelScrollsByLines() {
        let event = scrollEvent(detentsY: 1, source: .wheel)
        #expect(event.scrollDistance(lineHeight: 40).y == 40)
    }

    /// The point of high-resolution wheels: a third of a notch moves a third of
    /// a line, so a free-spinning wheel scrolls smoothly.
    @Test func aHighResolutionWheelScrollsProportionally() {
        let event = scrollEvent(detentsY: 1.0 / 3, source: .wheel)
        #expect(abs(event.scrollDistance(lineHeight: 60).y - 20) < 0.001)
    }

    /// A wheel that reports no detents at all falls back to its raw delta as a
    /// notch count, which is what the pre-value120 protocol gave.
    @Test func aWheelWithoutDetentsTreatsItsDeltaAsNotches() {
        let event = scrollEvent(deltaY: 2, source: .wheel)
        #expect(event.scrollDistance(lineHeight: 40).y == 80)
    }

    // MARK: - Source

    @Test func preciseScrollingIsDerivedFromTheSource() {
        #expect(scrollEvent(source: .finger).hasPreciseScrollingDeltas)
        #expect(scrollEvent(source: .continuous).hasPreciseScrollingDeltas)
        #expect(!scrollEvent(source: .wheel).hasPreciseScrollingDeltas)
        #expect(!scrollEvent(source: .wheelTilt).hasPreciseScrollingDeltas)
    }

    /// An unreported source is treated as a wheel: a detented view stepping once
    /// is a better failure than a smooth view jumping.
    @Test func anUnknownSourceIsTreatedAsAWheel() {
        #expect(!scrollEvent(source: .unknown).hasPreciseScrollingDeltas)
    }
}

/// `ScrollView` against the two device kinds.
@MainActor
@Suite(.uiContext) struct ScrollViewDeviceTests {
    private func makeScrollView() -> ScrollView {
        let scrollView = ScrollView()
        scrollView.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let content = View()
        content.frame = Rect(x: 0, y: 0, width: 100, height: 1000)
        scrollView.documentView = content
        scrollView.layoutIfNeeded()
        return scrollView
    }

    private func scroll(
        _ scrollView: ScrollView, deltaY: Double = 0, detentsY: Double = 0,
        source: ScrollSource
    ) {
        var event = Event(
            type: .scrollWheel, location: Point(x: 10, y: 10), timestampNanoseconds: 0,
            scrollDeltaY: deltaY, scrollSource: source, scrollDetentsY: detentsY)
        event.button = .left
        _ = scrollView.handleEvent(event)
    }

    @Test func aWheelNotchScrollsOneLine() {
        let scrollView = makeScrollView()
        scrollView.lineScrollDistance = 40
        scroll(scrollView, detentsY: 1, source: .wheel)
        #expect(scrollView.contentOffset.y == 40)
    }

    /// The fidelity this phase exists for: a free-spinning wheel moves by less
    /// than a line instead of snapping.
    @Test func aFractionalNotchScrollsProportionally() {
        let scrollView = makeScrollView()
        scrollView.lineScrollDistance = 40
        scroll(scrollView, detentsY: 0.25, source: .wheel)
        #expect(scrollView.contentOffset.y == 10)
    }

    @Test func aTouchpadScrollsByItsOwnDistance() {
        let scrollView = makeScrollView()
        scrollView.lineScrollDistance = 40
        scroll(scrollView, deltaY: 13, source: .finger)
        #expect(scrollView.contentOffset.y == 13, "not multiplied by the line height")
    }
}
