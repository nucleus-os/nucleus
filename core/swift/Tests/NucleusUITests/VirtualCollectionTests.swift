import Testing
@testable import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers

@MainActor
@Suite(.uiContext) struct CollectionSnapshotTests {
    @Test func duplicateIdentityIsRejected() {
        #expect(throws: CollectionSnapshotError.duplicateItemID(
            CollectionItemID("same")
        )) {
            try CollectionSnapshot(items: [
                CollectionItem(id: "same"),
                CollectionItem(id: "same"),
            ])
        }
    }

    @Test func listPreservesSelectionAndFocusThroughMoves() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        list.rowHeight = 20
        list.makeRow = { View() }
        list.applySnapshot(try! CollectionSnapshot(ids: ["a", "b", "c"]))
        list.selectItem(id: CollectionItemID("b"))
        let retained = list.rowView(forItemID: "b")

        list.applySnapshot(try! CollectionSnapshot(ids: ["c", "a", "b"]))

        #expect(list.selectedItemIDs == [CollectionItemID("b")])
        #expect(list.focusedItemID == CollectionItemID("b"))
        #expect(list.rowView(forItemID: "b") === retained)
    }

    @Test func listKeyboardNavigationActivatesTheStableItem() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        list.rowHeight = 20
        list.applySnapshot(try! CollectionSnapshot(ids: ["a", "b", "c"]))
        var activated: CollectionItemID?
        list.onActivateItem = { item, _ in activated = item.id }

        #expect(list.handleEvent(Event(
            type: .keyDown, keyCode: .downArrow)) == .handled)
        #expect(list.focusedItemID == CollectionItemID("b"))
        #expect(list.handleEvent(Event(
            type: .keyDown, keyCode: .return)) == .handled)
        #expect(activated == CollectionItemID("b"))
    }

    @Test func multipleSelectionExtendsFromStableAnchor() {
        let list = ListView()
        list.selectionMode = .multiple
        list.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        list.rowHeight = 20
        list.applySnapshot(try! CollectionSnapshot(ids: Array(0..<5)))
        list.selectItem(id: CollectionItemID(1))
        list.selectItem(id: CollectionItemID(3), extendingSelection: true)
        #expect(list.selectedItemIDs == Set([
            CollectionItemID(1),
            CollectionItemID(2),
            CollectionItemID(3),
        ]))
    }
}

@MainActor
@Suite(.uiContext) struct VirtualGridViewTests {
    private func makeGrid(
        count: Int = 10,
        width: Double = 210,
        height: Double = 100
    ) -> VirtualGridView {
        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: width, height: height)
        grid.columns = .fixed(count: 2)
        grid.columnGap = 10
        grid.rowGap = 5
        grid.cellSizing = .square
        grid.makeCell = { View() }
        grid.applySnapshot(
            try! CollectionSnapshot(ids: Array(0..<count)))
        grid.layoutIfNeeded()
        return grid
    }

    @Test func fixedColumnsAndSquareCellsResolveDeterministically() {
        let grid = makeGrid()
        #expect(grid.resolvedColumnCount == 2)
        #expect(grid.resolvedCellSize == Size(width: 100, height: 100))
        #expect(grid.frameForItem(at: 3) == Rect(
            x: 110, y: 105, width: 100, height: 100))
    }

    @Test func adaptiveColumnsRespectMinimumWidth() {
        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: 320, height: 100)
        grid.columnGap = 10
        grid.columns = .adaptive(minimumWidth: 100)
        grid.applySnapshot(try! CollectionSnapshot(ids: Array(0..<20)))
        grid.layoutIfNeeded()
        #expect(grid.resolvedColumnCount == 3)
        #expect(grid.resolvedCellSize.width == 100)
    }

    @Test func onlyViewportAndOverscanAreMaterializedAndReused() {
        var built = 0
        let grid = makeGrid(count: 10_000)
        grid.makeCell = {
            built += 1
            return View()
        }
        // Force fresh materialization after installing the counting factory.
        grid.applySnapshot(
            try! CollectionSnapshot(ids: Array(10_000..<20_000)))
        #expect(grid.materializedCellCount < 12)
        grid.contentOffset.y = 5_000
        let initial = built
        grid.contentOffset.y = 10_000
        #expect(built == initial)
    }

    @Test func gapHitTestingDoesNotSelectACell() {
        let grid = makeGrid()
        #expect(grid.itemIndex(at: Point(x: 50, y: 50)) == 0)
        #expect(grid.itemIndex(at: Point(x: 105, y: 50)) == nil)
        #expect(grid.itemIndex(at: Point(x: 50, y: 102)) == nil)
    }

    @Test func movedItemKeepsItsCellAndRevisionChangesReconfigureIt() {
        let grid = makeGrid(count: 4)
        var configured: [CollectionItemID] = []
        grid.configureCell = { _, item, _ in configured.append(item.id) }
        grid.reloadVisibleCells()
        let retained = grid.cellView(forItemID: 1)
        configured.removeAll()

        grid.applySnapshot(try! CollectionSnapshot(items: [
            CollectionItem(id: 3),
            CollectionItem(id: 1, revision: 1),
            CollectionItem(id: 0),
            CollectionItem(id: 2),
        ]))
        #expect(grid.cellView(forItemID: 1) === retained)
        #expect(configured == [CollectionItemID(1)])
    }

    @Test func keyboardNavigationUsesResolvedColumnsAndScrolls() {
        let grid = makeGrid(count: 20, height: 100)
        grid.setSelectedItemIDs([CollectionItemID(0)])
        #expect(grid.handleEvent(Event(
            type: .keyDown, keyCode: .downArrow)) == .handled)
        #expect(grid.focusedItemID == CollectionItemID(2))
        #expect(grid.contentOffset.y > 0)
    }

    @Test func continuousScrollingKeepsPublishedLayersBounded() throws {
        installStubHost()
        let grid = makeGrid(count: 10_000)
        let publisher = ViewLayerPublisher(
            context: Application.makeInMemoryVisualContext())
        _ = try publisher.publish(roots: [grid])
        var maximumPublished = publisher.publishedVisualLayerCount

        for step in 1...200 {
            grid.contentOffset.y = Double(step * 75)
            _ = try publisher.publish(roots: [grid])
            maximumPublished = max(
                maximumPublished,
                publisher.publishedVisualLayerCount)
        }

        #expect(grid.materializedCellCount < 12)
        #expect(maximumPublished <= 13)
        #expect(publisher.retainedPaintRegistrationCount <= 1)
    }
}
