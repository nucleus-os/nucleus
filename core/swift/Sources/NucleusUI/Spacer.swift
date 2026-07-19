/// Flexible empty space.
///
/// A stack's `Distribution` can space its arranged views apart, but only
/// uniformly. A spacer expresses the uneven case — the bar's three sections
/// pushed to their edges, a button pinned to the right of a row — as an ordinary
/// arranged view, which is the same thing `NSStackView` and flexbox do.
///
/// It has no appearance and no intrinsic size; it exists to take the slack.
@MainActor
public final class Spacer: View, ~Sendable {
    /// Create a spacer that absorbs whatever room is left over.
    ///
    /// - Parameter minimumLength: room the spacer keeps even when the stack is
    ///   short of space. Zero lets it collapse entirely, which is usually right —
    ///   a spacer is slack, not padding.
    public init(minimumLength: Double = 0) {
        self.minimumLength = minimumLength
        super.init()
        growFactor = 1
        // Slack is the first thing to give up when a stack is over-full: a
        // spacer shrinking is invisible, and a label shrinking is not.
        shrinkFactor = 1
        isAccessibilityElement = false
    }

    public var minimumLength: Double {
        didSet {
            guard minimumLength != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    public override var intrinsicContentSize: Size {
        Size(width: minimumLength, height: minimumLength)
    }

    /// A spacer draws nothing, so there is nothing to lay out inside it.
    public override func layout() {}
}
