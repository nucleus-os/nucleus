/// The size range a parent offers a child during measurement.
///
/// `intrinsicContentSize` answers "how big are you, unconstrained" — which is
/// the wrong question for anything whose height depends on its width. A wrapped
/// label is the canonical case: at width 200 it is two lines tall, at width 400
/// one. Constraints carry the proposal so the child can answer honestly.
///
/// Maxima may be `.infinity`, meaning "as large as you like on this axis".
/// Minima are always finite.
public struct LayoutConstraints: Equatable, Sendable {
    public let minWidth: Double
    public let maxWidth: Double
    public let minHeight: Double
    public let maxHeight: Double

    public init(
        minWidth: Double = 0,
        maxWidth: Double = .infinity,
        minHeight: Double = 0,
        maxHeight: Double = .infinity
    ) {
        let width = Self.canonicalRange(minimum: minWidth, maximum: maxWidth)
        let height = Self.canonicalRange(minimum: minHeight, maximum: maxHeight)
        self.minWidth = width.minimum
        self.maxWidth = width.maximum
        self.minHeight = height.minimum
        self.maxHeight = height.maximum
    }

    /// No bounds on either axis. Measuring against this yields the intrinsic size.
    public static let unconstrained = LayoutConstraints()

    /// Exactly `size` on both axes — the child has no choice.
    public static func tight(_ size: Size) -> LayoutConstraints {
        LayoutConstraints(
            minWidth: size.width, maxWidth: size.width,
            minHeight: size.height, maxHeight: size.height)
    }

    /// At most `size`, with no minimum. The common "here is the space available".
    public static func upTo(_ size: Size) -> LayoutConstraints {
        LayoutConstraints(maxWidth: size.width, maxHeight: size.height)
    }

    /// The width being proposed, or `nil` when width is unbounded. Text layout
    /// takes this as its container width: `nil` means "do not wrap".
    public var proposedWidth: Double? {
        maxWidth.isFinite ? maxWidth : nil
    }

    public var proposedHeight: Double? {
        maxHeight.isFinite ? maxHeight : nil
    }

    public var hasTightWidth: Bool { minWidth == maxWidth }
    public var hasTightHeight: Bool { minHeight == maxHeight }

    /// Clamp `size` into this range. Infinite maxima leave that axis alone.
    public func constrain(_ size: Size) -> Size {
        Size(
            width: Self.constrain(size.width, minimum: minWidth, maximum: maxWidth),
            height: Self.constrain(size.height, minimum: minHeight, maximum: maxHeight))
    }

    /// The constraints that remain after reserving `insets` — what a container
    /// offers its children once its own padding is taken out.
    public func inset(by insets: EdgeInsets) -> LayoutConstraints {
        let horizontal = Self.canonicalInset(insets.left)
            + Self.canonicalInset(insets.right)
        let vertical = Self.canonicalInset(insets.top)
            + Self.canonicalInset(insets.bottom)
        return LayoutConstraints(
            minWidth: max(0, minWidth - horizontal),
            maxWidth: maxWidth.isFinite ? max(0, maxWidth - horizontal) : .infinity,
            minHeight: max(0, minHeight - vertical),
            maxHeight: maxHeight.isFinite ? max(0, maxHeight - vertical) : .infinity)
    }

    /// Drop the minima, keeping the maxima. A container that will position a
    /// child itself does not want the child inflating to the container's own
    /// minimum.
    public var looseningMinima: LayoutConstraints {
        LayoutConstraints(maxWidth: maxWidth, maxHeight: maxHeight)
    }

    private static func canonicalRange(
        minimum: Double, maximum: Double
    ) -> (minimum: Double, maximum: Double) {
        let minimum = minimum.isFinite ? max(0, minimum) : 0
        let canonicalMaximum: Double
        if maximum == .infinity {
            canonicalMaximum = .infinity
        } else if maximum.isFinite {
            canonicalMaximum = max(minimum, max(0, maximum))
        } else {
            // NaN and negative infinity are invalid maxima. Collapsing to the
            // minimum yields a deterministic tight range.
            canonicalMaximum = minimum
        }
        return (minimum, canonicalMaximum)
    }

    private static func constrain(
        _ proposed: Double, minimum: Double, maximum: Double
    ) -> Double {
        guard proposed.isFinite else { return minimum }
        return min(max(max(0, proposed), minimum), maximum)
    }

    private static func canonicalInset(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
