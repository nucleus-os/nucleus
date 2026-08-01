package import NucleusUI

/// The native bar clock. Wall-clock ownership stays in the runtime; the
/// product receives an already localized display value and retains one label.
@MainActor
package final class ClockWidget: BarWidget {
    package let label: Label
    package private(set) var displayText: String

    package override init() {
        displayText = ""
        label = Label("")
        super.init()
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = resolve(.role(.onSurface))
        accessibilityRole = .staticText
        setBody { label }
        showsCapsule = false
    }

    package func update(displayText: String) {
        guard displayText != self.displayText else { return }
        self.displayText = displayText
        label.text = displayText
        accessibilityLabel =
            displayText.isEmpty
            ? "Clock unavailable"
            : "Time, \(displayText)"
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    package override func viewDidChangeEffectiveAppearance() {
        label.textColor = resolve(.role(.onSurface))
        super.viewDidChangeEffectiveAppearance()
    }

    package override var intrinsicContentSize: Size {
        label.intrinsicContentSize
    }

    package override func measure(_ constraints: LayoutConstraints) -> Size {
        label.measure(constraints)
    }

    package override func layout() {
        label.centerVertically(in: bounds)
    }
}
