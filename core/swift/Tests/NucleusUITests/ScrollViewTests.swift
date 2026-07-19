import Testing
import NucleusUI

/// Scrolling, on the bounds-origin model. The scroll position *is* the clip
/// view's bounds origin; nothing else moves.
@MainActor
@Suite struct ScrollViewTests {
    private func makeScrollView(
        viewport: Size = Size(width: 100, height: 100),
        content: Size = Size(width: 100, height: 400)
    ) -> ScrollView {
        let scroll = ScrollView()
        scroll.frame = Rect(origin: .zero, size: viewport)
        let document = View()
        document.frame = Rect(origin: .zero, size: content)
        scroll.documentView = document
        scroll.layoutIfNeeded()
        return scroll
    }

    // MARK: - The position

    /// The scroll position is the clip view's bounds origin, not a separate
    /// field kept in step with one.
    @Test func theOffsetIsTheClipViewsBoundsOrigin() {
        let scroll = makeScrollView()
        scroll.contentOffset = Point(x: 0, y: 50)
        #expect(scroll.clipView.boundsOrigin == Point(x: 0, y: 50))
    }

    /// The document does not move. That is the whole reason the offset lives on
    /// the clip view rather than in the children's frames.
    @Test func scrollingDoesNotMoveTheDocument() {
        let scroll = makeScrollView()
        let document = scroll.documentView!
        let before = document.frame

        scroll.contentOffset = Point(x: 0, y: 120)
        #expect(document.frame == before)
    }

    @Test func theRangeIsContentMinusViewport() {
        let scroll = makeScrollView(
            viewport: Size(width: 100, height: 100),
            content: Size(width: 100, height: 400))
        #expect(scroll.maximumOffset == Point(x: 0, y: 300))
    }

    @Test func contentThatFitsDoesNotScroll() {
        let scroll = makeScrollView(
            viewport: Size(width: 100, height: 100),
            content: Size(width: 100, height: 40))
        #expect(scroll.maximumOffset == Point(x: 0, y: 0))

        scroll.contentOffset = Point(x: 0, y: 50)
        #expect(scroll.contentOffset == .zero, "clamped to nothing")
    }

    @Test func theOffsetIsClampedBothWays() {
        let scroll = makeScrollView()
        scroll.contentOffset = Point(x: 0, y: 5000)
        #expect(scroll.contentOffset.y == 300)

        scroll.contentOffset = Point(x: 0, y: -80)
        #expect(scroll.contentOffset.y == 0)
    }

    /// A document that shrinks while scrolled to its end would otherwise leave
    /// the view showing empty space past the content, with no way back.
    @Test func shrinkingTheDocumentPullsTheOffsetBack() {
        let scroll = makeScrollView()
        scroll.contentOffset = Point(x: 0, y: 300)

        scroll.documentView!.frame = Rect(x: 0, y: 0, width: 100, height: 150)
        scroll.clampScrollPosition()
        #expect(scroll.contentOffset.y == 50, "150 content - 100 viewport")
    }

    @Test func scrollingNotifiesOnlyWhenItMoves() {
        let scroll = makeScrollView()
        var positions: [Point] = []
        scroll.onScroll = { positions.append($0) }

        scroll.contentOffset = Point(x: 0, y: 50)
        scroll.contentOffset = Point(x: 0, y: 50)
        #expect(positions.count == 1, "an identical assignment is not a scroll")

        scroll.contentOffset = Point(x: 0, y: 5000)
        #expect(positions.count == 2)
        #expect(positions.last?.y == 300, "the clamped value is reported")
    }

    // MARK: - The wheel

    /// A discrete wheel reports notches, so the distance a line covers is the
    /// scroll view's to decide.
    @Test func aDiscreteWheelScrollsByLines() {
        let scroll = makeScrollView()
        scroll.lineScrollDistance = 40

        scroll.dispatchEvent(Event(
            type: .scrollWheel, location: Point(x: 10, y: 10), scrollDeltaY: 2))
        #expect(scroll.contentOffset.y == 80)
    }

    /// A trackpad already reports a distance, and must not be multiplied again.
    @Test func aPreciseDeviceScrollsByItsOwnDelta() {
        let scroll = makeScrollView()
        scroll.dispatchEvent(Event(
            type: .scrollWheel, location: Point(x: 10, y: 10),
            scrollDeltaY: 17, hasPreciseScrollingDeltas: true))
        #expect(scroll.contentOffset.y == 17)
    }

    /// A scroll that cannot move is unhandled, so a nested scroll view at its
    /// end passes the wheel to its parent rather than swallowing it.
    @Test func aScrollAtTheEndIsUnhandled() {
        let scroll = makeScrollView()
        scroll.contentOffset = Point(x: 0, y: 300)

        let handled = scroll.dispatchEvent(Event(
            type: .scrollWheel, location: Point(x: 10, y: 10), scrollDeltaY: 5))
        #expect(handled == .notHandled)

        let backwards = scroll.dispatchEvent(Event(
            type: .scrollWheel, location: Point(x: 10, y: 10), scrollDeltaY: -5))
        #expect(backwards == .handled)
    }

