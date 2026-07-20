public struct SegmentOption: Hashable, Sendable {
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
public final class SegmentedControl: Control, ~Sendable {
    public var segments: [SegmentOption] {
        didSet {
            guard segments != oldValue else { return }
            precondition(
                Set(segments.map(\.id)).count == segments.count,
                "segment identities must be unique")
            let valid = Set(segments.map(\.id))
            selectedIDs.formIntersection(valid)
            reconcileAccessibilityIDs()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
            recordMutation(.accessibility)
        }
    }

    public var selectionMode: CollectionSelectionMode = .single {
        didSet {
            guard selectionMode != oldValue else { return }
            setSelectedIDs(selectedIDs)
        }
    }
    public private(set) var selectedIDs: Set<CollectionItemID> = []
    private var pressedIndex: Int?
    private var onSelectionChange: ((Set<CollectionItemID>) -> Void)?
    private var accessibilityIDs:
        [CollectionItemID: AccessibilityID] = [:]

    public init(segments: [SegmentOption] = []) {
        self.segments = segments
        precondition(
            Set(segments.map(\.id)).count == segments.count,
            "segment identities must be unique")
        super.init()
        accessibilityRole = .tabList
        reconcileAccessibilityIDs()
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityElements() ?? []
        }
    }

    public func onChange(
        _ handler: @escaping (Set<CollectionItemID>) -> Void
    ) {
        onSelectionChange = handler
    }

    public func setSelectedIDs(_ ids: Set<CollectionItemID>) {
        let valid = Set(segments.map(\.id))
        let requested = ids.intersection(valid)
        let next: Set<CollectionItemID>
        switch selectionMode {
        case .none:
            next = []
        case .single:
            next = segments.first(where: {
                requested.contains($0.id)
            }).map { [$0.id] } ?? []
        case .multiple:
            next = requested
        }
        guard next != selectedIDs else { return }
        selectedIDs = next
        isSelected = !next.isEmpty
        accessibilityValue = segments
            .filter { next.contains($0.id) }
            .map(\.title)
            .joined(separator: ", ")
        onSelectionChange?(next)
        setNeedsDisplay()
        recordMutation(.accessibility)
    }

    public override var intrinsicContentSize: Size {
        let widths = segments.map {
            TextLayout(
                text: $0.title,
                font: Font.systemFont(ofSize: 14)
                    .scaled(by: uiContext.environment.textScale)
            ).intrinsicSize.width + 24
        }
        return Size(width: widths.reduce(0, +), height: 30)
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
        if event.type == .pointerDown || event.type == .touchDown {
            pressedIndex = segmentIndex(at: event.location)
        }
        if event.type == .keyDown {
            switch event.keyCode {
            case .leftArrow:
                moveSelection(by: -1)
                return .handled
            case .rightArrow:
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
        guard let index = pressedIndex ?? selectedIndex,
              segments[index].isEnabled
        else {
            pressedIndex = nil
            return .handled
        }
        pressedIndex = nil
        let id = segments[index].id
        switch selectionMode {
        case .none:
            break
        case .single:
            setSelectedIDs([id])
        case .multiple:
            var next = selectedIDs
            if !next.insert(id).inserted { next.remove(id) }
            setSelectedIDs(next)
        }
        _ = super.performPrimaryAction(event: event)
        return .handled
    }

    public override func draw(in context: GraphicsContext) {
        guard !segments.isEmpty else { return }
        let segmentWidth = bounds.size.width / Double(segments.count)
        for index in segments.indices {
            let rect = Rect(
                x: Double(index) * segmentWidth,
                y: 0,
                width: segmentWidth,
                height: bounds.size.height)
            var path = Path()
            path.addRoundedRect(rect, radius: 6)
            context.fillColor = resolve(
                selectedIDs.contains(segments[index].id)
                    ? .role(.primary)
                    : .role(.surfaceVariant))
            context.fill(path)
            let text = TextLayout(
                text: segments[index].title,
                font: Font.systemFont(ofSize: 14)
                    .scaled(by: uiContext.environment.textScale))
            context.alpha = segments[index].isEnabled ? 1 : 0.45
            context.draw(text, in: Rect(
                x: rect.origin.x
                    + max(0, (rect.size.width - text.intrinsicSize.width) / 2),
                y: max(0, (rect.size.height - text.intrinsicSize.height) / 2),
                width: min(rect.size.width, text.intrinsicSize.width),
                height: text.intrinsicSize.height))
            context.alpha = 1
        }
    }

    private var selectedIndex: Int? {
        segments.firstIndex { selectedIDs.contains($0.id) }
    }

    private func segmentIndex(at point: Point) -> Int? {
        guard point.x >= 0, !segments.isEmpty, bounds.size.width > 0 else {
            return nil
        }
        let index = Int(
            (point.x / (bounds.size.width / Double(segments.count)))
                .rounded(.down))
        return segments.indices.contains(index) ? index : nil
    }

    private func moveSelection(by delta: Int) {
        guard !segments.isEmpty else { return }
        var index = selectedIndex ?? (delta > 0 ? -1 : segments.count)
        for _ in segments.indices {
            index = min(max(0, index + delta), segments.count - 1)
            if segments[index].isEnabled {
                setSelectedIDs([segments[index].id])
                return
            }
            if index == 0 || index == segments.count - 1 { return }
        }
    }

    private func reconcileAccessibilityIDs() {
        let valid = Set(segments.map(\.id))
        accessibilityIDs = accessibilityIDs.filter {
            valid.contains($0.key)
        }
        for segment in segments where accessibilityIDs[segment.id] == nil {
            accessibilityIDs[segment.id] =
                uiContext.allocateAccessibilityID()
        }
    }

    private func accessibilityElements()
        -> [AccessibilityVirtualElement]
    {
        guard !segments.isEmpty else { return [] }
        let width = bounds.size.width / Double(segments.count)
        return segments.enumerated().compactMap { index, segment in
            guard let id = accessibilityIDs[segment.id] else { return nil }
            var traits: AccessibilityTraits = []
            if !segment.isEnabled { traits.insert(.disabled) }
            if selectedIDs.contains(segment.id) {
                traits.insert(.selected)
            }
            return AccessibilityVirtualElement(
                id: id,
                properties: AccessibilityProperties(
                    isElement: true,
                    label: segment.title,
                    role: .tab,
                    traits: traits),
                frame: Rect(
                    x: Double(index) * width,
                    y: 0,
                    width: width,
                    height: bounds.size.height),
                actions: segment.isEnabled
                    ? [.focus, .select, .press]
                    : []
            ) { [weak self] request in
                guard let self,
                      self.segments.contains(where: {
                        $0.id == segment.id && $0.isEnabled
                      })
                else { return false }
                switch request.action {
                case .focus:
                    _ = self.window?.makeFirstResponder(self)
                    self.setSelectedIDs([segment.id])
                    return true
                case .select, .press:
                    switch self.selectionMode {
                    case .none:
                        return false
                    case .single:
                        self.setSelectedIDs([segment.id])
                    case .multiple:
                        var next = self.selectedIDs
                        if !next.insert(segment.id).inserted {
                            next.remove(segment.id)
                        }
                        self.setSelectedIDs(next)
                    }
                    return true
                default:
                    return false
                }
            }
        }
    }
}
