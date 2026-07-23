@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RetainedTreeStoreTests {
    @Test func retainedTreeStore() {
        let ctx = ContextID(raw: 1)
        let store = RetainedTreeStore(resourceHost: SwiftResourceHost())

        // --- fresh store: empty, clean, revision 0 ---
        #expect(store.revision == 0, "initial-revision")
        #expect(!store.presentDirty, "initial-clean")
        #expect(store.snapshot().layers.isEmpty, "initial-empty")
        #expect(!store.hasPendingDamage, "initial-no-damage")

        // --- empty transaction is a no-op: no revision bump, stays clean ---
        store.ingest(Transaction(contextId: ctx))
        #expect(store.revision == 0, "empty-ingest-no-bump")
        #expect(!store.presentDirty, "empty-ingest-clean")

        // --- first real ingest: tree populated, revision bumped, dirty + damaged ---
        var t = Transaction(contextId: ctx)
        var root = LayerCreated(nodeId: 1, kind: .container)
        root.bounds = Bounds(w: 200, h: 200)
        t.created.append(root)
        var child = LayerCreated(nodeId: 2, kind: .container)
        child.bounds = Bounds(w: 100, h: 100)
        child.initialContent = .paint(PaintContentHandle(raw: 9))
        t.created.append(child)
        t.inserted.append(LayerInserted(nodeId: 1, parentId: 0, index: 0))
        t.inserted.append(LayerInserted(nodeId: 2, parentId: 1, index: 0))
        store.ingest(t)
        #expect(store.revision == 1, "ingest-revision-bump")
        #expect(store.presentDirty, "ingest-dirty")
        #expect(store.hasPendingDamage, "ingest-pending-damage")
        #expect(store.snapshot().roots(for: ctx) == [1], "ingest-root")
        #expect(store.snapshot().get(2)?.parent == 1, "ingest-child-parent")
        #expect(store.snapshot().get(2)?.model.content == .paint(PaintContentHandle(raw: 9)), "ingest-content")

        // A handed-out value snapshot remains isolated from the live store even
        // though the store now mutates its own dictionary values in place.
        var isolatedSnapshot = store.snapshot()
        isolatedSnapshot.layers[2]?.model.properties.position = Point2D(x: 90, y: 45)
        #expect(isolatedSnapshot.get(2)?.model.properties.position == Point2D(x: 90, y: 45))
        #expect(store.snapshot().get(2)?.model.properties.position == Point2D())

        // --- markPresented clears the dirty flag and every node's damage ---
        store.markPresented()
        #expect(!store.presentDirty, "presented-clean")
        #expect(!store.hasPendingDamage, "presented-damage-cleared")
        // The tree itself is unchanged — only damage bookkeeping was reset.
        #expect(store.snapshot().get(2)?.model.content == .paint(PaintContentHandle(raw: 9)), "presented-keeps-content")
        #expect(store.revision == 1, "presented-keeps-revision")

        // --- a second commit re-dirties and re-damages, revision advances ---
        var t2 = Transaction(contextId: ctx)
        var move = LayerPropertyUpdate(nodeId: 2)
        move.position = Point2D(x: 25, y: 25)
        t2.propertyUpdates.append(move)
        store.ingest(t2)
        #expect(store.revision == 2, "second-revision-bump")
        #expect(store.presentDirty, "second-dirty")
        #expect(store.hasPendingDamage, "second-pending-damage")
        #expect(store.snapshot().get(2)?.model.properties.position == Point2D(x: 25, y: 25), "second-position")

        // --- removal folds through too ---
        var t3 = Transaction(contextId: ctx)
        t3.removed.append(LayerRemoved(nodeId: 2))
        store.ingest(t3)
        #expect(store.revision == 3, "remove-revision-bump")
        #expect(store.snapshot().get(2) == nil, "remove-gone")
        #expect(store.snapshot().get(1)?.children == [], "remove-unwired")
    }
}
