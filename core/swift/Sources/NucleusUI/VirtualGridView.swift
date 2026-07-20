public enum VirtualGridColumns: Sendable, Equatable {
    /// Exactly `count` equal-width columns.
    case fixed(count: Int)
    /// As many equal-width columns as fit without becoming narrower than
    /// `minimumWidth`.
    case adaptive(minimumWidth: Double, maximumCount: Int? = nil)
}

public enum VirtualGridCellSizing: Sendable, Equatable {
    case square
    /// Width divided by height.
    case aspectRatio(Double)
    case fixedHeight(Double)
}

/// A row-major virtualized grid sharing list snapshot, revision, selection,
/// focus, and retained recycling contracts.
@MainActor
open class VirtualGridView: ScrollView {
    public var makeCell: (() -> View)?
    public var configureCell: ((View, CollectionItem, Int) -> Void)?
    public var updateCellState: ((View, CollectionItemState) -> Void)?
    public var onSelectionChange: ((Set<CollectionItemID>) -> Void)?
    public var onActivateItem: ((CollectionItem, Int) -> Void)?
    public var accessibilityItemProperties:
        ((CollectionItem, Int) -> AccessibilityProperties)?
    {
        didSet { recordMutation(.accessibility) }
    }

    public private(set) var snapshot: CollectionSnapshot = .empty
    public var itemCount: Int { snapshot.items.count }

    public var columns: VirtualGridColumns = .adaptive(minimumWidth: 120) {
        didSet {
            guard columns != oldValue else { return }
            invalidateGridGeometry()
        }
    }
    public var cellSizing: VirtualGridCellSizing = .square {
        didSet {
            guard cellSizing != oldValue else { return }
            invalidateGridGeometry()
        }
    }

