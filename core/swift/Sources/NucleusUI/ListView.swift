/// A vertically scrolling list of uniform-height rows, materializing only the
/// rows on screen.
///
/// Virtualization lives here rather than in `ScrollView` for the reason AppKit
/// puts it in `NSTableView`: it needs to know the rows are uniform. A scroll
/// view virtualizing an arbitrary document would have to guess at its structure.
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
            resizeDocument()
            setNeedsLayout()
        }
    }

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
        resizeDocument()
        recycleAll()
        clampScrollPosition()
        updateVisibleRows()
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
            height: Double(rowCount) * rowHeight)
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
        guard rowCount > 0, rowHeight > 0 else { return 0..<0 }
        let height = clipView.frame.size.height
        guard height > 0 else { return 0..<0 }

        let first = Int((contentOffset.y / rowHeight).rounded(.down)) - overscan
        let visibleCount = Int((height / rowHeight).rounded(.up)) + overscan * 2 + 1
        let start = max(0, first)
        let end = min(rowCount, start + visibleCount)
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
            reusePool.append(row)
        }

        for index in wanted where activeRows[index] == nil {
            let row = dequeueRow()
            row.frame = Rect(
                x: 0, y: Double(index) * rowHeight,
                width: document.frame.size.width, height: rowHeight)
            configureRow?(row, index)
            document.addSubview(row)
            activeRows[index] = row
        }
    }

    private func dequeueRow() -> View {
        if let recycled = reusePool.popLast() { return recycled }
        return makeRow?() ?? View()
    }

    private func recycleAll() {
        for (_, row) in activeRows {
            row.removeFromSuperview()
            reusePool.append(row)
        }
        activeRows.removeAll()
        materializedRange = 0..<0
    }

    /// The row index at a point in this view's coordinates, or `nil` past the
    /// end. Used by hit handling and available to callers doing their own.
    public func rowIndex(at point: Point) -> Int? {
        guard rowHeight > 0 else { return nil }
        let documentY = point.y + contentOffset.y
        let index = Int((documentY / rowHeight).rounded(.down))
        guard index >= 0, index < rowCount else { return nil }
        return index
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
            x: 0, y: Double(index) * rowHeight,
            width: document.frame.size.width, height: rowHeight))
    }

    /// Rows currently materialized. Exposed so a test can assert that a list of
    /// ten thousand rows holds a handful of views.
    public var materializedRowCount: Int { activeRows.count }
}
