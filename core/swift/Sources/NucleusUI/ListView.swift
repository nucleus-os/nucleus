/// A vertically scrolling, stable-identity virtualized collection.
///
/// Only rows intersecting the viewport plus `overscan` are materialized.
/// Snapshot identity, not index, owns a retained row while it remains visible
/// across insertions, removals, and moves.
@MainActor
open class ListView: ScrollView {
    public var makeRow: (() -> View)?
    public var configureRow: ((View, CollectionItem, Int) -> Void)?
    public var updateRowState: ((View, CollectionItemState) -> Void)?
    public var onSelectionChange: ((Set<CollectionItemID>) -> Void)?
    public var onActivateItem: ((CollectionItem, Int) -> Void)?
    public var accessibilityItemProperties:
        ((CollectionItem, Int) -> AccessibilityProperties)?
    {
        didSet { recordMutation(.accessibility) }
    }

    public private(set) var snapshot: CollectionSnapshot = .empty
    public var rowCount: Int { snapshot.items.count }

    public var selectionMode: CollectionSelectionMode = .single {
        didSet {
            guard selectionMode != oldValue else { return }
            normalizeSelection()
        }
    }
    public private(set) var selectedItemIDs: Set<CollectionItemID> = []
    public private(set) var focusedItemID: CollectionItemID?

    private var selectionAnchorID: CollectionItemID?

    private var storedRowHeight: Double = 28
    public var rowHeight: Double {
        get { storedRowHeight }
        set {
            let value = newValue.isFinite && newValue > 0 ? newValue : 28
            guard value != storedRowHeight else { return }
            storedRowHeight = value
            invalidateRowHeights()
        }
    }

    /// A per-item height. `nil` selects the allocation-free uniform-height path.
    public var rowHeightProvider: ((CollectionItem, Int) -> Double)? {
        didSet { invalidateRowHeights() }
    }

    /// Rows retained beyond each viewport edge.
    public var overscan: Int = 2 {
        didSet {
            let canonical = max(0, overscan)
            if canonical != overscan {
                overscan = canonical
            } else if overscan != oldValue {
                reconcileVisibleRows(forceGeometry: true)
            }
        }
    }

    private struct RowBinding {
        var item: CollectionItem
        var index: Int
        var view: View
    }

    private let document = View()
    private var rowOffsets: [Double]?
    private var activeRows: [Int: RowBinding] = [:]
    /// Pooled rows remain hidden children of `document`; reuse never destroys
    /// and recreates their visual layers.
    private var reusePool: [View] = []
    private var materializedRange: Range<Int> = 0..<0
    private var accessibilityIDs:
        [CollectionItemID: AccessibilityID] = [:]

