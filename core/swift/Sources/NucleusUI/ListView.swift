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

    /// Text used only for keyboard type-ahead. Content configuration remains
    /// independent from navigation metadata.
    public var itemSearchText: ((CollectionItem) -> String?)?

    public private(set) var snapshot: CollectionSnapshot = .empty
    public private(set) var snapshotGeneration: UInt64 = 1
    public var rowCount: Int { snapshot.items.count }

    public var selectionMode: CollectionSelectionMode = .single {
        didSet {
            guard selectionMode != oldValue else { return }
            normalizeSelection()
        }
    }
    public private(set) var selectedItemIDs: Set<CollectionItemID> = []
    public private(set) var focusedItemID: CollectionItemID?

    public var reordering: CollectionReorderingConfiguration? {
        didSet { configureReorderingLifecycle() }
    }

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

    /// Measures an item under the row's current width constraint. `nil`
    /// selects the allocation-free uniform-height path.
    public var measureRow: ((CollectionItem, Double) -> Double)? {
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

    private struct ScrollAnchor {
        var itemID: CollectionItemID
        var previousIndex: Int
        var offsetInsideItem: Double
    }

    private struct MeasurementContext: Equatable {
        var width: Double
        var environmentGeneration: UInt64
        var backingScaleBits: UInt32
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
    private var measurementCache =
        CollectionMeasurementCache(capacity: 2_048)
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
            self.reconcileVisibleRows(forceGeometry: false)
        }
        isAccessibilityElement = true
        accessibilityRole = .list
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
        invalidateMeasuredGeometry()
        super.environmentDidChange(changes)
    }

    open override func viewDidChangeBackingScaleFactor() {
        invalidateMeasuredGeometry()
        super.viewDidChangeBackingScaleFactor()
    }

    /// Apply one validated state. Duplicate identity is rejected when the
    /// snapshot is constructed, before it can corrupt view or selection maps.
    public func applySnapshot(_ newSnapshot: CollectionSnapshot) {
        guard newSnapshot != snapshot else { return }
        typeAheadTask?.cancel()
        typeAheadTask = nil
        typeAhead = ""
        let oldSnapshot = snapshot
        let anchor = captureScrollAnchor()
        let firstChanged = firstLayoutChange(
            from: oldSnapshot,
            to: newSnapshot)
        let oldFocusedIndex = focusedItemID.flatMap { id in
            oldSnapshot.items.firstIndex { $0.id == id }
        }

        snapshot = newSnapshot
        advanceSnapshotGeneration()
        reconcileItemTokens()
        reconcileAccessibilityIDs()
        rebuildRowOffsets(from: firstChanged)
        resizeDocument()
        restoreScrollAnchor(anchor)
        reconcileSelectionAfterSnapshot(
            previousFocusedIndex: oldFocusedIndex)
        reconcileVisibleRows(forceGeometry: true)
        refreshAccessibleDragSource()
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
        measurementCache.removeAll()
        invalidateMeasuredGeometry()
    }

    private func invalidateMeasuredGeometry() {
        let anchor = captureScrollAnchor()
        rebuildRowOffsets(from: 0)
        resizeDocument()
        restoreScrollAnchor(anchor)
        reconcileVisibleRows(forceGeometry: true)
        setNeedsLayout()
        recordMutation(.accessibility)
    }

    // MARK: - Geometry

    private var measurementContext: MeasurementContext {
        MeasurementContext(
            width: max(0, clipView.frame.size.width),
            environmentGeneration: uiContext.environmentGeneration,
            backingScaleBits:
                (window?.surfaceAssociation?.transform.backingScaleFactor.value
                    ?? 1).bitPattern)
    }

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

    private func rebuildRowOffsets(from proposedStart: Int) {
        let context = measurementContext
        defer { lastMeasurementContext = context }
        guard let measureRow, rowCount > 0 else {
            rowOffsets = nil
            return
        }

        let contextChanged = lastMeasurementContext != context
        let start = contextChanged ? 0 : min(max(0, proposedStart), rowCount)
        let oldOffsets = rowOffsets
        var offsets = [Double](repeating: 0, count: rowCount + 1)
        if start > 0,
           let oldOffsets,
           oldOffsets.count > start
        {
            for index in 0...start {
                offsets[index] = oldOffsets[index]
            }
        }

        var total = offsets[start]
        for index in start..<rowCount {
            let item = snapshot.items[index]
            let key = CollectionMeasurementCache.Key(
                itemID: item.id,
                revision: item.revision,
                width: context.width,
                environmentGeneration: context.environmentGeneration,
                backingScaleBits: context.backingScaleBits)
            total += measurementCache.value(for: key) {
                measureRow(item, context.width)
            }
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
        let anchor = captureScrollAnchor()
        super.layout()
        if lastMeasurementContext != measurementContext {
            rebuildRowOffsets(from: 0)
        }
        if document.frame.size.width != clipView.frame.size.width
            || document.frame.size.height != contentHeight
        {
            resizeDocument()
            restoreScrollAnchor(anchor)
        }
        reconcileVisibleRows(forceGeometry: true)
    }

    public func visibleRowRange() -> Range<Int> {
        guard rowCount > 0, clipView.frame.size.height > 0 else {
            return 0..<0
        }

        if rowOffsets == nil {
            let first =
                Int((contentOffset.y / rowHeight).rounded(.down)) - overscan
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

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let index = rowIndex(atDocumentY: contentOffset.y),
              snapshot.items.indices.contains(index)
        else { return nil }
        return ScrollAnchor(
            itemID: snapshot.items[index].id,
            previousIndex: index,
            offsetInsideItem: contentOffset.y - offset(forRow: index))
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, !snapshot.items.isEmpty else {
            clampScrollPosition()
            return
        }
        let index = snapshot.items.firstIndex {
            $0.id == anchor.itemID
        } ?? min(anchor.previousIndex, snapshot.items.count - 1)
        let inside = min(
            max(0, anchor.offsetInsideItem),
            max(0, height(forRow: index).nextDown))
        isReconcilingGeometry = true
        contentOffset = Point(
            x: contentOffset.x,
            y: offset(forRow: index) + inside)
        isReconcilingGeometry = false
        clampScrollPosition()
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
            precondition(
                availableByID.updateValue(binding, forKey: binding.item.id)
                    == nil,
                "one materialized view is allowed per item identity")
        }
        let wantedIDs = Set(wanted.map { snapshot.items[$0].id })
        for id in Array(availableByID.keys) where !wantedIDs.contains(id) {
            guard let binding = availableByID.removeValue(forKey: id) else {
                continue
            }
            recycle(binding.view)
        }
        var nextActive: [Int: RowBinding] = [:]
        nextActive.reserveCapacity(wanted.count)

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
                let binding = RowBinding(
                    item: item,
                    index: index,
                    view: row)
                updateState(for: binding)
                nextActive[index] = binding
            }
        }

        for binding in availableByID.values {
            recycle(binding.view)
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

    private func recycle(_ row: View) {
        row.isHidden = true
        let limit = max(16, materializedRange.count + overscan * 2)
        if reusePool.count < limit {
            reusePool.append(row)
        } else {
            row.removeFromSuperview()
        }
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
        refreshAccessibleDragSource()
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
            scrollRowToVisible(index)
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
            if reordering != nil { actions.insert(.startDrag) }
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

    public func rowIndex(at point: Point) -> Int? {
        rowIndex(atDocumentY: point.y + contentOffset.y)
    }

    open override func hitTest(_ point: Point) -> View? {
        guard let hit = super.hitTest(point) else { return nil }
        guard hit !== self else { return self }
        // Indicators and controls embedded in a row remain interactive.
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
            if let index = rowIndex(at: event.location) {
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
                if handleTypeAhead(event) { return .handled }
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

    // MARK: - Reordering

    private func advanceSnapshotGeneration() {
        snapshotGeneration &+= 1
        precondition(
            snapshotGeneration != 0,
            "list snapshot generation exhausted")
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
            precondition(nextItemToken != 0, "list item token exhausted")
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
        let y = min(max(0, point.y + contentOffset.y), contentHeight)
        guard let row = rowIndex(atDocumentY: y) else {
            return y <= 0 ? 0 : rowCount
        }
        return y < offset(forRow: row) + height(forRow: row) / 2
            ? row
            : row + 1
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
        let y = offset(forRow: min(max(0, insertion), rowCount))
        preview.frame = Rect(
            x: 0,
            y: max(0, y - 1),
            width: document.frame.size.width,
            height: 2)
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

    public var materializedRowCount: Int { activeRows.count }
    public var reusePoolCount: Int { reusePool.count }
    public var measurementCacheEntryCount: Int {
        measurementCache.count
    }

    package var hasVisibleInsertionPreview: Bool {
        insertionPreview?.isHidden == false
    }

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