    private var storedRowGap: Double = 0
    public var rowGap: Double {
        get { storedRowGap }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedRowGap else { return }
            storedRowGap = value
            invalidateGridGeometry()
        }
    }

    private var storedColumnGap: Double = 0
    public var columnGap: Double {
        get { storedColumnGap }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedColumnGap else { return }
            storedColumnGap = value
            invalidateGridGeometry()
        }
    }

    public var overscanRows: Int = 1 {
        didSet {
            let value = max(0, overscanRows)
            if value != overscanRows {
                overscanRows = value
            } else if value != oldValue {
                reconcileVisibleCells(forceGeometry: true)
            }
        }
    }

    public var selectionMode: CollectionSelectionMode = .single {
        didSet {
            guard selectionMode != oldValue else { return }
            setSelectedItemIDs(selectedItemIDs)
        }
    }
    public private(set) var selectedItemIDs: Set<CollectionItemID> = []
    public private(set) var focusedItemID: CollectionItemID?
    private var selectionAnchorID: CollectionItemID?

    private struct CellBinding {
        var item: CollectionItem
        var index: Int
        var view: View
    }

    private struct Geometry: Equatable {
        var columnCount: Int
        var cellWidth: Double
        var cellHeight: Double
        var rowCount: Int

        static let empty = Geometry(
            columnCount: 1,
            cellWidth: 0,
            cellHeight: 0,
            rowCount: 0)
    }

    private let document = View()
    private var geometry: Geometry = .empty
    private var activeCells: [Int: CellBinding] = [:]
    private var reusePool: [View] = []
    private var materializedRange: Range<Int> = 0..<0
    private var accessibilityIDs:
        [CollectionItemID: AccessibilityID] = [:]

    public override init() {
        super.init()
        documentView = document
        onScroll = { [weak self] _ in
            self?.reconcileVisibleCells(forceGeometry: false)
        }
        isAccessibilityElement = true
        accessibilityRole = .grid
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityElements() ?? []
        }
    }

    open override var acceptsFirstResponder: Bool { true }

    public func applySnapshot(_ newSnapshot: CollectionSnapshot) {
        guard newSnapshot != snapshot else { return }
        let old = snapshot
        let oldFocusedIndex = focusedItemID.flatMap { id in
            old.items.firstIndex { $0.id == id }
        }
        snapshot = newSnapshot
        reconcileAccessibilityIDs()
        updateGeometry()
        clampScrollPosition()
        reconcileSelection(previousFocusedIndex: oldFocusedIndex)
        reconcileVisibleCells(forceGeometry: true)
        setNeedsLayout()
        recordMutation(.accessibility)
    }

    public func reloadVisibleCells() {
        for index in activeCells.keys.sorted() {
            guard let binding = activeCells[index] else { continue }
            configureCell?(binding.view, binding.item, binding.index)
            updateState(for: binding)
        }
    }

    private func invalidateGridGeometry() {
        updateGeometry()
        clampScrollPosition()
        reconcileVisibleCells(forceGeometry: true)
        setNeedsLayout()
    }

    open override func layout() {
        super.layout()
        updateGeometry()
        clampScrollPosition()
        reconcileVisibleCells(forceGeometry: true)
    }

    private func updateGeometry() {
        let width = max(0, clipView.frame.size.width)
        let count: Int
        switch columns {
        case .fixed(let proposed):
            count = max(1, proposed)
        case .adaptive(let proposedMinimum, let proposedMaximum):
            let minimum = proposedMinimum.isFinite
                ? max(1, proposedMinimum)
                : 1
            let fitting = max(
                1,
                Int(((width + columnGap) / (minimum + columnGap))
                    .rounded(.down)))
            count = min(fitting, max(1, proposedMaximum ?? fitting))
        }

        let gaps = columnGap * Double(max(0, count - 1))
        let cellWidth = max(0, (width - gaps) / Double(count))
        let cellHeight: Double
        switch cellSizing {
        case .square:
            cellHeight = cellWidth
        case .aspectRatio(let proposed):
            let ratio = proposed.isFinite && proposed > 0 ? proposed : 1
            cellHeight = cellWidth / ratio
        case .fixedHeight(let proposed):
            cellHeight = proposed.isFinite ? max(0, proposed) : 0
        }
        let rows = itemCount == 0 ? 0 : (itemCount + count - 1) / count
        let next = Geometry(
            columnCount: count,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            rowCount: rows)
        guard next != geometry
            || document.frame.size.width != width
        else { return }
        geometry = next
        document.frame = Rect(
            x: 0,
            y: 0,
            width: width,
            height: Double(rows) * cellHeight
                + Double(max(0, rows - 1)) * rowGap)
    }

    public var resolvedColumnCount: Int { geometry.columnCount }
    public var resolvedCellSize: Size {
        Size(width: geometry.cellWidth, height: geometry.cellHeight)
    }

    public func frameForItem(at index: Int) -> Rect? {
        guard snapshot.items.indices.contains(index) else { return nil }
        let row = index / geometry.columnCount
        let column = index % geometry.columnCount
        return Rect(
            x: Double(column) * (geometry.cellWidth + columnGap),
            y: Double(row) * (geometry.cellHeight + rowGap),
            width: geometry.cellWidth,
            height: geometry.cellHeight)
    }

    public func visibleItemRange() -> Range<Int> {
        guard itemCount > 0,
              clipView.frame.size.height > 0,
              geometry.cellHeight > 0
        else { return 0..<0 }
        let rowStride = geometry.cellHeight + rowGap
        let firstVisibleRow = min(
            geometry.rowCount - 1,
            max(0, Int((contentOffset.y / rowStride).rounded(.down))))
        let bottom = contentOffset.y + clipView.frame.size.height
        let lastVisibleRow = min(
            geometry.rowCount - 1,
            max(firstVisibleRow, Int((bottom / rowStride).rounded(.down))))
        let firstRow = max(0, firstVisibleRow - overscanRows)
        let lastRow = min(
            geometry.rowCount - 1,
            lastVisibleRow + overscanRows)
        let start = firstRow * geometry.columnCount
        let end = min(itemCount, (lastRow + 1) * geometry.columnCount)
        return start..<max(start, end)
    }

    private func reconcileVisibleCells(forceGeometry: Bool) {
        let wanted = visibleItemRange()
        let identitiesMatch = wanted == materializedRange
            && wanted.allSatisfy { index in
                activeCells[index]?.item == snapshot.items[index]
            }
        guard forceGeometry || !identitiesMatch else { return }
        materializedRange = wanted

        var available: [CollectionItemID: CellBinding] = [:]
        for binding in activeCells.values {
            available[binding.item.id] = binding
        }
        let wantedIDs = Set(wanted.map { snapshot.items[$0].id })
        for id in Array(available.keys) where !wantedIDs.contains(id) {
            guard let binding = available.removeValue(forKey: id) else {
                continue
            }
            binding.view.isHidden = true
            reusePool.append(binding.view)
        }

        var next: [Int: CellBinding] = [:]
        for index in wanted {
            let item = snapshot.items[index]
            if var binding = available.removeValue(forKey: item.id) {
                let revisionChanged = binding.item.revision != item.revision
                binding.item = item
                binding.index = index
                binding.view.isHidden = false
                if let frame = frameForItem(at: index) {
                    binding.view.frame = frame
                }
                if revisionChanged {
                    configureCell?(binding.view, item, index)
                }
                updateState(for: binding)
                next[index] = binding
            } else {
                let cell = dequeueCell()
                cell.isHidden = false
                if let frame = frameForItem(at: index) {
                    cell.frame = frame
                }
                configureCell?(cell, item, index)
                let binding = CellBinding(item: item, index: index, view: cell)
                updateState(for: binding)
                next[index] = binding
            }
        }
        for binding in available.values {
            binding.view.isHidden = true
            reusePool.append(binding.view)
        }
        activeCells = next
    }

    private func dequeueCell() -> View {
        if let cell = reusePool.popLast() { return cell }
        let cell = makeCell?() ?? View()
        document.addSubview(cell)
        return cell
    }

    public func itemIndex(at point: Point) -> Int? {
        guard geometry.cellWidth > 0, geometry.cellHeight > 0 else {
            return nil
        }
        let documentPoint = Point(
            x: point.x + contentOffset.x,
            y: point.y + contentOffset.y)
        guard documentPoint.x >= 0, documentPoint.y >= 0 else { return nil }
        let columnStride = geometry.cellWidth + columnGap
        let rowStride = geometry.cellHeight + rowGap
        let column = Int((documentPoint.x / columnStride).rounded(.down))
        let row = Int((documentPoint.y / rowStride).rounded(.down))
        guard column >= 0, column < geometry.columnCount,
              row >= 0, row < geometry.rowCount
        else { return nil }
        let localX = documentPoint.x - Double(column) * columnStride
        let localY = documentPoint.y - Double(row) * rowStride
        guard localX < geometry.cellWidth, localY < geometry.cellHeight else {
            return nil
        }
        let index = row * geometry.columnCount + column
        return index < itemCount ? index : nil
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
            normalized = snapshot.items.first(where: {
                requested.contains($0.id)
            }).map { [$0.id] } ?? []
        case .multiple:
            normalized = requested
        }
        setSelection(normalized)
    }

    private func reconcileSelection(previousFocusedIndex: Int?) {
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
            let index = min(previousFocusedIndex ?? 0, snapshot.items.count - 1)
            focusedItemID = snapshot.items[index].id
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
                var result = selectedItemIDs
                if !result.insert(id).inserted { result.remove(id) }
                setSelection(result)
            } else {
                selectionAnchorID = id
                setSelection([id])
            }
        }
        updateAllVisibleStates()
    }

    private func setSelection(_ value: Set<CollectionItemID>) {
        guard value != selectedItemIDs else { return }
        selectedItemIDs = value
        updateAllVisibleStates()
        recordMutation(.accessibility)
        onSelectionChange?(value)
    }

    private func updateState(for binding: CellBinding) {
        updateCellState?(
            binding.view,
            CollectionItemState(
                isSelected: selectedItemIDs.contains(binding.item.id),
                isFocused: focusedItemID == binding.item.id))
    }

    private func updateAllVisibleStates() {
        for binding in activeCells.values { updateState(for: binding) }
    }

    private func moveFocus(by delta: Int, extending: Bool) {
        guard !snapshot.items.isEmpty else { return }
        let current = focusedItemID.flatMap { id in
            snapshot.items.firstIndex { $0.id == id }
        } ?? 0
        let target = min(max(0, current + delta), snapshot.items.count - 1)
        select(index: target, extending: extending, toggling: false)
        scrollItemToVisible(target)
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
            guard let id = accessibilityIDs[item.id],
                  let itemFrame = frameForItem(at: index)
            else { return nil }
            var properties = accessibilityItemProperties?(item, index)
                ?? AccessibilityProperties(
                    isElement: true,
                    label: "Item \(index + 1)",
                    role: .gridCell)
            properties.isElement = true
            properties.role = properties.role ?? .gridCell
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
                    x: clipView.frame.origin.x + itemFrame.origin.x,
                    y: clipView.frame.origin.y + itemFrame.origin.y
                        - contentOffset.y,
                    width: itemFrame.size.width,
                    height: itemFrame.size.height),
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
                    self.scrollItemToVisible(current)
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

    open override func hitTest(_ point: Point) -> View? {
        guard let hit = super.hitTest(point) else { return nil }
        guard hit !== self else { return self }
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
            if let index = itemIndex(at: event.location) {
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
            case .leftArrow:
                moveFocus(by: -1, extending: extending)
                return .handled
            case .rightArrow:
                moveFocus(by: 1, extending: extending)
                return .handled
            case .upArrow:
                moveFocus(by: -geometry.columnCount, extending: extending)
                return .handled
            case .downArrow:
                moveFocus(by: geometry.columnCount, extending: extending)
                return .handled
            case .home:
                if !snapshot.items.isEmpty {
                    select(index: 0, extending: extending, toggling: false)
                    scrollItemToVisible(0)
                }
                return .handled
            case .end:
                if !snapshot.items.isEmpty {
                    let last = snapshot.items.count - 1
                    select(index: last, extending: extending, toggling: false)
                    scrollItemToVisible(last)
                }
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

    public func scrollItemToVisible(_ index: Int) {
        guard let frame = frameForItem(at: index) else { return }
        scrollToVisible(frame)
    }

    public func scrollSelectionToVisible() {
        guard let focusedItemID,
              let index = snapshot.items.firstIndex(where: {
                  $0.id == focusedItemID
              })
        else { return }
        scrollItemToVisible(index)
    }

    public var materializedCellCount: Int { activeCells.count }

    public func cellView(at index: Int) -> View? {
        activeCells[index]?.view
    }

    public func cellView(forItemID id: CollectionItemID) -> View? {
        activeCells.values.first(where: { $0.item.id == id })?.view
    }

    public func cellView(
        forItemID id: some Hashable & Sendable
    ) -> View? {
        cellView(forItemID: CollectionItemID(id))
    }
}