    public override init() {
        super.init()
        documentView = document
        onScroll = { [weak self] _ in
            self?.reconcileVisibleRows(forceGeometry: false)
        }
        isAccessibilityElement = true
        accessibilityRole = .list
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityElements() ?? []
        }
    }

    open override var acceptsFirstResponder: Bool { true }

    /// Apply one validated state. Duplicate identity is rejected when the
    /// snapshot is constructed, before it can corrupt view or selection maps.
    public func applySnapshot(_ newSnapshot: CollectionSnapshot) {
        guard newSnapshot != snapshot else { return }
        let oldSnapshot = snapshot
        let oldFocusedIndex = focusedItemID.flatMap { id in
            oldSnapshot.items.firstIndex { $0.id == id }
        }
        snapshot = newSnapshot
        reconcileAccessibilityIDs()
        rebuildRowOffsets()
        resizeDocument()
        clampScrollPosition()
        reconcileSelectionAfterSnapshot(previousFocusedIndex: oldFocusedIndex)
        reconcileVisibleRows(forceGeometry: true)
        setNeedsLayout()
        recordMutation(.accessibility)
    }

    /// Explicitly reconfigure materialized content without changing revisions.
    public func reloadVisibleRows() {
        for index in activeRows.keys.sorted() {
            guard let binding = activeRows[index] else { continue }
            configureRow?(binding.view, binding.item, binding.index)
            updateState(for: binding)
        }
    }

    public func invalidateRowHeights() {
        rebuildRowOffsets()
        resizeDocument()
        clampScrollPosition()
        reconcileVisibleRows(forceGeometry: true)
        setNeedsLayout()
        recordMutation(.accessibility)
    }

    // MARK: - Geometry

    private func rebuildRowOffsets() {
        guard let provider = rowHeightProvider, rowCount > 0 else {
            rowOffsets = nil
            return
        }
        var offsets = [Double](repeating: 0, count: rowCount + 1)
        var total: Double = 0
        for index in snapshot.items.indices {
            let proposed = provider(snapshot.items[index], index)
            total += proposed.isFinite ? max(0, proposed) : 0
            offsets[index + 1] = total
        }
        rowOffsets = offsets
    }

    public func offset(forRow index: Int) -> Double {
        guard let offsets = rowOffsets else {
            return Double(max(0, index)) * rowHeight
        }
        guard index >= 0 else { return 0 }
        guard index < offsets.count else { return offsets.last ?? 0 }
        return offsets[index]
    }

    public func height(forRow index: Int) -> Double {
        guard let offsets = rowOffsets else {
            return index >= 0 && index < rowCount ? rowHeight : 0
        }
        guard index >= 0, index + 1 < offsets.count else { return 0 }
        return offsets[index + 1] - offsets[index]
    }

    public var contentHeight: Double {
        rowOffsets?.last ?? Double(rowCount) * rowHeight
    }

    private func rowIndex(atDocumentY y: Double) -> Int? {
        guard rowCount > 0, y >= 0, y < contentHeight else { return nil }
        guard let offsets = rowOffsets else {
            return min(rowCount - 1, Int((y / rowHeight).rounded(.down)))
        }

        var low = 0
        var high = rowCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y {
                low = middle
            } else {
                high = middle - 1
            }
        }
        // Zero-height rows at the same offset are skipped in favour of the
        // first subsequent row that actually contains the point.
        while low + 1 < rowCount, offsets[low + 1] <= y {
            low += 1
        }
        return height(forRow: low) > 0 ? low : nil
    }

    private func resizeDocument() {
        document.frame = Rect(
            x: 0,
            y: 0,
            width: clipView.frame.size.width,
            height: contentHeight)
    }

    open override func layout() {
        super.layout()
        if document.frame.size.width != clipView.frame.size.width {
            resizeDocument()
        }
        reconcileVisibleRows(forceGeometry: true)
    }

    public func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, clipView.frame.size.height > 0 else { return 0..<0 }

        if rowOffsets == nil {
            let first = Int((contentOffset.y / rowHeight).rounded(.down)) - overscan
            let visibleCount = Int(
                (clipView.frame.size.height / rowHeight).rounded(.up))
                + overscan * 2 + 1
            let start = max(0, first)
            let end = min(rowCount, start + visibleCount)
            return start..<max(start, end)
        }

        let top = max(0, contentOffset.y)
        let bottom = min(
            max(0, contentHeight.nextDown),
            contentOffset.y + clipView.frame.size.height)
        let first = rowIndex(atDocumentY: top) ?? 0
        let last = rowIndex(atDocumentY: bottom) ?? max(0, rowCount - 1)
        let start = max(0, first - overscan)
        let end = min(rowCount, last + overscan + 1)
        return start..<max(start, end)
    }

    private func reconcileVisibleRows(forceGeometry: Bool) {
        let wanted = visibleRowRange()
        let identitiesMatch = wanted == materializedRange
            && wanted.allSatisfy { index in
                activeRows[index]?.item == snapshot.items[index]
            }
        guard forceGeometry || !identitiesMatch else { return }
        materializedRange = wanted

        var availableByID: [CollectionItemID: RowBinding] = [:]
        for binding in activeRows.values {
            availableByID[binding.item.id] = binding
        }
        let wantedIDs = Set(wanted.map { snapshot.items[$0].id })
        for id in Array(availableByID.keys) where !wantedIDs.contains(id) {
            guard let binding = availableByID.removeValue(forKey: id) else {
                continue
            }
            binding.view.isHidden = true
            reusePool.append(binding.view)
        }
        var nextActive: [Int: RowBinding] = [:]

        for index in wanted {
            let item = snapshot.items[index]
            if var binding = availableByID.removeValue(forKey: item.id) {
                let revisionChanged = binding.item.revision != item.revision
                binding.item = item
                binding.index = index
                binding.view.isHidden = false
                place(binding.view, at: index)
                if revisionChanged {
                    configureRow?(binding.view, item, index)
                }
                updateState(for: binding)
                nextActive[index] = binding
            } else {
                let row = dequeueRow()
                row.isHidden = false
                place(row, at: index)
                configureRow?(row, item, index)
                let binding = RowBinding(item: item, index: index, view: row)
                updateState(for: binding)
                nextActive[index] = binding
            }
        }

        for binding in availableByID.values {
            binding.view.isHidden = true
            reusePool.append(binding.view)
        }
        activeRows = nextActive
    }

    private func place(_ row: View, at index: Int) {
        row.frame = Rect(
            x: 0,
            y: offset(forRow: index),
            width: document.frame.size.width,
            height: height(forRow: index))
    }

    private func dequeueRow() -> View {
        if let recycled = reusePool.popLast() { return recycled }
        let row = makeRow?() ?? View()
        document.addSubview(row)
        return row
    }

    // MARK: - Selection and focus

    public func setSelectedItemIDs(_ ids: Set<CollectionItemID>) {
        let valid = Set(snapshot.items.map(\.id))
        let requested = ids.intersection(valid)
        let normalized: Set<CollectionItemID>
        switch selectionMode {
        case .none:
            normalized = []
        case .single:
            if let focusedItemID, requested.contains(focusedItemID) {
                normalized = [focusedItemID]
            } else if let first = snapshot.items.first(where: {
                requested.contains($0.id)
            }) {
                normalized = [first.id]
            } else {
                normalized = []
            }
        case .multiple:
            normalized = requested
        }
        setSelection(normalized)
    }

    public func selectItem(
        id: CollectionItemID,
        extendingSelection: Bool = false
    ) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == id })
        else { return }
        select(index: index, extending: extendingSelection, toggling: false)
    }

    public func scrollSelectionToVisible() {
        guard let focusedItemID,
              let index = snapshot.items.firstIndex(where: {
                  $0.id == focusedItemID
              })
        else { return }
        scrollRowToVisible(index)
    }

    private func normalizeSelection() {
        setSelectedItemIDs(selectedItemIDs)
    }

    private func reconcileSelectionAfterSnapshot(
        previousFocusedIndex: Int?
    ) {
        let valid = Set(snapshot.items.map(\.id))
        setSelectedItemIDs(selectedItemIDs.intersection(valid))
        if let focusedItemID, valid.contains(focusedItemID) {
            updateAllVisibleStates()
            return
        }
        if snapshot.items.isEmpty {
            focusedItemID = nil
            selectionAnchorID = nil
        } else {
            let index = min(
                previousFocusedIndex ?? 0,
                snapshot.items.count - 1)
            focusedItemID = snapshot.items[index].id
            if selectionAnchorID.map({ !valid.contains($0) }) == true {
                selectionAnchorID = focusedItemID
            }
        }
        updateAllVisibleStates()
    }

    private func select(
        index: Int,
        extending: Bool,
        toggling: Bool
    ) {
        guard snapshot.items.indices.contains(index) else { return }
        let id = snapshot.items[index].id
        focusedItemID = id

        switch selectionMode {
        case .none:
            setSelection([])
        case .single:
            selectionAnchorID = id
            setSelection([id])
        case .multiple:
            if extending,
               let anchor = selectionAnchorID,
               let anchorIndex = snapshot.items.firstIndex(where: {
                   $0.id == anchor
               })
            {
                let range = min(anchorIndex, index)...max(anchorIndex, index)
                setSelection(Set(range.map { snapshot.items[$0].id }))
            } else if toggling {
                selectionAnchorID = id
                var selection = selectedItemIDs
                if !selection.insert(id).inserted {
                    selection.remove(id)
                }
                setSelection(selection)
            } else {
                selectionAnchorID = id
                setSelection([id])
            }
        }
        updateAllVisibleStates()
    }

    private func setSelection(_ selection: Set<CollectionItemID>) {
        guard selection != selectedItemIDs else { return }
        selectedItemIDs = selection
        updateAllVisibleStates()
        recordMutation(.accessibility)
        onSelectionChange?(selection)
    }

    private func updateState(for binding: RowBinding) {
        updateRowState?(
            binding.view,
            CollectionItemState(
                isSelected: selectedItemIDs.contains(binding.item.id),
                isFocused: focusedItemID == binding.item.id))
    }

    private func updateAllVisibleStates() {
        for binding in activeRows.values {
            updateState(for: binding)
        }
    }

    private func moveFocus(by delta: Int, extending: Bool) {
        guard !snapshot.items.isEmpty else { return }
        let current = focusedItemID.flatMap { id in
            snapshot.items.firstIndex { $0.id == id }
        } ?? (delta > 0 ? -1 : snapshot.items.count)
        let target = min(max(0, current + delta), snapshot.items.count - 1)
        select(index: target, extending: extending, toggling: false)
        scrollRowToVisible(target)
    }

    private func reconcileAccessibilityIDs() {
        let valid = Set(snapshot.items.map(\.id))
        accessibilityIDs = accessibilityIDs.filter {
            valid.contains($0.key)
        }
        for item in snapshot.items where accessibilityIDs[item.id] == nil {
            accessibilityIDs[item.id] = uiContext.allocateAccessibilityID()
        }
    }

    private func accessibilityElements()
        -> [AccessibilityVirtualElement]
    {
        snapshot.items.enumerated().compactMap { index, item in
            guard let id = accessibilityIDs[item.id] else { return nil }
            var properties = accessibilityItemProperties?(item, index)
                ?? AccessibilityProperties(
                    isElement: true,
                    label: "Item \(index + 1)",
                    role: .listItem)
            properties.isElement = true
            properties.role = properties.role ?? .listItem
            if selectedItemIDs.contains(item.id) {
                properties.traits.insert(.selected)
            } else {
                properties.traits.remove(.selected)
            }
            var actions: Set<AccessibilityAction> = [.focus]
            if selectionMode != .none { actions.insert(.select) }
            if onActivateItem != nil { actions.insert(.press) }
            return AccessibilityVirtualElement(
                id: id,
                properties: properties,
                frame: Rect(
                    x: clipView.frame.origin.x,
                    y: clipView.frame.origin.y
                        + offset(forRow: index) - contentOffset.y,
                    width: clipView.frame.size.width,
                    height: height(forRow: index)),
                actions: actions
            ) { [weak self] request in
                guard let self,
                      let current = self.snapshot.items.firstIndex(
                        where: { $0.id == item.id })
                else { return false }
                switch request.action {
                case .focus:
                    self.focusedItemID = item.id
                    self.updateAllVisibleStates()
                    self.recordMutation(.accessibility)
                    self.scrollRowToVisible(current)
                    _ = self.window?.makeFirstResponder(self)
                    return true
                case .select:
                    self.select(
                        index: current,
                        extending: false,
                        toggling: false)
                    return true
                case .press:
                    guard let onActivateItem = self.onActivateItem else {
                        return false
                    }
                    onActivateItem(self.snapshot.items[current], current)
                    return true
                default:
                    return false
                }
            }
        }
    }

    // MARK: - Input

    public func rowIndex(at point: Point) -> Int? {
        rowIndex(atDocumentY: point.y + contentOffset.y)
    }

    open override func hitTest(_ point: Point) -> View? {
        guard let hit = super.hitTest(point) else { return nil }
        guard hit !== self else { return self }
        // Indicators and controls embedded in a row remain interactive.
        if hit === verticalScrollIndicator || hit === horizontalScrollIndicator {
            return hit
        }
        var node: View? = hit
        while let current = node, current !== self {
            if current is Control { return hit }
            node = current.parentView
        }
        return self
    }

    open override func handleEvent(_ event: Event) -> EventHandling {
        switch event.type {
        case .pointerDown:
            if let index = rowIndex(at: event.location) {
                _ = window?.makeFirstResponder(self)
                select(
                    index: index,
                    extending: event.modifierFlags.contains(.shift),
                    toggling: event.modifierFlags.contains(.command)
                        || event.modifierFlags.contains(.control))
                if event.clickCount >= 2 {
                    onActivateItem?(snapshot.items[index], index)
                }
                _ = super.handleEvent(event)
                return .handled
            }
        case .keyDown:
            let extending = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case .upArrow:
                moveFocus(by: -1, extending: extending)
                return .handled
            case .downArrow:
                moveFocus(by: 1, extending: extending)
                return .handled
            case .home:
                guard !snapshot.items.isEmpty else { return .handled }
                select(index: 0, extending: extending, toggling: false)
                scrollRowToVisible(0)
                return .handled
            case .end:
                guard !snapshot.items.isEmpty else { return .handled }
                let last = snapshot.items.count - 1
                select(index: last, extending: extending, toggling: false)
                scrollRowToVisible(last)
                return .handled
            case .return, .space:
                guard let focusedItemID,
                      let index = snapshot.items.firstIndex(where: {
                          $0.id == focusedItemID
                      })
                else { return .handled }
                onActivateItem?(snapshot.items[index], index)
                return .handled
            default:
                break
            }
        default:
            break
        }
        return super.handleEvent(event)
    }

    public func scrollRowToVisible(_ index: Int) {
        guard snapshot.items.indices.contains(index) else { return }
        scrollToVisible(Rect(
            x: 0,
            y: offset(forRow: index),
            width: document.frame.size.width,
            height: height(forRow: index)))
    }

    public var materializedRowCount: Int { activeRows.count }

    public func rowView(at index: Int) -> View? {
        activeRows[index]?.view
    }

    public func rowView(forItemID id: CollectionItemID) -> View? {
        activeRows.values.first(where: { $0.item.id == id })?.view
    }

    public func rowView(
        forItemID id: some Hashable & Sendable
    ) -> View? {
        rowView(forItemID: CollectionItemID(id))
    }
}
