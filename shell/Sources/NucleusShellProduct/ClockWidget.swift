public import NucleusUI

/// The native bar clock. Wall-clock ownership stays in the runtime; the
/// product receives an already localized display value and retains one label.
@MainActor
public final class ClockWidget: BarWidget {
    public let label: Label
    public private(set) var displayText: String

    public override init() {
        displayText = ""
        label = Label("")
        super.init()
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = resolve(.role(.onSurface))
        accessibilityRole = .staticText
        setBody { label }
        showsCapsule = false
    }

    public func update(displayText: String) {
        guard displayText != self.displayText else { return }
        self.displayText = displayText
        label.text = displayText
        accessibilityLabel = displayText.isEmpty
            ? "Clock unavailable"
            : "Time, \(displayText)"
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    public override func viewDidChangeEffectiveAppearance() {
        label.textColor = resolve(.role(.onSurface))
        super.viewDidChangeEffectiveAppearance()
    }

    public override var intrinsicContentSize: Size {
        label.intrinsicContentSize
    }

    public override func measure(_ constraints: LayoutConstraints) -> Size {
        label.measure(constraints)
    }

    public override func layout() {
        label.centerVertically(in: bounds)
    }
}