    // MARK: - scrollToVisible

    /// The minimum distance, not a recentring: a scroll that recentred on every
    /// step would move content the reader is looking at.
    @Test func scrollToVisibleMovesTheMinimum() {
        let scroll = makeScrollView()

        // Below the viewport: its bottom edge comes to the viewport's bottom.
        #expect(scroll.scrollToVisible(Rect(x: 0, y: 180, width: 100, height: 20)))
        #expect(scroll.contentOffset.y == 100)

        // Already visible: nothing moves.
        #expect(!scroll.scrollToVisible(Rect(x: 0, y: 120, width: 100, height: 20)))
        #expect(scroll.contentOffset.y == 100)

        // Above: its top edge comes to the viewport's top.
        #expect(scroll.scrollToVisible(Rect(x: 0, y: 40, width: 100, height: 20)))
        #expect(scroll.contentOffset.y == 40)
    }

    // MARK: - Indicators

    /// Asserted on the computed rect rather than the recording: a path command
    /// carries its geometry in the payload blob.
    @Test func theIndicatorTracksTheOffset() throws {
        let scroll = makeScrollView()

        let atTop = try #require(scroll.verticalIndicatorRect())
        scroll.contentOffset = Point(x: 0, y: 300)
        let atBottom = try #require(scroll.verticalIndicatorRect())

        #expect(atBottom.origin.y > atTop.origin.y)
        #expect(atBottom.size.height == atTop.size.height, "the thumb keeps its size")
        #expect(atTop.origin.y >= 0)
        #expect(atBottom.origin.y + atBottom.size.height <= 100)
    }

    /// Nothing to scroll, nothing to indicate.
    @Test func thereIsNoIndicatorWhenTheContentFits() {
        let scroll = makeScrollView(
            viewport: Size(width: 100, height: 100),
            content: Size(width: 100, height: 50))
        #expect(scroll.verticalIndicatorRect() == nil)
    }

    /// A longer document gets a shorter thumb, which is what makes the thumb
    /// a length indicator rather than decoration.
    @Test func theThumbShrinksAsTheDocumentGrows() throws {
        let shortDoc = makeScrollView(content: Size(width: 100, height: 200))
        let longDoc = makeScrollView(content: Size(width: 100, height: 2000))

        let short = try #require(shortDoc.verticalIndicatorRect())
        let long = try #require(longDoc.verticalIndicatorRect())
        #expect(long.size.height < short.size.height)
    }

    @Test func horizontalIndicatorsAreOptIn() {
        let scroll = makeScrollView(
            viewport: Size(width: 100, height: 100),
            content: Size(width: 400, height: 400))
        #expect(scroll.horizontalIndicatorRect() == nil, "vertical only by default")

        scroll.indicators = .both
        #expect(scroll.horizontalIndicatorRect() != nil)
    }
}

