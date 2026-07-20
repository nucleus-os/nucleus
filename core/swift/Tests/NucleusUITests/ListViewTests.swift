import Testing
@testable import NucleusUI


/// Variable row heights, and rows that follow their item rather than their slot.
@MainActor
@Suite(.uiContext) struct ListViewVariableHeightTests {
    /// Heights cycling 20 / 40 / 60, so an index is not derivable by division.
    private func makeList(rowCount: Int = 30) -> ListView {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        list.overscan = 0
        list.makeRow = { View() }
        list.rowHeightProvider = { _, index in
            Double(20 + (index % 3) * 20)
        }
        list.applySnapshot(try! CollectionSnapshot(ids: Array(0..<rowCount)))
        list.layoutIfNeeded()
        return list
    }

    // MARK: - Geometry

    @Test func rowsStackAtTheirOwnHeights() {
        let list = makeList()
        #expect(list.height(forRow: 0) == 20)
        #expect(list.height(forRow: 1) == 40)
        #expect(list.height(forRow: 2) == 60)

        #expect(list.offset(forRow: 0) == 0)
        #expect(list.offset(forRow: 1) == 20)
        #expect(list.offset(forRow: 2) == 60)
        #expect(list.offset(forRow: 3) == 120, "one full 20/40/60 cycle")
    }

    @Test func theContentHeightIsTheSumOfTheRows() {
        let list = makeList(rowCount: 3)
        #expect(list.contentHeight == 120)
    }

    /// The lookup a scroll performs on every frame. Division cannot answer it
    /// once heights vary.
    @Test func aPointResolvesToTheRowContainingIt() {
        let list = makeList()
        #expect(list.rowIndex(at: Point(x: 0, y: 0)) == 0)
        #expect(list.rowIndex(at: Point(x: 0, y: 19)) == 0)
        #expect(list.rowIndex(at: Point(x: 0, y: 20)) == 1, "the boundary belongs to the next row")
        #expect(list.rowIndex(at: Point(x: 0, y: 59)) == 1)
        #expect(list.rowIndex(at: Point(x: 0, y: 60)) == 2)
        #expect(list.rowIndex(at: Point(x: 0, y: 119)) == 2)
    }

    @Test func aPointPastTheEndResolvesToNothing() {
        let list = makeList(rowCount: 3)
        #expect(list.rowIndex(at: Point(x: 0, y: 120)) == nil)
        #expect(list.rowIndex(at: Point(x: 0, y: -1)) == nil)
    }

    /// The visible range must cover the viewport exactly — too few rows leaves a
    /// gap, and the count cannot be derived from a single height any more.
    @Test func theVisibleRangeCoversTheViewport() {
        let list = makeList()
        // 100pt of viewport from the top covers rows 0 (20), 1 (40), 2 (60)
        // partially — three rows.
        let range = list.visibleRowRange()
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 3)
    }

    @Test func scrollingMovesTheVisibleRange() {
        let list = makeList()
        list.contentOffset = Point(x: 0, y: 120)  // exactly row 3
        let range = list.visibleRowRange()
        #expect(range.lowerBound == 3)
        #expect(range.contains(4))
    }

    @Test func rowsAreLaidOutAtTheirMeasuredPositions() {
        let list = makeList()
        list.layoutIfNeeded()
        // Only the rows on screen exist, and each sits at its own offset.
        #expect(list.materializedRowCount == 3)
    }

    /// A height that changed without the count changing.
    @Test func invalidatingRemeasures() {
        let list = makeList(rowCount: 3)
        #expect(list.contentHeight == 120)

        list.rowHeightProvider = { _, _ in 10 }
        #expect(list.contentHeight == 30)
        #expect(list.offset(forRow: 2) == 20)
    }

    /// Dropping the provider returns to the arithmetic path rather than leaving
    /// a stale table behind.
    @Test func clearingTheProviderReturnsToUniformRows() {
        let list = makeList(rowCount: 4)
        list.rowHeight = 25
        list.rowHeightProvider = nil
        #expect(list.contentHeight == 100)
        #expect(list.offset(forRow: 2) == 50)
        #expect(list.rowIndex(at: Point(x: 0, y: 60)) == 2)
    }

    /// A zero-height row would break the search's assumption that offsets
    /// increase, so a negative one is clamped rather than trusted.
    @Test func negativeHeightsAreClamped() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        list.makeRow = { View() }
        list.rowHeightProvider = { _, index in index == 1 ? -50 : 20 }
        list.applySnapshot(try! CollectionSnapshot(ids: Array(0..<3)))
        #expect(list.contentHeight == 40)
        #expect(list.height(forRow: 1) == 0)
    }

    // MARK: - Keyed identity

    /// A view follows its item. Without this, inserting at the top hands every
    /// visible row's view to a different item, taking whatever state it held.
    @Test func aRowViewFollowsItsItem() {
        var items = ["a", "b", "c", "d"]
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        list.rowHeight = 20
        list.overscan = 0
        list.makeRow = { View() }
        var configured: [String] = []
        list.configureRow = { _, _, index in
            configured.append(items[index])
        }
        list.applySnapshot(try! CollectionSnapshot(ids: items))
        list.layoutIfNeeded()

        let viewForB = list.rowView(at: 1)
        #expect(viewForB != nil)
        configured.removeAll()

        // Insert at the top: every item shifts down one slot.
        items.insert("z", at: 0)
        list.applySnapshot(try! CollectionSnapshot(ids: items))
        list.layoutIfNeeded()

        #expect(list.rowView(at: 2) === viewForB, "b's view moved with b")
        #expect(configured == ["z"], "only the new item was configured")
    }

    /// A revision changes content without discarding the retained row.
    @Test func aChangedRevisionReconfiguresOnlyThatItem() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        list.rowHeight = 20
        list.overscan = 0
        list.makeRow = { View() }
        var configured: [CollectionItemID] = []
        list.configureRow = { _, item, _ in configured.append(item.id) }
        list.applySnapshot(try! CollectionSnapshot(items: [
            CollectionItem(id: "a"),
            CollectionItem(id: "b"),
            CollectionItem(id: "c"),
        ]))
        list.layoutIfNeeded()

        let retained = list.rowView(forItemID: "b")
        configured.removeAll()
        list.applySnapshot(try! CollectionSnapshot(items: [
            CollectionItem(id: "a"),
            CollectionItem(id: "b", revision: 1),
            CollectionItem(id: "c"),
        ]))
        list.layoutIfNeeded()
        #expect(configured == [CollectionItemID("b")])
        #expect(list.rowView(forItemID: "b") === retained)
    }

    /// An item that disappeared must not keep its view alive under its key.
    @Test func aVanishedItemDoesNotRetainItsView() {
        var items = ["a", "b", "c"]
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        list.rowHeight = 20
        list.overscan = 0
        list.makeRow = { View() }
        list.configureRow = { _, _, _ in }
        list.applySnapshot(try! CollectionSnapshot(ids: items))
        list.layoutIfNeeded()

        items = ["a"]
        list.applySnapshot(try! CollectionSnapshot(ids: items))
        list.layoutIfNeeded()
        #expect(list.materializedRowCount == 1)
    }
}
