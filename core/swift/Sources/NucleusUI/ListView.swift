/// A vertically scrolling list, materializing only the rows on screen.
///
/// Virtualization lives here rather than in `ScrollView` for the reason AppKit
/// puts it in `NSTableView`: it needs to know the content is a list of rows. A
/// scroll view virtualizing an arbitrary document would have to guess at its
/// structure.
///
/// Rows may be uniform or measured. Uniform is the arithmetic path and stays
/// free; measured costs one prefix-sum pass and a binary search per lookup.
///
/// Rows are recycled. A list of ten thousand entries holds as many views as fit
/// on screen plus a small overscan, which is what makes the launcher and the
/// notification history affordable.
@MainActor
open class ListView: ScrollView {
    /// Make a fresh, unconfigured row view. Called only when the pool is empty.
    public var makeRow: (() -> View)?

    /// Configure a recycled or new row for `index`.
    public var configureRow: ((View, Int) -> Void)?

    /// Called when a row is clicked.
    public var onSelectRow: ((Int) -> Void)?

    public private(set) var rowCount: Int = 0

    public var rowHeight: Double = 28 {
        didSet {
            guard rowHeight != oldValue, rowHeight > 0 else { return }
            invalidateRowHeights()
        }
    }

    /// A per-row height. `nil` means every row is `rowHeight`.
    ///
    /// Setting this costs a prefix-sum pass over every row, so a list that does
    /// not need it keeps the arithmetic path: with uniform rows an index is a
    /// division, and a list of ten thousand rows needs no array at all.
    public var rowHeightProvider: ((Int) -> Double)? {
        didSet { invalidateRowHeights() }
    }

    /// A stable identity for the item at an index.
    ///
    /// Without it, a row view belongs to a *position*: inserting at the top
    /// reconfigures every visible row, and anything a row was holding — a
    /// pressed state, a caret, an in-flight animation — moves to whatever item
    /// slid into that slot. With it, a view follows its item and is only
    /// reconfigured when the item behind it actually changes.
    public var rowKey: ((Int) -> AnyHashable)?

    /// Cumulative row offsets, `rowCount + 1` entries, built only when heights
    /// vary. `nil` is the uniform case.
    private var rowOffsets: [Double]?

    /// Views retired this pass, held by item identity so a row that merely moved
    /// keeps its view instead of being rebuilt from the pool.
    private var keyedRows: [AnyHashable: View] = [:]
    private var rowKeysByIndex: [Int: AnyHashable] = [:]

    /// Rows kept beyond each edge of the visible range, so a scroll does not
    /// expose an unfilled row before layout catches up.
    public var overscan: Int = 2

    private let document = View()
    /// Live rows by index, and the pool of views not currently placed.
    private var activeRows: [Int: View] = [:]
    private var reusePool: [View] = []
    /// The range currently materialized, to skip the work when it has not moved.
    private var materializedRange: Range<Int> = 0..<0

    public override init() {
        super.init()
        documentView = document
        onScroll = { [weak self] _ in self?.updateVisibleRows() }
    }

    /// Set the number of rows and rebuild. Every visible row is reconfigured,
    /// because the data behind an index may have changed even where the count
    /// did not.
    public func setRowCount(_ count: Int) {
        rowCount = max(0, count)
        rebuildRowOffsets()
        resizeDocument()
        recycleAll()
        clampScrollPosition()
        updateVisibleRows()
    }

    /// Re-measure every row. Call when a row's height changes without its count
    /// doing — a label that grew a line, a disclosure that opened.
    public func invalidateRowHeights() {
        rebuildRowOffsets()
        resizeDocument()
        clampScrollPosition()
        materializedRange = 0..<0
        setNeedsLayout()
        updateVisibleRows()
    }

    // MARK: - Geometry

    private func rebuildRowOffsets() {
        guard let provider = rowHeightProvider, rowCount > 0 else {
            rowOffsets = nil
            return
        }
        var offsets = [Double](repeating: 0, count: rowCount + 1)
        var total: Double = 0
        for index in 0..<rowCount {
            // A non-positive height would make the row unhittable and break the
            // search's assumption that offsets increase.
            total += max(0, provider(index))
            offsets[index + 1] = total
        }
        rowOffsets = offsets
    }

    /// The top of a row, in document coordinates.
    public func offset(forRow index: Int) -> Double {
        guard let offsets = rowOffsets else { return Double(index) * rowHeight }
        guard index >= 0 else { return 0 }
        guard index < offsets.count else { return offsets.last ?? 0 }
        return offsets[index]
    }

    public func height(forRow index: Int) -> Double {
        guard let offsets = rowOffsets else { return rowHeight }
        guard index >= 0, index + 1 < offsets.count else { return 0 }
        return offsets[index + 1] - offsets[index]
    }

    /// The height of every row together.
    public var contentHeight: Double {
        if let offsets = rowOffsets { return offsets.last ?? 0 }
        return Double(rowCount) * rowHeight
    }

