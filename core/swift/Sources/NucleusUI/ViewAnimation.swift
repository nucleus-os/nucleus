@_spi(NucleusCompositor) import NucleusLayers

/// A view property that can be animated by the compositor.
///
/// Deliberately narrower than "any property": these are the ones the render
/// tier interpolates on its own thread. Animating anything else means driving it
/// from the frame loop, and pretending otherwise would produce properties that
/// silently snap instead of animating.
public enum AnimatableProperty: Sendable, Equatable {
    case opacity
    case cornerRadius
    case positionX
    case positionY
    case boundsWidth
    case boundsHeight
    case scrollOffsetX
    case scrollOffsetY

    var keyPath: AnimationKeyPath {
        switch self {
        case .opacity: return .opacity
        case .cornerRadius: return .cornerRadius
        case .positionX: return .positionX
        case .positionY: return .positionY
        case .boundsWidth: return .boundsW
        case .boundsHeight: return .boundsH
        case .scrollOffsetX: return .scrollOffsetX
        case .scrollOffsetY: return .scrollOffsetY
        }
    }
}

/// How an animation moves between its endpoints.
public struct AnimationTiming: Sendable, Equatable {
    public var duration: Double
    public var curve: AnimationCurve

    public init(duration: Double, curve: AnimationCurve = .bezier(.default)) {
        self.duration = duration
        self.curve = curve
    }

    /// The reference's three durations, which are conventions worth sharing:
    /// a shell whose panels and toggles animate at unrelated speeds reads as
    /// unfinished.
    public static let fast = AnimationTiming(duration: 0.10)
    public static let standard = AnimationTiming(duration: 0.20)
    public static let slow = AnimationTiming(duration: 0.40)

    public static func spring(
        duration: Double = 0.4, _ curve: SpringCurve = .snappy
    ) -> AnimationTiming {
        AnimationTiming(duration: duration, curve: .spring(curve))
    }
}

/// Global motion policy.
///
/// A single switch rather than a per-call flag: reduce-motion is an
/// accessibility preference, and honouring it only where a caller remembered to
/// check would honour it nowhere. When motion is off, animations are not
/// shortened — they are skipped, and the property takes its final value at once.
@MainActor
public enum Motion {
    /// Set false for reduce-motion. Every `animate` call becomes an immediate
    /// assignment.
    public static var isEnabled = true

    /// Multiplies every duration. For a global speed preference, and for making
    /// animation observable in a test without waiting.
    public static var speed: Double = 1 {
        didSet { if speed <= 0 { speed = 1 } }
    }

    static func effectiveDuration(_ duration: Double) -> Double {
        guard isEnabled else { return 0 }
        return duration / speed
    }
}

extension View {
    /// Animate a property from one value to another.
    ///
    /// The render tier interpolates this — the animation runs on the compositor
    /// without the frame loop assigning anything per frame, which is why the
    /// property set is narrow and why `Motion` can skip it wholesale.
    ///
    /// Returns whether an animation was actually started; `false` means motion
    /// is disabled and the caller should assign the final value itself.
    @discardableResult
    public func animate(
        _ property: AnimatableProperty,
        from: Double,
        to: Double,
        timing: AnimationTiming = .standard,
        id: UInt64 = 0
    ) -> Bool {
        let duration = Motion.effectiveDuration(timing.duration)
        guard duration > 0 else { return false }

        let animation = Animation.scalar(
            keyPath: property.keyPath,
            from: from, to: to,
            duration: duration,
            curve: timing.curve,
            id: id)
        LayerTransaction.appendAmbient(
            .animationAdded(layer: backingLayer.id, animation),
            in: backingLayer.context)
        return true
    }

    /// Stop animating a property. Whatever value it currently shows stays.
    public func removeAnimation(for property: AnimatableProperty) {
        LayerTransaction.appendAmbient(
            .animationRemoved(layer: backingLayer.id, property.keyPath),
            in: backingLayer.context)
    }

    /// Fade in from transparent, and unhide.
    ///
    /// `isHidden` is cleared *first*: a hidden layer does not composite, so
    /// fading one in would run the animation invisibly and pop at the end.
    public func fadeIn(timing: AnimationTiming = .standard) {
        isHidden = false
        // With motion off this is just the unhide above, which is the correct
        // reduced behaviour: the view appears at its final opacity.
        animate(.opacity, from: 0, to: alphaValue, timing: timing)
    }

    /// Fade to transparent. The caller hides or removes the view on completion —
    /// this does not, because there is no completion callback at this tier and
    /// guessing would leave views either flashing back or vanishing early.
    public func fadeOut(timing: AnimationTiming = .standard) {
        // Model first, then the animation — the Core Animation order, and for the
        // same reason. An animation installs a *presentation override* that the
        // compositor shows while it runs, so moving the model value immediately
        // is not a race with it. Leaving the model behind would be the bug:
        // `alphaValue` is the view tier's authoritative value, and a later write
        // that included opacity would push the stale one back out.
        let start = alphaValue
        alphaValue = 0
        animate(.opacity, from: start, to: 0, timing: timing)
    }
}
