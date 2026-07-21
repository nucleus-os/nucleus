@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderModelSmokeTests {
    @Test func renderModelSmoke() {
        let ctx = ContextID(raw: 1)
        let store = RetainedTreeStore(resourceHost: SwiftResourceHost())

        // Fresh store starts clean.
        #expect(store.revision == 0, "initial-revision")
        #expect(!store.presentDirty, "initial-clean")
        #expect(store.snapshot().layers.isEmpty, "initial-empty")

        // Ingest a non-empty transaction: create a root + child, wire them.
        var txn = Transaction(contextId: ctx)
        var root = LayerCreated(nodeId: 1, kind: .container)
        root.bounds = Bounds(w: 320, h: 240)
        txn.created.append(root)
        var child = LayerCreated(nodeId: 2, kind: .container)
        child.bounds = Bounds(w: 100, h: 100)
        child.initialContent = .paint(PaintContentHandle(raw: 7))
        txn.created.append(child)
        txn.inserted.append(LayerInserted(nodeId: 1, parentId: 0, index: 0))
        txn.inserted.append(LayerInserted(nodeId: 2, parentId: 1, index: 0))
        store.ingest(txn)

        // Tree shape + bookkeeping through the public API.
        #expect(store.revision == 1, "ingest-revision")
        #expect(store.presentDirty, "ingest-dirty")
        #expect(store.hasPendingDamage, "ingest-pending-damage")
        #expect(store.snapshot().roots(for: ctx) == [1], "ingest-root")
        #expect(store.snapshot().get(2)?.parent == 1, "ingest-child-parent")
        #expect(store.snapshot().get(1)?.children == [2], "ingest-parent-children")
        #expect(store.snapshot().get(2)?.model.content == .paint(PaintContentHandle(raw: 7)), "ingest-content")
        #expect(store.snapshot().get(1)?.model.properties.bounds == Bounds(w: 320, h: 240), "ingest-bounds")

        // markPresented clears the present-dirty + per-node damage.
        store.markPresented()
        #expect(!store.presentDirty, "presented-clean")
        #expect(!store.hasPendingDamage, "presented-damage-cleared")
        #expect(store.revision == 1, "presented-keeps-revision")
    }
}