    /// The row containing a document-space y, by binary search when heights
    /// vary. Linear scanning here would make scrolling cost the list's length.
    private func rowIndex(atDocumentY y: Double) -> Int? {
        guard rowCount > 0 else { return nil }
        guard let offsets = rowOffsets else {
            guard rowHeight > 0 else { return nil }
            let index = Int((y / rowHeight).rounded(.down))
            return (index >= 0 && index < rowCount) ? index : nil
        }
        guard y >= 0, y < (offsets.last ?? 0) else { return nil }

        var low = 0
        var high = rowCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Reconfigure the rows on screen without disturbing the scroll position.
    /// The cheap update for "the data changed, the shape did not".
    public func reloadVisibleRows() {
        for (index, row) in activeRows {
            configureRow?(row, index)
        }
    }

    private func resizeDocument() {
        document.frame = Rect(
            x: 0, y: 0,
            width: clipView.frame.size.width,
            height: contentHeight)
    }

    open override func layout() {
        super.layout()
        // The document is as wide as the clip view: a list scrolls vertically,
        // and a row narrower or wider than the view would be a layout bug rather
        // than a horizontal scroll.
        if document.frame.size.width != clipView.frame.size.width {
            resizeDocument()
        }
        updateVisibleRows()
    }

    /// The rows the current offset actually needs.
    public func visibleRowRange() -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let height = clipView.frame.size.height
        guard height > 0 else { return 0..<0 }

        guard rowOffsets != nil else {
            guard rowHeight > 0 else { return 0..<0 }
            let first = Int((contentOffset.y / rowHeight).rounded(.down)) - overscan
            let visibleCount = Int((height / rowHeight).rounded(.up)) + overscan * 2 + 1
            let start = max(0, first)
            let end = min(rowCount, start + visibleCount)
            return start..<max(start, end)
        }

        // Variable heights: find the row at each edge rather than dividing.
        let top = max(0, contentOffset.y)
        let bottom = contentOffset.y + height
        let firstVisible = rowIndex(atDocumentY: top) ?? 0
        let lastVisible = rowIndex(atDocumentY: min(bottom, max(0, contentHeight - 1)))
            ?? (rowCount - 1)

        let start = max(0, firstVisible - overscan)
        let end = min(rowCount, lastVisible + overscan + 1)
        return start..<max(start, end)
    }

    private func updateVisibleRows() {
        let wanted = visibleRowRange()
        guard wanted != materializedRange else { return }
        materializedRange = wanted

        // Retire rows that scrolled out, into the pool rather than out of
        // existence: allocating a view per scrolled row is the cost this class
        // exists to avoid.
        for (index, row) in activeRows where !wanted.contains(index) {
            row.removeFromSuperview()
            activeRows[index] = nil
            if let key = rowKeysByIndex.removeValue(forKey: index), rowKey != nil {
                keyedRows[key] = row
            } else {
                reusePool.append(row)
            }
        }

        for index in wanted where activeRows[index] == nil {
            let key = rowKey?(index)
            // A view already showing this item is reused as it stands: it is
            // already configured, and reconfiguring would discard whatever the
            // row was holding.
            let recycled = key.flatMap { keyedRows.removeValue(forKey: $0) }
            let row = recycled ?? dequeueRow()
            row.frame = Rect(
                x: 0, y: offset(forRow: index),
                width: document.frame.size.width, height: height(forRow: index))
            if recycled == nil {
                configureRow?(row, index)
            }
            document.addSubview(row)
            activeRows[index] = row
            rowKeysByIndex[index] = key
        }

        // Anything not claimed by identity this pass goes back to the plain
        // pool; holding it by key forever would be a leak keyed on stale items.
        for (_, row) in keyedRows { reusePool.append(row) }
        keyedRows.removeAll(keepingCapacity: true)
    }

    private func dequeueRow() -> View {
        if let recycled = reusePool.popLast() { return recycled }
        return makeRow?() ?? View()
    }

    private func recycleAll() {
        for (index, row) in activeRows {
            row.removeFromSuperview()
            // Keep identity across a reload: the same item usually survives a
            // row-count change, and that is exactly when a view should follow
            // its item rather than its position.
            if let key = rowKeysByIndex[index], rowKey != nil {
                keyedRows[key] = row
            } else {
                reusePool.append(row)
            }
        }
        activeRows.removeAll()
        rowKeysByIndex.removeAll()
        materializedRange = 0..<0
    }

    /// The row index at a point in this view's coordinates, or `nil` past the
    /// end. Used by hit handling and available to callers doing their own.
    public func rowIndex(at point: Point) -> Int? {
        rowIndex(atDocumentY: point.y + contentOffset.y)
    }

    /// Rows are display, not targets: a click on one lands on the list.
    ///
    /// Mirrors `NSTableView`, where the table owns the click and the row is
    /// something it drew. It also has to be this way — an event that climbed the
    /// responder chain from a row would arrive carrying the *row's* coordinates,
    /// and `rowIndex(at:)` would read a point in the wrong space and select the
    /// wrong row.
    ///
    /// A `Control` inside a row is the exception, and keeps the hit: a row with a
    /// button in it must still have a working button.
    open override func hitTest(_ point: Point) -> View? {
        guard let hit = super.hitTest(point) else { return nil }
        guard hit !== self else { return self }

        var node: View? = hit
        while let current = node, current !== self {
            if current is Control { return hit }
            node = current.parentView
        }
        return self
    }

    open override func handleEvent(_ event: Event) -> EventHandling {
        if event.type == .pointerDown, let index = rowIndex(at: event.location) {
            onSelectRow?(index)
            return .handled
        }
        return super.handleEvent(event)
    }

    /// Scroll `index` into view by the minimum distance.
    public func scrollRowToVisible(_ index: Int) {
        guard index >= 0, index < rowCount else { return }
        scrollToVisible(Rect(
            x: 0, y: offset(forRow: index),
            width: document.frame.size.width, height: height(forRow: index)))
    }

    /// Rows currently materialized. Exposed so a test can assert that a list of
    /// ten thousand rows holds a handful of views.
    public var materializedRowCount: Int { activeRows.count }

    /// The view showing `index`, if that row is on screen.
    ///
    /// Only materialized rows have views — a list of ten thousand rows has a
    /// handful — so this is nil for anything scrolled away.
    public func rowView(at index: Int) -> View? { activeRows[index] }
}
