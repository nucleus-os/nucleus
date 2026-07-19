/// Quantizes scrolling into whole wheel detents.
///
/// Scrolling has two consumers with different needs, and conflating them is what
/// makes shell widgets feel wrong. **Content scrolling** wants the raw distance:
/// a list should track a touchpad exactly. **Discrete stepping** — volume,
/// workspace cycling, a value stepper — wants notches, and a notch must mean the
/// same thing whether it came from a ratcheted wheel, a free-spinning
/// high-resolution one, or a touchpad.
///
/// This is the second of those. Feed it every scroll event; it returns whole
/// steps and keeps the remainder.
public struct ScrollDetentAccumulator: Sendable, Equatable {
    /// Continuous-source distance that counts as one detent.
    ///
    /// A touchpad reports pixels, not notches, so a threshold is the only way to
    /// derive steps from it. Ten is what the reference uses and it is a feel
    /// decision, not a derived constant.
    public static let continuousDistancePerDetent: Double = 10

    private var remainder: Double = 0

    public init() {}

    /// Accumulate one event's scroll and return the whole detents it completed.
    ///
    /// - Parameters:
    ///   - detents: the device's own detent report, when it has one.
    ///   - distance: the continuous distance, used when it does not.
    ///   - source: decides whether the result is capped.
    public mutating func accumulate(
        detents: Double, distance: Double, source: ScrollSource
    ) -> Int {
        let increment = detents != 0 ? detents : distance / Self.continuousDistancePerDetent
        guard increment != 0 else { return 0 }

        // A reversal starts over rather than working off the old remainder.
        // Without this, scrolling up then immediately down feels dead for the
        // first notch, because the accumulated positive fraction has to be
        // spent before anything negative registers.
        if (increment > 0) != (remainder > 0) && remainder != 0 {
            remainder = 0
        }
        remainder += increment

        let steps = remainder < 0 ? remainder.rounded(.up) : remainder.rounded(.down)
        remainder -= steps

        // A ratcheted wheel emits one event per notch, so the notch the user
        // felt stays one step even when the compositor scales the delta. A
        // free-spinning wheel sends fractions and still has to accrue a whole
        // one. Continuous sources are not capped: a fast flick should step more
        // than once.
        if source == .wheel || source == .wheelTilt {
            return Int(max(-1, min(1, steps)))
        }
        return Int(steps)
    }

    /// Forget the partial detent. Call when a gesture ends, so the next one
    /// starts clean rather than inheriting a stale fraction.
    public mutating func reset() {
        remainder = 0
    }

    /// The unspent fraction, for tests and diagnostics.
    public var pendingFraction: Double { remainder }
}

extension Event {
    /// The scroll distance this event should move content by.
    ///
    /// A wheel reports detents, so the caller decides what a notch is worth. A
    /// touchpad reports distance and is used as given — scaling it would make
    /// the content lag the finger.
    public func scrollDistance(lineHeight: Double) -> Point {
        guard !hasPreciseScrollingDeltas else {
            return Point(x: scrollDeltaX, y: scrollDeltaY)
        }
        // Prefer the detent report: a high-resolution wheel expresses a fraction
        // of a notch there and nowhere else.
        if scrollDetentsX != 0 || scrollDetentsY != 0 {
            return Point(x: scrollDetentsX * lineHeight, y: scrollDetentsY * lineHeight)
        }
        return Point(x: scrollDeltaX * lineHeight, y: scrollDeltaY * lineHeight)
    }
}
