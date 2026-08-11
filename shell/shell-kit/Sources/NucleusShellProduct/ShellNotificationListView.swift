package import NucleusUI

package struct ShellNoticeActionContent: Sendable, Equatable {
    package var id: String
    package var title: String

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

package struct ShellNoticeContent: Sendable, Equatable {
    package var id: String
    package var title: String
    package var body: String
    package var hasDefaultAction: Bool
    package var actions: [ShellNoticeActionContent]

    package init(
        id: String,
        title: String,
        body: String,
        hasDefaultAction: Bool = false,
        actions: [ShellNoticeActionContent] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.hasDefaultAction = hasDefaultAction
        self.actions = actions
    }
}

@MainActor
package final class ShellNotificationListView: View {
    private var notices: [(content: ShellNoticeContent, view: ShellNoticeView)] = []
    package var onDismiss: ((String) -> Void)?
    package var onActivate: ((String, String?) -> Void)?

    package func update(_ contents: [ShellNoticeContent]) {
        for record in notices {
            record.view.removeFromSuperview()
        }
        notices = contents.map { content in
            let view = ShellNoticeView(
                title: content.title,
                body: content.body)
            view.configureActions(
                content.actions,
                hasDefaultAction: content.hasDefaultAction,
                activate: { [weak self] actionID in
                    self?.onActivate?(content.id, actionID)
                },
                dismiss: { [weak self] in
                    self?.onDismiss?(content.id)
                })
            addSubview(view)
            return (content, view)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Notifications"
        accessibilityRole = .window
        accessibilityChildren = notices.map(\.view)
        setNeedsLayout()
    }

    package override func layout() {
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
