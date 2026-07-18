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
    public var minWidth: Double
    public var maxWidth: Double
    public var minHeight: Double
    public var maxHeight: Double

    public init(
        minWidth: Double = 0,
        maxWidth: Double = .infinity,
        minHeight: Double = 0,
        maxHeight: Double = .infinity
    ) {
        self.minWidth = max(0, minWidth)
        self.maxWidth = max(self.minWidth, maxWidth)
        self.minHeight = max(0, minHeight)
        self.maxHeight = max(self.minHeight, maxHeight)
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
            width: min(max(size.width, minWidth), maxWidth),
            height: min(max(size.height, minHeight), maxHeight))
    }

    /// The constraints that remain after reserving `insets` — what a container
    /// offers its children once its own padding is taken out.
    public func inset(by insets: EdgeInsets) -> LayoutConstraints {
        let horizontal = insets.left + insets.right
        let vertical = insets.top + insets.bottom
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
}
