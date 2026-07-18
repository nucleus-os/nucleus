import NucleusUI

/// The shell's top bar: fixed chrome at each end, flexible space between.
///
/// The layout acceptance test for this tier. Everything here — flexible space,
/// cross-axis alignment, nested stacks measuring their own children — is
/// expressed with NucleusUI constraints alone. If the bar needed a
/// shell-specific placement rule to come out right, that would be a missing
/// general rule in the layout system rather than something to compensate for
/// here.
@MainActor
public final class ShellBarView: View {
    /// Chrome pinned to the leading edge, laid out left to right.
    public let leadingItems: StackView
    /// Chrome pinned to the trailing edge.
    public let trailingItems: StackView

    private let row: StackView
    /// Carries no content and no intrinsic size; it exists to absorb whatever
    /// width the two item groups do not use. This is what pins the trailing
    /// group to the right edge at any bar width.
    private let flexibleSpace: View

    public override init() {
        row = StackView(axis: .horizontal, spacing: 8, alignment: .center)
        leadingItems = StackView(axis: .horizontal, spacing: 6, alignment: .center)
        trailingItems = StackView(axis: .horizontal, spacing: 6, alignment: .center)
        flexibleSpace = View()
        super.init()

        row.layoutMargins = EdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        flexibleSpace.growFactor = 1
        // The item groups are sized by their contents and never squeezed by the
        // spacer, which is the whole point of the arrangement.
        leadingItems.shrinkFactor = 0
        trailingItems.shrinkFactor = 0

        addSubview(row)
        row.addArrangedSubview(leadingItems)
        row.addArrangedSubview(flexibleSpace)
        row.addArrangedSubview(trailingItems)
    }

    public override var intrinsicContentSize: Size {
        Size(width: 0, height: 26)
    }

    public override func layout() {
        row.arrange(in: bounds)
    }
}

/// A panel of wrapped body text under a title — the case that cannot be laid
/// out from `intrinsicContentSize` at all, because the body's height is a
/// function of the width the panel is given.
@MainActor
public final class ShellNoticeView: View {
    public let titleLabel: Label
    public let bodyLabel: Label

    private let column: StackView

    public init(title: String = "", body: String = "") {
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
    public override func measure(_ constraints: LayoutConstraints) -> Size {
        column.measure(constraints)
    }

    public override func layout() {
        column.arrange(in: bounds)
    }
}
