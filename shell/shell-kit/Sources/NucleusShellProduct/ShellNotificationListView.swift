public import NucleusUI

public struct ShellNoticeContent: Sendable, Equatable {
    public var id: UInt32
    public var title: String
    public var body: String

    public init(id: UInt32, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

@MainActor
public final class ShellNotificationListView: View {
    private var notices:
        [(content: ShellNoticeContent, view: ShellNoticeView)] = []
    public var onDismiss: ((UInt32) -> Void)?

    public func update(_ contents: [ShellNoticeContent]) {
        for record in notices {
            record.view.removeFromSuperview()
        }
        notices = contents.map { content in
            let view = ShellNoticeView(
                title: content.title,
                body: content.body)
            addSubview(view)
            return (content, view)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Notifications"
        accessibilityRole = .window
        accessibilityChildren = notices.map(\.view)
        setNeedsLayout()
    }

    public override func layout() {
        var y = 0.0
        for record in notices {
            record.view.frame = Rect(
                x: 0,
                y: y,
                width: bounds.size.width,
                height: 112)
            y += 120
        }
    }
}
