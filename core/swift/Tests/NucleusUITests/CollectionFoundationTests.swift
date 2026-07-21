@testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext, .serialized)
/// Release collection gate. Materialization, cache, and layer limits are
/// functions of viewport/overscan, not elapsed time.
struct NucleusCollectionStressTests {
    private func makeList(
        count: Int = 100,
        height: Double = 100
    ) -> ListView {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: height)
        list.rowHeight = 20
        list.overscan = 0
        list.makeRow = { View() }
        list.applySnapshot(
            try! CollectionSnapshot(ids: Array(0..<count)))
        list.layoutIfNeeded()
        return list
    }

    private func makeScene(
        root: View,
        size: Size = Size(width: 200, height: 100)
    ) -> WindowScene {
        root.frame = Rect(origin: .zero, size: size)
        let window = Window(
            title: "Collection",
            frame: Rect(origin: .zero, size: size))
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.displayBounds = Rect(origin: .zero, size: size)
        scene.makeKey(window)
        root.layoutIfNeeded()
        return scene
    }

    @Test func listPreservesTheTopItemAndIntraItemOffset() {
        let list = makeList()
        list.contentOffset.y = 407
        #expect(list.rowIndex(at: .zero) == 20)

        list.applySnapshot(try! CollectionSnapshot(
            ids: Array(-5..<0) + Array(0..<100)))

        #expect(list.contentOffset.y == 507)
        #expect(list.rowIndex(at: .zero) == 25)
        #expect(list.snapshot.items[25].id == CollectionItemID(20))
    }

    @Test func localizedRevisionUsesTheMeasurementCacheAndBoundsIt() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        var measurements = 0
        list.measureRow = { _, width in
            measurements += 1
            return width / 10
        }
        list.applySnapshot(try! CollectionSnapshot(items: (0..<3_000).map {
            CollectionItem(id: $0)
        }))
        list.layoutIfNeeded()
        let afterInitialLayout = measurements
        #expect(list.measurementCacheEntryCount <= 2_048)

        var changed = list.snapshot.items
        changed[2_500] = CollectionItem(id: 2_500, revision: 1)
        list.applySnapshot(try! CollectionSnapshot(items: changed))

        // Entries evicted by the hard cache bound can be measured again, but
        // the cache itself never follows model size without limit.
        #expect(measurements > afterInitialLayout)
        #expect(list.measurementCacheEntryCount <= 2_048)

        let beforeEnvironment = measurements
        list.uiContext.updateEnvironment(
            list.uiContext.environment.replacing(textScale: 1.25))
        #expect(measurements > beforeEnvironment)
        #expect(list.measurementCacheEntryCount <= 2_048)
    }

    @Test func aSmallSnapshotRemeasuresOnlyTheChangedRevision() {
        let list = ListView()
        list.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        var measurements = 0
        list.measureRow = { _, _ in
            measurements += 1
            return 20
        }
        list.applySnapshot(try! CollectionSnapshot(items: (0..<50).map {
            CollectionItem(id: $0)
        }))
        list.layoutIfNeeded()
        let baseline = measurements
        var items = list.snapshot.items
        items[25] = CollectionItem(id: 25, revision: 1)
        list.applySnapshot(try! CollectionSnapshot(items: items))
        #expect(measurements == baseline + 1)

        let scene = makeScene(root: list)
        let beforeScale = measurements
        scene.keyWindow?.setSurfaceAssociation(WindowSurfaceAssociation(
            surfaceID: PresentationSurfaceID(rawValue: 1),
            transform: WindowSurfaceTransform(
                backingScaleFactor: BackingScaleFactor(Double(2)))))
        #expect(measurements == beforeScale + 50)
    }

    @Test func listTypeAheadUsesMetadataWithoutMaterializingTheItem() {
        let list = makeList(count: 1_000)
        list.itemSearchText = { item in
            item.id == CollectionItemID(750) ? "Nebula" : "Other"
        }

        #expect(list.handleEvent(Event(
            type: .keyDown,
            keyCode: .letterN,
            characters: "n")) == .handled)
        #expect(list.focusedItemID == CollectionItemID(750))
        #expect(list.selectedItemIDs == [CollectionItemID(750)])
        #expect(list.materializedRowCount < 20)
    }

    @Test func listTypeAheadDeadlineAndSnapshotCancellationUseContextTime() async {
        let list = makeList(count: 4)
        list.itemSearchText = { "item-\($0.id)" }
        #expect(list.handleEvent(Event(
            type: .keyDown,
            keyCode: .letterI,
            characters: "i")) == .handled)
        await waitForClockWaiters(1)

        testUIClock().advance(by: .nanoseconds(699_999_999))
        await Task.yield()
        #expect(testUIClock().waiterCount == 1)
        testUIClock().advance(by: .nanoseconds(1))
        await waitForClockWaiters(0)

        #expect(list.handleEvent(Event(
            type: .keyDown,
            keyCode: .letterI,
            characters: "i")) == .handled)
        await waitForClockWaiters(1)
        list.applySnapshot(try! CollectionSnapshot(ids: [10, 11]))
        await waitForClockWaiters(0)
        testUIClock().advance(by: .seconds(1))
        #expect(testUIClock().waiterCount == 0)
    }

    @Test func variableGridUsesTallestRowsAndSpatialNavigation() {
        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: 210, height: 100)
        grid.columns = .fixed(count: 2)
        grid.columnGap = 10
        grid.rowGap = 5
        let heights: [CollectionItemID: Double] = [
            CollectionItemID(0): 20,
            CollectionItemID(1): 100,
            CollectionItemID(2): 80,
            CollectionItemID(3): 20,
        ]
        grid.measureCellHeight = { item, _ in heights[item.id] ?? 0 }
        grid.applySnapshot(try! CollectionSnapshot(ids: Array(0..<4)))
        grid.layoutIfNeeded()

        #expect(grid.frameForItem(at: 0) == Rect(
            x: 0, y: 0, width: 100, height: 20))
        #expect(grid.frameForItem(at: 2) == Rect(
            x: 0, y: 105, width: 100, height: 80))
        grid.selectItem(id: CollectionItemID(0))
        #expect(grid.handleEvent(Event(
            type: .keyDown,
            keyCode: .downArrow)) == .handled)
        #expect(grid.focusedItemID == CollectionItemID(2))
    }

    @Test func gridTypeAheadSnapshotReplacementCancelsItsDeadline() async {
        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        grid.columns = .fixed(count: 2)
        grid.itemSearchText = { "cell-\($0.id)" }
        grid.applySnapshot(try! CollectionSnapshot(ids: [0, 1, 2, 3]))
        #expect(grid.handleEvent(Event(
            type: .keyDown,
            keyCode: .letterC,
            characters: "c")) == .handled)
        await waitForClockWaiters(1)

        grid.applySnapshot(try! CollectionSnapshot(ids: [4, 5]))
        await waitForClockWaiters(0)
        testUIClock().advance(by: .seconds(1))
        #expect(testUIClock().waiterCount == 0)
    }

    private func waitForClockWaiters(_ count: Int) async {
        for _ in 0..<32 where testUIClock().waiterCount != count {
            await Task.yield()
        }
        #expect(testUIClock().waiterCount == count)
    }

    @Test func gridPreservesScrollAnchorAcrossMovement() {
        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        grid.columns = .fixed(count: 2)
        grid.cellSizing = .fixedHeight(20)
        grid.applySnapshot(
            try! CollectionSnapshot(ids: Array(0..<100)))
        grid.layoutIfNeeded()
        grid.contentOffset.y = 207

        grid.applySnapshot(try! CollectionSnapshot(
            ids: [-4, -3, -2, -1] + Array(0..<100)))

        #expect(grid.contentOffset.y == 247)
        #expect(grid.snapshot.items[24].id == CollectionItemID(20))
    }

    @Test func reusePoolsStayBoundedAcrossDisjointSnapshots() {
        let list = makeList(count: 10_000)
        for generation in 1...100 {
            list.contentOffset.y = Double(generation * 200)
            list.applySnapshot(try! CollectionSnapshot(
                ids: Array(
                    generation * 10_000..<(generation + 1) * 10_000)))
        }
        #expect(list.materializedRowCount < 10)
        #expect(list.reusePoolCount <= 16)

        let grid = VirtualGridView()
        grid.frame = Rect(x: 0, y: 0, width: 210, height: 100)
        grid.columns = .fixed(count: 2)
        grid.makeCell = { View() }
        grid.applySnapshot(
            try! CollectionSnapshot(ids: Array(0..<10_000)))
        grid.layoutIfNeeded()
        for generation in 1...100 {
            grid.contentOffset.y = Double(generation * 200)
            grid.applySnapshot(try! CollectionSnapshot(
                ids: Array(
                    generation * 10_000..<(generation + 1) * 10_000)))
        }
        #expect(grid.materializedCellCount < 12)
        #expect(grid.reusePoolCount <= 16)
    }

    @Test func listReorderMovesAgainstTheAcceptedGeneration() async {
        let list = makeList(count: 4, height: 80)
        var applied: CollectionReorderResult?
        list.reordering = CollectionReorderingConfiguration(
            didApply: { _, result in applied = result })
        let scene = makeScene(
            root: list,
            size: Size(width: 200, height: 80))

        _ = list.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 20, y: 10),
            pointerTool: .mouse))
        #expect(scene.beginDrag(
            from: list,
            at: Point(x: 20, y: 10)) != nil)
        #expect(scene.updateDrag(
            at: Point(x: 20, y: 79)) == DragDropProposal(
                contentType: collectionReorderContentType,
                operation: .move))
        #expect(list.hasVisibleInsertionPreview)
        #expect(await scene.drop(
            at: Point(x: 20, y: 79)) == .performed(.move))

        #expect(list.snapshot.items.map(\.id) == [
            CollectionItemID(1),
            CollectionItemID(2),
            CollectionItemID(3),
            CollectionItemID(0),
        ])
        #expect(applied == CollectionReorderResult(
            itemID: CollectionItemID(0),
            sourceIndex: 0,
            insertionIndex: 4,
            operation: .move))
        #expect(!list.hasVisibleInsertionPreview)
    }

    @Test func staleReorderIsRejectedWithoutMutatingTheNewSnapshot() async {
        let list = makeList(count: 4, height: 80)
        list.reordering = CollectionReorderingConfiguration()
        let scene = makeScene(
            root: list,
            size: Size(width: 200, height: 80))

        _ = list.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 20, y: 10),
            pointerTool: .mouse))
        #expect(scene.beginDrag(
            from: list,
            at: Point(x: 20, y: 10)) != nil)
        _ = scene.updateDrag(at: Point(x: 20, y: 79))
        let replacement = try! CollectionSnapshot(items: [
            CollectionItem(id: 0, revision: 1),
            CollectionItem(id: 1),
            CollectionItem(id: 2),
            CollectionItem(id: 3),
        ])
        list.applySnapshot(replacement)

        #expect(await scene.drop(
            at: Point(x: 20, y: 79)) == .rejected)
        #expect(list.snapshot == replacement)
        #expect(!list.hasVisibleInsertionPreview)
    }

    @Test func explicitCopyProducesAUniqueItem() async {
        let list = makeList(count: 2, height: 40)
        list.reordering = CollectionReorderingConfiguration(
            allowedOperations: [.copy],
            preferredOperation: .copy,
            copyItem: { _ in CollectionItem(id: "copy") })
        let scene = makeScene(
            root: list,
            size: Size(width: 200, height: 40))

        _ = list.handleEvent(Event(
            type: .pointerDown,
            location: Point(x: 20, y: 10),
            pointerTool: .mouse))
        _ = scene.beginDrag(
            from: list,
            at: Point(x: 20, y: 10))
        #expect(await scene.drop(
            at: Point(x: 20, y: 39)) == .performed(.copy))
        #expect(list.snapshot.items.map(\.id) == [
            CollectionItemID(0),
            CollectionItemID(1),
            CollectionItemID("copy"),
        ])
    }
}
