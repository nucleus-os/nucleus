package import NucleusUI

/// A panel of wrapped body text under a title — the case that cannot be laid
/// out from `intrinsicContentSize` at all, because the body's height is a
/// function of the width the panel is given.
@MainActor
package final class ShellNoticeView: View {
    package let titleLabel: Label
    package let bodyLabel: Label

    private let column: StackView
    private var actionButtons: [Button] = []

    package init(title: String = "", body: String = "") {
        column = StackView(axis: .vertical, spacing: 4, alignment: .fill)
        titleLabel = Label(title)
        bodyLabel = Label(body)
        super.init()

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.numberOfLines = 6

        column.layoutMargins = EdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        addSubview(column)
        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(bodyLabel)
    }

    /// Defers to the column, which measures the wrapped body against the
    /// width being proposed.
    package override func measure(_ constraints: LayoutConstraints) -> Size {
        column.measure(constraints)
    }

    package override func layout() {
        let actionHeight = actionButtons.isEmpty ? 0.0 : 30.0
        column.arrange(
            in: Rect(
                x: 0,
                y: 0,
                width: bounds.size.width,
                height: max(0, bounds.size.height - actionHeight)))
        guard !actionButtons.isEmpty else { return }
        let width = bounds.size.width / Double(actionButtons.count)
        for (index, button) in actionButtons.enumerated() {
            button.frame = Rect(
                x: Double(index) * width,
                y: bounds.size.height - actionHeight,
                width: width,
                height: actionHeight)
        }
    }

    package func configureActions(
        _ actions: [ShellNoticeActionContent],
        hasDefaultAction: Bool,
        activate: @escaping @MainActor (String?) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons.removeAll(keepingCapacity: true)
        if hasDefaultAction {
            addActionButton(title: "Open") { activate(nil) }
        }
        for action in actions.prefix(3) {
            addActionButton(title: action.title) { activate(action.id) }
        }
        addActionButton(title: "Dismiss", perform: dismiss)
        accessibilityChildren = [titleLabel, bodyLabel] + actionButtons
        setNeedsLayout()
    }

    private func addActionButton(
        title: String,
        perform: @escaping @MainActor () -> Void
    ) {
        let button = Button(title: title)
        button.onPress { _ in perform() }
        addSubview(button)
        actionButtons.append(button)
    }
}
