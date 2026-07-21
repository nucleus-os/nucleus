public struct RadioOption: Hashable, Sendable {
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
public final class RadioGroup: Control, ~Sendable {
    public var options: [RadioOption] {
        didSet {
            guard options != oldValue else { return }
            precondition(
                Set(options.map(\.id)).count == options.count,
                "radio option identities must be unique")
            if let selectedID,
               !options.contains(where: { $0.id == selectedID })
            {
                self.selectedID = nil
            }
            reconcileAccessibilityIDs()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
            recordMutation(.accessibility)
        }
    }

    public var selectedID: CollectionItemID? {
        didSet {
            guard selectedID != oldValue else { return }
            if let selectedID {
                precondition(
                    options.contains { $0.id == selectedID },
                    "selected radio identity must exist")
            }
            isSelected = selectedID != nil
            accessibilityValue = selectedOption?.title
            recordMutation(.accessibility)
            onSelectionChange?(selectedID)
            setNeedsDisplay()
        }
    }

    public var selectedOption: RadioOption? {
        selectedID.flatMap { id in options.first { $0.id == id } }
    }

    private var pressedIndex: Int?
    private var onSelectionChange: ((CollectionItemID?) -> Void)?
    private var accessibilityIDs:
        [CollectionItemID: AccessibilityID] = [:]
    private static let rowHeight = 28.0

    public init(options: [RadioOption] = []) {
        self.options = options
        precondition(
            Set(options.map(\.id)).count == options.count,
            "radio option identities must be unique")
        super.init()
        accessibilityRole = .radioGroup
        reconcileAccessibilityIDs()
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityElements() ?? []
        }
    }

    public func onChange(
        _ handler: @escaping (CollectionItemID?) -> Void
    ) {
        onSelectionChange = handler
    }

    public override var intrinsicContentSize: Size {
        let width = options.map { option in
            TextLayout(
                text: option.title,
                font: Font.systemFont(ofSize: 14)
                    .scaled(by: uiContext.environment.textScale),
                textSystem: uiContext.services.textSystem
            ).intrinsicSize.width + 32
        }.max() ?? 0
        return Size(
            width: width,
            height: Double(options.count) * RadioGroup.rowHeight)
    }

    public override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union(.textScale)
    }

    public override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if changes.contains(.textScale) {
            invalidateIntrinsicContentSize()
        }
        super.environmentDidChange(changes)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        if event.type == .pointerDown {
            pressedIndex = optionIndex(at: event.location)
        }
        if event.type == .keyDown {
            switch event.keyCode {
            case .upArrow, .leftArrow:
                moveSelection(by: -1)
                return .handled
            case .downArrow, .rightArrow:
                moveSelection(by: 1)
                return .handled
            default:
                break
            }
        }
        let result = super.handleEvent(event)
        if event.type == .pointerCancelled || event.type == .touchCancelled {
            pressedIndex = nil
        }
        return result
    }

    public override func performPrimaryAction(
        event: Event
    ) -> EventHandling {
        let index = pressedIndex ?? selectedIndex ?? firstEnabledIndex
        pressedIndex = nil
        guard let index, options[index].isEnabled else { return .handled }
        selectedID = options[index].id
        _ = super.performPrimaryAction(event: event)
        return .handled
    }

    public override func draw(in context: GraphicsContext) {
        for index in options.indices {
            let center = Point(
                x: 10,
                y: Double(index) * RadioGroup.rowHeight
                    + RadioGroup.rowHeight / 2)
            var ring = Path()
            ring.addEllipse(in: Rect(
                x: center.x - 7,
                y: center.y - 7,
                width: 14,
                height: 14))
            context.strokeColor = resolve(.role(.outline))
            context.lineWidth = 1.5
            context.stroke(ring)
            if selectedID == options[index].id {
                var dot = Path()
                dot.addEllipse(in: Rect(
                    x: center.x - 4,
                    y: center.y - 4,
                    width: 8,
                    height: 8))
                context.fillColor = resolve(.role(.primary))
                context.fill(dot)
            }
            let layout = TextLayout(
                text: options[index].title,
                font: Font.systemFont(ofSize: 14)
                    .scaled(by: uiContext.environment.textScale),
                textSystem: uiContext.services.textSystem)
            context.alpha = options[index].isEnabled ? 1 : 0.45
            context.draw(layout, in: Rect(
                x: 24,
                y: Double(index) * RadioGroup.rowHeight
                    + (RadioGroup.rowHeight - layout.intrinsicSize.height) / 2,
                width: max(0, bounds.size.width - 24),
                height: layout.intrinsicSize.height))
            context.alpha = 1
        }
    }

    private var selectedIndex: Int? {
        selectedID.flatMap { id in options.firstIndex { $0.id == id } }
    }

    private var firstEnabledIndex: Int? {
        options.firstIndex(where: \.isEnabled)
    }

    private func optionIndex(at point: Point) -> Int? {
        guard point.y >= 0 else { return nil }
        let index = Int((point.y / RadioGroup.rowHeight).rounded(.down))
        return options.indices.contains(index) ? index : nil
    }

    private func moveSelection(by delta: Int) {
        guard !options.isEmpty else { return }
        var index = selectedIndex ?? (delta > 0 ? -1 : options.count)
        for _ in options.indices {
            index = min(max(0, index + delta), options.count - 1)
            if options[index].isEnabled {
                selectedID = options[index].id
                return
            }
            if index == 0 || index == options.count - 1 { return }
        }
    }

    private func reconcileAccessibilityIDs() {
        let valid = Set(options.map(\.id))
        accessibilityIDs = accessibilityIDs.filter {
            valid.contains($0.key)
        }
        for option in options where accessibilityIDs[option.id] == nil {
            accessibilityIDs[option.id] =
                uiContext.allocateAccessibilityID()
        }
    }

    private func accessibilityElements()
        -> [AccessibilityVirtualElement]
    {
        options.enumerated().compactMap { index, option in
            guard let id = accessibilityIDs[option.id] else { return nil }
            var traits: AccessibilityTraits = []
            if !option.isEnabled { traits.insert(.disabled) }
            if option.id == selectedID {
                traits.formUnion([.selected, .checked])
            }
            return AccessibilityVirtualElement(
                id: id,
                properties: AccessibilityProperties(
                    isElement: true,
                    label: option.title,
                    role: .radioButton,
                    traits: traits),
                frame: Rect(
                    x: 0,
                    y: Double(index) * RadioGroup.rowHeight,
                    width: bounds.size.width,
                    height: RadioGroup.rowHeight),
                actions: option.isEnabled ? [.focus, .select, .press] : []
            ) { [weak self] request in
                guard let self,
                      let current = self.options.firstIndex(
                        where: { $0.id == option.id }),
                      self.options[current].isEnabled
                else { return false }
                switch request.action {
                case .focus:
                    _ = self.window?.makeFirstResponder(self)
                    self.selectedID = option.id
                    return true
                case .select, .press:
                    self.selectedID = option.id
                    return true
                default:
                    return false
                }
            }
        }
    }
}