/// The virtualized list. Rows are recycled, which is what makes a list of ten
/// thousand entries affordable.
@MainActor
@Suite struct ListViewTests {
    private func makeList(
        rows: Int, height: Double = 200
    ) -> (ListView, () -> Int) {
        var built = 0
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: height)
        list.rowHeight = 20
        list.makeRow = {
            built += 1
            return View()
        }
        list.layoutIfNeeded()
        list.setRowCount(rows)
        return (list, { built })
    }

    /// The point of the class: ten thousand rows, a handful of views.
    @Test func onlyVisibleRowsAreMaterialized() {
        let (list, built) = makeList(rows: 10_000)
        #expect(list.rowCount == 10_000)
        // 200pt viewport / 20pt rows = 10, plus overscan either side.
        #expect(list.materializedRowCount < 20)
        #expect(built() < 20, "and only that many were ever built")
    }

    /// Scrolling reuses views instead of allocating per row scrolled past.
    @Test func scrollingRecyclesRatherThanAllocates() {
        let (list, built) = makeList(rows: 10_000)
        let afterFirstFill = built()

        list.contentOffset = Point(x: 0, y: 5_000)
        list.contentOffset = Point(x: 0, y: 50_000)
        #expect(built() == afterFirstFill, "no new views for scrolled-past rows")
        #expect(list.materializedRowCount < 20)
    }

    @Test func theDocumentIsAsTallAsAllRows() {
        let (list, _) = makeList(rows: 100)
        #expect(list.contentSize.height == 2_000)
        #expect(list.maximumOffset.y == 1_800)
    }

    @Test func rowsAreConfiguredWithTheirIndex() {
        let (list, _) = makeList(rows: 50)
        var configured: [Int] = []
        list.configureRow = { _, index in configured.append(index) }
        list.reloadVisibleRows()

        #expect(!configured.isEmpty)
        #expect(configured.allSatisfy { $0 >= 0 && $0 < 50 })
    }

    /// The visible range follows the offset, which is what tells the list which
    /// rows to build.
    @Test func theVisibleRangeFollowsTheOffset() {
        let (list, _) = makeList(rows: 1_000)
        let atTop = list.visibleRowRange()
        #expect(atTop.lowerBound == 0)

        list.contentOffset = Point(x: 0, y: 400)
        let scrolled = list.visibleRowRange()
        #expect(scrolled.lowerBound > atTop.lowerBound)
        // 400 / 20 = row 20, less the overscan.
        #expect(scrolled.contains(20))
    }

    /// The range never runs past the data, however far the offset is pushed.
    @Test func theRangeStaysWithinTheRowCount() {
        let (list, _) = makeList(rows: 12)
        list.contentOffset = Point(x: 0, y: 100_000)
        let range = list.visibleRowRange()
        #expect(range.lowerBound >= 0)
        #expect(range.upperBound <= 12)
    }

    @Test func anEmptyListMaterializesNothing() {
        let (list, built) = makeList(rows: 0)
        #expect(list.visibleRowRange().isEmpty)
        #expect(list.materializedRowCount == 0)
        #expect(built() == 0)
    }

    /// Row hit testing accounts for the scroll, which is the bounds-origin model
    /// showing up in a place that would silently select the wrong row.
    @Test func rowHitTestingAccountsForScrolling() {
        let (list, _) = makeList(rows: 1_000)
        #expect(list.rowIndex(at: Point(x: 5, y: 10)) == 0)

        list.contentOffset = Point(x: 0, y: 400)
        #expect(list.rowIndex(at: Point(x: 5, y: 10)) == 20,
                "the row now under that point")
    }

    @Test func selectingReportsTheRowUnderThePointer() {
        let (list, _) = makeList(rows: 1_000)
        var selected: Int?
        list.onSelectRow = { selected = $0 }

        list.contentOffset = Point(x: 0, y: 400)
        list.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 30)))
        #expect(selected == 21)
    }

    @Test func scrollingARowIntoViewMovesTheMinimum() {
        let (list, _) = makeList(rows: 1_000)
        list.scrollRowToVisible(20)
        // Row 20 spans 400..<420; the viewport is 200 tall, so its bottom edge
        // lands at the viewport's bottom.
        #expect(list.contentOffset.y == 220)

        // Row 15 spans 300..<320 and the viewport now shows 220..<420, so it is
        // already visible and nothing moves.
        list.scrollRowToVisible(15)
        #expect(list.contentOffset.y == 220)

        // Row 5 spans 100..<120, above the viewport: its top edge comes to the
        // viewport's top.
        list.scrollRowToVisible(5)
        #expect(list.contentOffset.y == 100)
    }

    /// A row is display, not a target — but a control inside one must still
    /// work.
    @Test func aControlInsideARowKeepsTheClick() {
        // Built from scratch rather than via `makeList`: rows are recycled, so a
        // `makeRow` installed after rows already exist would never be called —
        // the pool would hand back the plain views it already had.
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        list.rowHeight = 20
        list.layoutIfNeeded()

        var rowSelections = 0
        var buttonPresses = 0
        list.onSelectRow = { _ in rowSelections += 1 }

        // A button per row — one shared instance would be re-parented by each
        // `addSubview` and end up in the last row only.
        list.makeRow = {
            let row = View()
            let button = Control()
            button.frame = Rect(x: 0, y: 0, width: 40, height: 20)
            button.onPrimaryAction { _ in buttonPresses += 1 }
            row.addSubview(button)
            return row
        }
        list.setRowCount(100)

        // A plain part of a row, past the button, selects the row.
        list.dispatchEvent(Event(type: .pointerDown, location: Point(x: 80, y: 10)))
        #expect(rowSelections == 1)

        // The control keeps its own click.
        let hit = list.hitTest(Point(x: 5, y: 5))
        #expect(hit is Control)

        list.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        list.dispatchEvent(Event(type: .pointerUp, location: Point(x: 5, y: 5)))
        #expect(buttonPresses == 1)
        #expect(rowSelections == 1, "and the row was not also selected")
    }

    /// Shrinking the data pulls the offset back rather than stranding the view
    /// past the end.
    @Test func shrinkingTheRowCountRebindsTheOffset() {
        let (list, _) = makeList(rows: 1_000)
        list.contentOffset = Point(x: 0, y: 15_000)

        list.setRowCount(20)
        #expect(list.contentOffset.y == 200, "20 rows * 20pt - 200pt viewport")
        #expect(list.visibleRowRange().upperBound <= 20)
    }
}
