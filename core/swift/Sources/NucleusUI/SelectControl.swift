public struct SelectOption: Hashable, Sendable {
    public var id: CollectionItemID
    public var title: String
    public var isEnabled: Bool

    public init(
        id: some Hashable & Sendable,
        title: String,
        isEnabled: Bool = true
    ) {
        self.id = CollectionItemID(id)
        self.title = title
        self.isEnabled = isEnabled
    }
}

@MainActor
public final class SelectControl: Button, ~Sendable {
    public var options: [SelectOption] {
        didSet {
            guard options != oldValue else { return }
            precondition(
                Set(options.map(\.id)).count == options.count,
                "select option identities must be unique")
            if let selectedID,
               !options.contains(where: { $0.id == selectedID })
            {
                self.selectedID = nil
            }
            synchronizeTitle()
        }
    }

    public var selectedID: CollectionItemID? {
        didSet {
            guard selectedID != oldValue else { return }
            if let selectedID {
                precondition(
                    options.contains { $0.id == selectedID },
                    "selected option identity must exist")
            }
            synchronizeTitle()
            accessibilityValue = selectedOption?.title
            onSelectionChange?(selectedID)
        }
    }

    public var selectedOption: SelectOption? {
        selectedID.flatMap { id in options.first { $0.id == id } }
    }

    public var placeholder: String = "Select…" {
        didSet { if placeholder != oldValue { synchronizeTitle() } }
    }

    private var onSelectionChange: ((CollectionItemID?) -> Void)?

    public init(options: [SelectOption] = []) {
        self.options = options
        precondition(
            Set(options.map(\.id)).count == options.count,
            "select option identities must be unique")
        super.init(title: "Select…")
        accessibilityRole = .comboBox
        synchronizeTitle()
    }

    public func onChange(
        _ handler: @escaping (CollectionItemID?) -> Void
    ) {
        onSelectionChange = handler
    }

    public override func performPrimaryAction(
        event: Event
    ) -> EventHandling {
        guard let scene = window?.windowScene else {
            selectNextEnabledOption()
            _ = super.performPrimaryAction(event: event)
            return .handled
        }

        let menu = Menu(items: options.map { option in
            MenuItem(
                id: option.id,
                title: option.title,
                isEnabled: option.isEnabled
            ) { [weak self] in
                self?.selectedID = option.id
            }
        })
        let anchorInWindow = convert(bounds, to: nil)
        let anchor = window?.sceneRect(fromWindow: anchorInWindow) ?? .zero
        scene.present(menu, anchor: anchor)
        _ = super.performPrimaryAction(event: event)
        return .handled
    }

    private func synchronizeTitle() {
        title = selectedOption?.title ?? placeholder
    }

    private func selectNextEnabledOption() {
        let enabled = options.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        guard let selectedID,
              let current = enabled.firstIndex(where: {
                  $0.id == selectedID
              })
        else {
            self.selectedID = enabled[0].id
            return
        }
        self.selectedID = enabled[(current + 1) % enabled.count].id
    }
}
