public struct MenuItem {
    public var id: CollectionItemID
    public var title: String
    public var isEnabled: Bool
    public var action: @MainActor () -> Void

    public init(
        id: some Hashable & Sendable,
        title: String,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = CollectionItemID(id)
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Portable menu content. Presentation remains a `Popover` owned by a scene.
@MainActor
public final class Menu: StackView, ~Sendable {
    public let items: [MenuItem]
    package var onPerform: (() -> Void)?

    public init(items: [MenuItem]) {
        precondition(
            Set(items.map(\.id)).count == items.count,
            "menu item identities must be unique")
        self.items = items
        super.init(axis: .vertical, spacing: 2, alignment: .fill)
        isAccessibilityElement = true
        accessibilityRole = .menu
        layoutMargins = EdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for item in items {
            let button = Button(title: item.title)
            button.accessibilityRole = .menuItem
            button.isEnabled = item.isEnabled
            button.frame = Rect(x: 0, y: 0, width: 180, height: 28)
            button.onPress { [weak self] _ in
                item.action()
                self?.onPerform?()
            }
            addArrangedSubview(button)
        }
        frame = Rect(
            x: 0,
            y: 0,
            width: 188,
            height: Double(items.count) * 30 + 8)
    }

    package func makePopover(
        anchor: Rect,
        preferring edge: PopupEdge = .below
    ) -> Popover {
        Popover.withChrome(
            content: self,
            anchor: anchor,
            preferring: edge,
            dismissal: [.outsideClick, .escapeKey],
            focusBehavior: .key,
            padding: .zero,
            level: .overlay)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        guard event.type == .keyDown else {
            return super.handleEvent(event)
        }
        switch event.keyCode {
        case .upArrow:
            return window?.advanceFocus(reverse: true) == true
                ? .handled : .notHandled
        case .downArrow:
            return window?.advanceFocus() == true
                ? .handled : .notHandled
        case .home:
            guard let first = firstTabStop() else { return .notHandled }
            return window?.makeFirstResponder(first) == true
                ? .handled : .notHandled
        case .end:
            guard let last = lastTabStop() else { return .notHandled }
            return window?.makeFirstResponder(last) == true
                ? .handled : .notHandled
        default:
            return super.handleEvent(event)
        }
    }
}

extension View {
    /// Lazily produce a menu for a secondary click.
    public var contextMenuProvider: (@MainActor () -> Menu)? {
        get { storedContextMenuProvider }
        set { storedContextMenuProvider = newValue }
    }
}
