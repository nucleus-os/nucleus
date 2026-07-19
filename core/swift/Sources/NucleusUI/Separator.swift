/// A dividing rule.
///
/// The orientation is inferred from the stack it sits in, because that is what
/// the caller means every time: a rule inside a row is vertical, a rule inside a
/// column is horizontal. Stating it at each use site is a chance to state it
/// wrong, and a wrong one is invisible until the layout changes direction.
@MainActor
public final class Separator: View, ~Sendable {
    public enum Orientation: Sendable, Equatable {
        /// Perpendicular to the enclosing stack's axis. A rule in a column is
        /// horizontal; a rule in a row is vertical.
        case automatic
        case horizontal
        case vertical
    }

    public var orientation: Orientation = .automatic {
        didSet {
            guard orientation != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    /// The rule's own width. Not scaled by anything: a hairline that rounds to
    /// zero on one display and two pixels on another is worse than a consistent
    /// one.
    public var thickness: Double = 1 {
        didSet {
            guard thickness != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// Clear space on either side of the rule, across it.
    ///
    /// Part of the separator rather than the stack's spacing because a rule
    /// usually wants more room around it than the items it divides want from
    /// each other.
    public var spacing: Double = 0 {
        didSet {
            guard spacing != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    public var color: ColorSpec = .role(.outline) {
        didSet { if color != oldValue { setNeedsDisplay() } }
    }

    public init(orientation: Orientation = .automatic) {
        self.orientation = orientation
        super.init()
        isAccessibilityElement = false
    }

    /// Whether the rule runs across the layout rather than down it.
    public var isHorizontalRule: Bool {
        switch orientation {
        case .horizontal: return true
        case .vertical: return false
        case .automatic:
            // A rule divides a stack's items, so it lies across the axis they
            // are arranged along.
            guard let stack = parentView as? StackView else { return true }
            return stack.axis == .vertical
        }
    }

    /// Thick across, and nothing along — the stack stretches it the other way.
    public override var intrinsicContentSize: Size {
        let across = thickness + spacing * 2
        return isHorizontalRule
            ? Size(width: 0, height: across)
            : Size(width: across, height: 0)
    }

    public override func draw(in context: GraphicsContext) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, thickness > 0 else { return }

        let rule: Rect
        if isHorizontalRule {
            // Centred in whatever height the stack gave, which may exceed the
            // intrinsic one when the stack stretches its items.
            rule = Rect(
                x: 0, y: (size.height - thickness) / 2,
                width: size.width, height: thickness)
        } else {
            rule = Rect(
                x: (size.width - thickness) / 2, y: 0,
                width: thickness, height: size.height)
        }
        context.fillColor = resolve(color)
        context.fill(rule)
    }
}
