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
/// focus, measurement, and retained recycling contracts.
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
    public var itemSearchText: ((CollectionItem) -> String?)?

    public private(set) var snapshot: CollectionSnapshot = .empty
    public private(set) var snapshotGeneration: UInt64 = 1
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

    /// Measures each cell's height at the resolved equal-column width. A row
    /// advances by its tallest cell; shorter cells keep their own frame.
    public var measureCellHeight:
        ((CollectionItem, Double) -> Double)?
    {
        didSet { invalidateGridGeometry() }
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
    public var reordering: CollectionReorderingConfiguration? {
        didSet { configureReorderingLifecycle() }
    }

    private var selectionAnchorID: CollectionItemID?

    private struct CellBinding {
        var item: CollectionItem
        var index: Int
        var view: View
    }

    private struct Geometry: Equatable {
        var columnCount: Int
        var cellWidth: Double
        var defaultCellHeight: Double
        var rowCount: Int

        static let empty = Geometry(
            columnCount: 1,
            cellWidth: 0,
            defaultCellHeight: 0,
            rowCount: 0)
    }

    private struct MeasurementContext: Equatable {
        var width: Double
        var environmentGeneration: UInt64
        var backingScaleBits: UInt32
        var columns: Int
    }

    private struct ScrollAnchor {
        var itemID: CollectionItemID
        var previousIndex: Int
        var offsetInsideItem: Double
    }

    private enum NavigationDirection {
        case left
        case right
        case up
        case down
    }

    private let document = View()
    private var geometry: Geometry = .empty
    private var cellHeights: [Double]?
    private var rowOffsets: [Double]?
    private var rowHeights: [Double]?
    private var activeCells: [Int: CellBinding] = [:]
    private var reusePool: [View] = []
    private var materializedRange: Range<Int> = 0..<0
    private var accessibilityIDs:
        [CollectionItemID: AccessibilityID] = [:]
    private var measurementCache =
        CollectionMeasurementCache(capacity: 4_096)
    private var lastMeasurementContext: MeasurementContext?
    private var isReconcilingGeometry = false

    private var typeAhead = ""
    private var typeAheadTask: Task<Void, Never>?

    private var itemTokens: [CollectionItemID: UInt64] = [:]
    private var itemIDsByToken: [UInt64: CollectionItemID] = [:]
    private var nextItemToken: UInt64 = 1
    private var acceptedDropGeneration: UInt64?
    private var proposedInsertionIndex: Int?
    private var insertionPreview: CollectionInsertionPreview?

    public override init() {
        super.init()
        scrollableAxes = .vertical
        documentView = document
        onInternalScroll = { [weak self] _ in
            guard let self, !self.isReconcilingGeometry else { return }
            self.reconcileVisibleCells(forceGeometry: false)
        }
        isAccessibilityElement = true
        accessibilityRole = .grid
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityElements() ?? []
        }
    }

    isolated deinit {
        typeAheadTask?.cancel()
    }

    open override var acceptsFirstResponder: Bool { true }

    open override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union([
            .reducedMotion,
            .reducedTransparency,
            .increasedContrast,
            .appearance,
            .textScale,
        ])
    }

    open override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        invalidateGridGeometry()
        super.environmentDidChange(changes)
    }

    open override func viewDidChangeBackingScaleFactor() {
        invalidateGridGeometry()
        super.viewDidChangeBackingScaleFactor()
    }

    public func applySnapshot(_ newSnapshot: CollectionSnapshot) {
        guard newSnapshot != snapshot else { return }
        typeAheadTask?.cancel()
        typeAheadTask = nil
        typeAhead = ""
        let old = snapshot
        let anchor = captureScrollAnchor()
        let firstChanged = firstLayoutChange(from: old, to: newSnapshot)
        let oldFocusedIndex = focusedItemID.flatMap { id in
            old.items.firstIndex { $0.id == id }
        }

        snapshot = newSnapshot
        advanceSnapshotGeneration()
        reconcileItemTokens()
        reconcileAccessibilityIDs()
        updateGeometry(fromItem: firstChanged)
        restoreScrollAnchor(anchor)
        reconcileSelection(previousFocusedIndex: oldFocusedIndex)
        reconcileVisibleCells(forceGeometry: true)
        refreshAccessibleDragSource()
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
        measurementCache.removeAll()
        let anchor = captureScrollAnchor()
        updateGeometry(fromItem: 0)
        restoreScrollAnchor(anchor)
        reconcileVisibleCells(forceGeometry: true)
        setNeedsLayout()
        recordMutation(.accessibility)
    }

    open override func layout() {
        let anchor = captureScrollAnchor()
        super.layout()
        updateGeometry(fromItem: 0)
        restoreScrollAnchor(anchor)
        reconcileVisibleCells(forceGeometry: true)
    }

    // MARK: - Geometry

    private func firstLayoutChange(
        from old: CollectionSnapshot,
        to new: CollectionSnapshot
    ) -> Int {
        let sharedCount = min(old.items.count, new.items.count)
        for index in 0..<sharedCount
        where old.items[index] != new.items[index] {
            return index
        }
        return sharedCount
    }

    private func resolvedGeometry(for width: Double) -> Geometry {
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
        let defaultHeight: Double
        switch cellSizing {
        case .square:
            defaultHeight = cellWidth
        case .aspectRatio(let proposed):
            let ratio = proposed.isFinite && proposed > 0 ? proposed : 1
            defaultHeight = cellWidth / ratio
        case .fixedHeight(let proposed):
            defaultHeight = proposed.isFinite ? max(0, proposed) : 0
        }
        let rows = itemCount == 0 ? 0 : (itemCount + count - 1) / count
        return Geometry(
            columnCount: count,
            cellWidth: cellWidth,
            defaultCellHeight: defaultHeight,
            rowCount: rows)
    }

    private func updateGeometry(fromItem proposedStart: Int) {
        let width = max(0, clipView.frame.size.width)
        let nextGeometry = resolvedGeometry(for: width)
        let context = MeasurementContext(
            width: nextGeometry.cellWidth,
            environmentGeneration: uiContext.environmentGeneration,
            backingScaleBits:
                (window?.surfaceAssociation?.transform.backingScaleFactor.value
                    ?? 1).bitPattern,
            columns: nextGeometry.columnCount)
        let contextChanged = lastMeasurementContext != context
            || geometry.columnCount != nextGeometry.columnCount
        geometry = nextGeometry

        if let measureCellHeight, itemCount > 0 {
            let proposedRow = proposedStart / geometry.columnCount
            let startRow = contextChanged
                ? 0
                : min(max(0, proposedRow), geometry.rowCount)
            let startItem = min(
                itemCount,
                startRow * geometry.columnCount)
            let oldCellHeights = cellHeights
            let oldRowOffsets = rowOffsets
            let oldRowHeights = rowHeights
            var heights = [Double](repeating: 0, count: itemCount)
            var offsets = [Double](
                repeating: 0,
                count: geometry.rowCount + 1)
            var rows = [Double](
                repeating: 0,
                count: geometry.rowCount)

            if startItem > 0, let oldCellHeights {
                for index in 0..<min(startItem, oldCellHeights.count) {
                    heights[index] = oldCellHeights[index]
                }
            }
            if startRow > 0,
               let oldRowOffsets,
               let oldRowHeights,
               oldRowOffsets.count > startRow,
               oldRowHeights.count >= startRow
            {
                for row in 0..<startRow {
                    offsets[row] = oldRowOffsets[row]
                    rows[row] = oldRowHeights[row]
                }
                offsets[startRow] = oldRowOffsets[startRow]
            }

            for index in startItem..<itemCount {
                let item = snapshot.items[index]
                let key = CollectionMeasurementCache.Key(
                    itemID: item.id,
                    revision: item.revision,
                    width: context.width,
                    environmentGeneration: context.environmentGeneration,
                    backingScaleBits: context.backingScaleBits)
                heights[index] = measurementCache.value(for: key) {
                    measureCellHeight(item, context.width)
                }
            }

            var y = offsets[startRow]
            for row in startRow..<geometry.rowCount {
                let lower = row * geometry.columnCount
                let upper = min(itemCount, lower + geometry.columnCount)
                let height = heights[lower..<upper].max() ?? 0
                rows[row] = height
                offsets[row] = y
                y += height
                if row + 1 < geometry.rowCount { y += rowGap }
                offsets[row + 1] = y
            }
            cellHeights = heights
            rowOffsets = offsets
            rowHeights = rows
        } else {
            cellHeights = nil
            rowOffsets = nil
            rowHeights = nil
        }
        lastMeasurementContext = context
        document.frame = Rect(
            x: 0,
            y: 0,
            width: width,
            height: contentHeight)
    }

    public var resolvedColumnCount: Int { geometry.columnCount }
    public var resolvedCellSize: Size {
        Size(
            width: geometry.cellWidth,
            height: geometry.defaultCellHeight)
    }

    public var contentHeight: Double {
        if let rowOffsets { return rowOffsets.last ?? 0 }
        return Double(geometry.rowCount) * geometry.defaultCellHeight
            + Double(max(0, geometry.rowCount - 1)) * rowGap
    }

    private func offset(forRow row: Int) -> Double {
        if let rowOffsets {
            guard row >= 0 else { return 0 }
            return row < rowOffsets.count
                ? rowOffsets[row]
                : rowOffsets.last ?? 0
        }
        return Double(max(0, row))
            * (geometry.defaultCellHeight + rowGap)
    }

    private func height(forGridRow row: Int) -> Double {
        if let rowHeights {
            return rowHeights.indices.contains(row)
                ? rowHeights[row]
                : 0
        }
        return row >= 0 && row < geometry.rowCount
            ? geometry.defaultCellHeight
            : 0
    }

    public func frameForItem(at index: Int) -> Rect? {
        guard snapshot.items.indices.contains(index) else { return nil }
        let row = index / geometry.columnCount
        let column = index % geometry.columnCount
        return Rect(
            x: Double(column) * (geometry.cellWidth + columnGap),
            y: offset(forRow: row),
            width: geometry.cellWidth,
            height: cellHeights?[index] ?? geometry.defaultCellHeight)
    }

    private func rowIndex(atDocumentY y: Double) -> Int? {
        guard geometry.rowCount > 0, y >= 0, y < contentHeight else {
            return nil
        }
        guard let offsets = rowOffsets else {
            let stride = geometry.defaultCellHeight + rowGap
            guard stride > 0 else { return nil }
            let row = min(
                geometry.rowCount - 1,
                Int((y / stride).rounded(.down)))
            return y < offset(forRow: row) + height(forGridRow: row)
                ? row
                : nil
        }
        var low = 0
        var high = geometry.rowCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return y < offsets[low] + height(forGridRow: low) ? low : nil
    }

    private func nearestRow(atDocumentY y: Double) -> Int {
        guard geometry.rowCount > 0 else { return 0 }
        if let row = rowIndex(atDocumentY: y) { return row }
        for row in 0..<geometry.rowCount
        where y <= offset(forRow: row) {
            return row
        }
        return geometry.rowCount - 1
    }

    public func visibleItemRange() -> Range<Int> {
        guard itemCount > 0,
              clipView.frame.size.height > 0,
              contentHeight > 0
        else { return 0..<0 }
        let top = max(0, contentOffset.y)
        let bottom = min(
            contentHeight.nextDown,
            contentOffset.y + clipView.frame.size.height)
        let firstVisibleRow = nearestRow(atDocumentY: top)
        let lastVisibleRow = nearestRow(atDocumentY: bottom)
        let firstRow = max(0, firstVisibleRow - overscanRows)
        let lastRow = min(
            geometry.rowCount - 1,
            lastVisibleRow + overscanRows)
        let start = firstRow * geometry.columnCount
        let end = min(itemCount, (lastRow + 1) * geometry.columnCount)
        return start..<max(start, end)
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard itemCount > 0 else { return nil }
        let row = nearestRow(atDocumentY: contentOffset.y)
        let index = min(itemCount - 1, row * geometry.columnCount)
        guard let frame = frameForItem(at: index) else { return nil }
        return ScrollAnchor(
            itemID: snapshot.items[index].id,
            previousIndex: index,
            offsetInsideItem: max(0, contentOffset.y - frame.origin.y))
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, !snapshot.items.isEmpty else {
            clampScrollPosition()
            return
        }
        let index = snapshot.items.firstIndex {
            $0.id == anchor.itemID
        } ?? min(anchor.previousIndex, snapshot.items.count - 1)
        guard let frame = frameForItem(at: index) else {
            clampScrollPosition()
            return
        }
        isReconcilingGeometry = true
        contentOffset = Point(
            x: contentOffset.x,
            y: frame.origin.y + max(0, anchor.offsetInsideItem))
        isReconcilingGeometry = false
        clampScrollPosition()
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
            precondition(
                available.updateValue(binding, forKey: binding.item.id)
                    == nil,
                "one materialized view is allowed per item identity")
        }
        let wantedIDs = Set(wanted.map { snapshot.items[$0].id })
        for id in Array(available.keys) where !wantedIDs.contains(id) {
            guard let binding = available.removeValue(forKey: id) else {
                continue
            }
            recycle(binding.view)
        }

        var next: [Int: CellBinding] = [:]
        next.reserveCapacity(wanted.count)
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
                let binding = CellBinding(
                    item: item,
                    index: index,
                    view: cell)
                updateState(for: binding)
                next[index] = binding
            }
        }
        for binding in available.values {
            recycle(binding.view)
        }
        activeCells = next
    }

    private func dequeueCell() -> View {
        if let cell = reusePool.popLast() { return cell }
        let cell = makeCell?() ?? View()
        document.addSubview(cell)
        return cell
    }

    private func recycle(_ cell: View) {
        cell.isHidden = true
        let limit = max(
            16,
            materializedRange.count
                + overscanRows * geometry.columnCount * 2)
        if reusePool.count < limit {
            reusePool.append(cell)
        } else {
            cell.removeFromSuperview()
        }
    }

    public func itemIndex(at point: Point) -> Int? {
        guard geometry.cellWidth > 0 else { return nil }
        let documentPoint = Point(
            x: point.x + contentOffset.x,
            y: point.y + contentOffset.y)
        guard documentPoint.x >= 0, documentPoint.y >= 0,
              let row = rowIndex(atDocumentY: documentPoint.y)
        else { return nil }
        let columnStride = geometry.cellWidth + columnGap
        let column = Int((documentPoint.x / columnStride).rounded(.down))
        guard column >= 0, column < geometry.columnCount else { return nil }
        let localX = documentPoint.x - Double(column) * columnStride
        guard localX < geometry.cellWidth else { return nil }
        let index = row * geometry.columnCount + column
        guard index < itemCount,
              let frame = frameForItem(at: index),
              documentPoint.y < frame.origin.y + frame.size.height
        else { return nil }
        return index
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
            } else {
                normalized = snapshot.items.first(where: {
                    requested.contains($0.id)
                }).map { [$0.id] } ?? []
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

    private func reconcileSelection(previousFocusedIndex: Int?) {
        let valid = Set(snapshot.items.map(\.id))
        setSelectedItemIDs(selectedItemIDs.intersection(valid))
        if let focusedItemID, valid.contains(focusedItemID) {
            if selectionAnchorID.map({ !valid.contains($0) }) == true {
                selectionAnchorID = focusedItemID
            }
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
            if selectionAnchorID.map({ !valid.contains($0) }) != false {
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
            selectionAnchorID = id
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
        refreshAccessibleDragSource()
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

    private func moveFocus(
        _ direction: NavigationDirection,
        extending: Bool
    ) {
        guard !snapshot.items.isEmpty else { return }
        let current = focusedItemID.flatMap { id in
            snapshot.items.firstIndex { $0.id == id }
        } ?? 0
        guard let source = frameForItem(at: current) else { return }
        let sourceCenter = Point(
            x: source.origin.x + source.size.width / 2,
            y: source.origin.y + source.size.height / 2)
        var best:
            (index: Int, beamPenalty: Int, primary: Double, secondary: Double)?

        for index in snapshot.items.indices where index != current {
            guard let frame = frameForItem(at: index) else { continue }
            let center = Point(
                x: frame.origin.x + frame.size.width / 2,
                y: frame.origin.y + frame.size.height / 2)
            let primary: Double
            let secondary: Double
            let isInBeam: Bool
            switch direction {
            case .left:
                primary = sourceCenter.x - center.x
                secondary = abs(sourceCenter.y - center.y)
                isInBeam = frame.origin.y
                    < source.origin.y + source.size.height
                    && frame.origin.y + frame.size.height > source.origin.y
            case .right:
                primary = center.x - sourceCenter.x
                secondary = abs(sourceCenter.y - center.y)
                isInBeam = frame.origin.y
                    < source.origin.y + source.size.height
                    && frame.origin.y + frame.size.height > source.origin.y
            case .up:
                primary = sourceCenter.y - center.y
                secondary = abs(sourceCenter.x - center.x)
                isInBeam = frame.origin.x
                    < source.origin.x + source.size.width
                    && frame.origin.x + frame.size.width > source.origin.x
            case .down:
                primary = center.y - sourceCenter.y
                secondary = abs(sourceCenter.x - center.x)
                isInBeam = frame.origin.x
                    < source.origin.x + source.size.width
                    && frame.origin.x + frame.size.width > source.origin.x
            }
            guard primary > 0 else { continue }
            let beamPenalty = isInBeam ? 0 : 1
            if let candidate = best {
                if candidate.beamPenalty < beamPenalty {
                    continue
                }
                if candidate.beamPenalty == beamPenalty,
                   candidate.primary < primary
                    || (candidate.primary == primary
                        && candidate.secondary <= secondary)
                {
                    continue
                }
            }
            best = (index, beamPenalty, primary, secondary)
        }
        guard let target = best?.index else { return }
        select(index: target, extending: extending, toggling: false)
        scrollItemToVisible(target)
    }

    private func handleTypeAhead(_ event: Event) -> Bool {
        guard let itemSearchText,
              let characters = event.characters,
              !characters.isEmpty,
              !characters.allSatisfy(\.isWhitespace),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              !snapshot.items.isEmpty
        else { return false }
        typeAhead += characters.lowercased()
        if !selectTypeAheadMatch(
            prefix: typeAhead,
            text: itemSearchText)
        {
            typeAhead = characters.lowercased()
            guard selectTypeAheadMatch(
                prefix: typeAhead,
                text: itemSearchText)
            else { return false }
        }
        typeAheadTask?.cancel()
        let clock = uiContext.clock
        typeAheadTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.typeAhead = ""
        }
        return true
    }

    private func selectTypeAheadMatch(
        prefix: String,
        text: (CollectionItem) -> String?
    ) -> Bool {
        let start = focusedItemID.flatMap { id in
            snapshot.items.firstIndex { $0.id == id }
        }.map { ($0 + 1) % snapshot.items.count } ?? 0
        for offset in snapshot.items.indices {
            let index = (start + offset) % snapshot.items.count
            guard text(snapshot.items[index])?
                .lowercased().hasPrefix(prefix) == true
            else { continue }
            select(index: index, extending: false, toggling: false)
            scrollItemToVisible(index)
            return true
        }
        return false
    }

    // MARK: - Accessibility

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
            if reordering != nil { actions.insert(.startDrag) }
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
                    self.refreshAccessibleDragSource()
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
                case .startDrag:
                    self.select(
                        index: current,
                        extending: false,
                        toggling: false)
                    self.installDragSource(for: current)
                    guard let scene = self.window?.windowScene else {
                        return false
                    }
                    return scene.beginDrag(
                        from: self,
                        at: scene.dragCenter(of: self)) != nil
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
        if hit === verticalScrollIndicator
            || hit === horizontalScrollIndicator
        {
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
                if event.pointerTool != .finger {
                    installDragSource(for: index)
                }
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
                moveFocus(.left, extending: extending)
                return .handled
            case .rightArrow:
                moveFocus(.right, extending: extending)
                return .handled
            case .upArrow:
                moveFocus(.up, extending: extending)
                return .handled
            case .downArrow:
                moveFocus(.down, extending: extending)
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
                if handleTypeAhead(event) { return .handled }
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

    // MARK: - Reordering

    private func advanceSnapshotGeneration() {
        snapshotGeneration &+= 1
        precondition(
            snapshotGeneration != 0,
            "grid snapshot generation exhausted")
    }

    private func reconcileItemTokens() {
        let valid = Set(snapshot.items.map(\.id))
        itemTokens = itemTokens.filter { valid.contains($0.key) }
        itemIDsByToken = itemIDsByToken.filter {
            valid.contains($0.value)
        }
        for item in snapshot.items where itemTokens[item.id] == nil {
            let token = nextItemToken
            nextItemToken &+= 1
            precondition(nextItemToken != 0, "grid item token exhausted")
            itemTokens[item.id] = token
            itemIDsByToken[token] = item.id
        }
    }

    private func configureReorderingLifecycle() {
        hideInsertionPreview()
        guard reordering != nil else {
            setDragSource(nil)
            setDropDestination(nil)
            insertionPreview?.removeFromSuperview()
            insertionPreview = nil
            recordMutation(.accessibility)
            return
        }
        setDropDestination(DropDestinationConfiguration(
            acceptedContentTypes: [collectionReorderContentType],
            proposal: { [weak self] info in
                self?.reorderProposal(for: info)
            },
            entered: { [weak self] info in
                self?.updateReorderTarget(info)
            },
            updated: { [weak self] info in
                self?.updateReorderTarget(info)
            },
            exited: { [weak self] _ in
                self?.hideInsertionPreview()
            },
            perform: { [weak self] info, payload in
                self?.performReorder(info: info, payload: payload) ?? false
            }))
        refreshAccessibleDragSource()
        recordMutation(.accessibility)
    }

    private func refreshAccessibleDragSource() {
        guard reordering != nil,
              let focusedItemID,
              let index = snapshot.items.firstIndex(where: {
                  $0.id == focusedItemID
              })
        else {
            setDragSource(nil)
            return
        }
        installDragSource(for: index)
    }

    private func installDragSource(for index: Int) {
        guard let reordering,
              snapshot.items.indices.contains(index),
              let token = itemTokens[snapshot.items[index].id]
        else {
            setDragSource(nil)
            return
        }
        let payload = CollectionReorderPayload(
            collectionID: id.rawValue,
            snapshotGeneration: snapshotGeneration,
            itemToken: token,
            sourceIndex: index).data
        setDragSource(DragSourceConfiguration(
            payloadProviders: [
                collectionReorderContentType: { payload }
            ],
            allowedOperations: reordering.allowedOperations,
            maximumPayloadBytes: 32,
            completion: { [weak self] _ in
                guard let self else { return }
                self.hideInsertionPreview()
                self.refreshAccessibleDragSource()
            }))
    }

    private func reorderProposal(
        for info: DragDropInfo
    ) -> DragDropProposal? {
        guard let reordering,
              info.offer.contentTypes.contains(
                collectionReorderContentType),
              info.offer.allowedOperations.contains(
                reordering.preferredOperation)
        else { return nil }
        acceptedDropGeneration = snapshotGeneration
        return DragDropProposal(
            contentType: collectionReorderContentType,
            operation: reordering.preferredOperation)
    }

    private func updateReorderTarget(_ info: DragDropInfo) {
        guard info.proposal != nil else {
            hideInsertionPreview()
            return
        }
        autoscrollForReorder(at: info.location)
        let insertion = insertionIndex(at: info.location)
        proposedInsertionIndex = insertion
        showInsertionPreview(at: insertion)
    }

    private func insertionIndex(at point: Point) -> Int {
        guard itemCount > 0 else { return 0 }
        let documentPoint = Point(
            x: min(max(0, point.x + contentOffset.x), document.frame.size.width),
            y: min(max(0, point.y + contentOffset.y), contentHeight))
        if documentPoint.y >= contentHeight { return itemCount }
        let row = nearestRow(atDocumentY: documentPoint.y)
        let columnStride = geometry.cellWidth + columnGap
        let column = min(
            geometry.columnCount - 1,
            max(0, Int((documentPoint.x / max(1, columnStride)).rounded(.down))))
        let index = min(itemCount - 1, row * geometry.columnCount + column)
        guard let frame = frameForItem(at: index) else { return itemCount }
        if documentPoint.y > frame.origin.y + frame.size.height / 2 {
            return min(itemCount, index + geometry.columnCount)
        }
        return documentPoint.x < frame.origin.x + frame.size.width / 2
            ? index
            : min(itemCount, index + 1)
    }

    private func autoscrollForReorder(at point: Point) {
        let edge = min(32, clipView.frame.size.height / 4)
        guard edge > 0 else { return }
        if point.y < edge {
            contentOffset.y -= 18
        } else if point.y > clipView.frame.size.height - edge {
            contentOffset.y += 18
        }
    }

    private func showInsertionPreview(at insertion: Int) {
        let preview: CollectionInsertionPreview
        if let insertionPreview {
            preview = insertionPreview
        } else {
            preview = CollectionInsertionPreview()
            insertionPreview = preview
            document.addSubview(preview)
        }
        let reference = insertion < itemCount
            ? insertion
            : max(0, itemCount - 1)
        guard let frame = frameForItem(at: reference) else {
            preview.isHidden = true
            return
        }
        let x = insertion < itemCount
            ? frame.origin.x - 1
            : frame.origin.x + frame.size.width - 1
        let row = reference / geometry.columnCount
        preview.frame = Rect(
            x: max(0, x),
            y: offset(forRow: row),
            width: 2,
            height: height(forGridRow: row))
        preview.isHidden = false
    }

    private func hideInsertionPreview() {
        acceptedDropGeneration = nil
        proposedInsertionIndex = nil
        insertionPreview?.isHidden = true
    }

    private func performReorder(
        info: DragDropInfo,
        payload: DragPayload
    ) -> Bool {
        guard let reordering,
              payload.contentType == collectionReorderContentType,
              let record = CollectionReorderPayload(data: payload.data),
              record.collectionID == id.rawValue,
              record.snapshotGeneration == snapshotGeneration,
              acceptedDropGeneration == snapshotGeneration,
              record.sourceIndex <= UInt64(Int.max),
              let itemID = itemIDsByToken[record.itemToken],
              let sourceIndex = snapshot.items.firstIndex(where: {
                  $0.id == itemID
              }),
              sourceIndex == Int(record.sourceIndex),
              let insertionIndex = proposedInsertionIndex,
              let operation = info.proposal?.operation,
              reordering.allowedOperations.contains(operation)
        else {
            hideInsertionPreview()
            return false
        }

        var items = snapshot.items
        switch operation {
        case .move:
            let item = items.remove(at: sourceIndex)
            let destination = insertionIndex > sourceIndex
                ? insertionIndex - 1
                : insertionIndex
            items.insert(item, at: min(max(0, destination), items.count))
        case .copy:
            guard let copy = reordering.copyItem?(items[sourceIndex]) else {
                hideInsertionPreview()
                return false
            }
            items.insert(copy, at: min(max(0, insertionIndex), items.count))
        case .link:
            hideInsertionPreview()
            return false
        }

        guard let next = try? CollectionSnapshot(items: items) else {
            hideInsertionPreview()
            return false
        }
        let result = CollectionReorderResult(
            itemID: itemID,
            sourceIndex: sourceIndex,
            insertionIndex: insertionIndex,
            operation: operation)
        hideInsertionPreview()
        applySnapshot(next)
        reordering.didApply?(snapshot, result)
        return true
    }

    // MARK: - Diagnostics

    public var materializedCellCount: Int { activeCells.count }
    public var reusePoolCount: Int { reusePool.count }
    public var measurementCacheEntryCount: Int {
        measurementCache.count
    }

    package var hasVisibleInsertionPreview: Bool {
        insertionPreview?.isHidden == false
    }

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
