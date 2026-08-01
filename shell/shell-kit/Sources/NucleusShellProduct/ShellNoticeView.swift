package import NucleusUI

/// A panel of wrapped body text under a title — the case that cannot be laid
/// out from `intrinsicContentSize` at all, because the body's height is a
/// function of the width the panel is given.
@MainActor
package final class ShellNoticeView: View {
    package let titleLabel: Label
    package let bodyLabel: Label

    private let column: StackView

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
        column.arrange(in: bounds)
    }
}
