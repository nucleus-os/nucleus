/// Multiline editable text using the same editor, input-method, selection,
/// pasteboard, and retained-layout machinery as `TextField`.
@MainActor
open class TextView: TextField, ~Sendable {
    open override var allowsMultilineText: Bool { true }

    /// A comfortable editor minimum; layout continues growing with its content.
    public var minimumVisibleLineCount: Int = 3 {
        didSet {
            if minimumVisibleLineCount < 1 {
                minimumVisibleLineCount = 1
                return
            }
            invalidateIntrinsicContentSize()
        }
    }

    public override init(string: String = "", isSecure: Bool = false) {
        super.init(string: string, isSecure: isSecure)
        hints.insert(.multiline)
    }

    open override var intrinsicContentSize: Size {
        let layout = textLayout()
        let lineHeight = Double(font.metrics.lineHeight)
        return Size(
            width: max(
                120,
                layout.intrinsicSize.width + textInsets.left + textInsets.right
            ),
            height: max(
                lineHeight * Double(minimumVisibleLineCount)
                    + textInsets.top + textInsets.bottom,
                layout.intrinsicSize.height + textInsets.top + textInsets.bottom
            )
        )
    }
}
