import NucleusTypes
@_spi(NucleusCompositor) @testable import NucleusUI
@_spi(NucleusCompositor) @testable import NucleusLayers
import Testing

@MainActor
@Suite struct LayerTransactionImplicitTests {
    @Test func implicitWritesAreEagerOnLocalState() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 1, commitSink: sink)
        let layer = context.makeLayer(.init(frame: .init(x: 0, y: 0, width: 10, height: 10)))

        // Writing through the ambient append path mutates local state at
        // the call site (Phase 1) and journals into the per-context
        // implicit buffer (Phase 2). No FFI commit happens yet.
        let update = LayerPropertyUpdate.decomposedFrame(.init(x: 1, y: 2, width: 3, height: 4))
        layer.apply(update)
        LayerTransaction.appendAmbient(.properties(layer: layer.id, update), in: context)

        #expect(layer.frame == .init(x: 1, y: 2, width: 3, height: 4))
        #expect(sink.transactions.count == 0)

        try LayerTransaction.flushImplicit(in: context)

        #expect(sink.transactions.count == 1)
        #expect(sink.transactions[0].propertyUpdates.count == 1)
        #expect(sink.transactions[0].propertyUpdates[0].layer == layer.id)
    }

    @Test func flushImplicitIsIdempotent() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 2, commitSink: sink)

        try LayerTransaction.flushImplicit(in: context)
        try LayerTransaction.flushImplicit(in: context)

        #expect(sink.transactions.count == 0)
    }

    @Test func flushImplicitBatchesMultiplePendingMutations() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 3, commitSink: sink)
        let a = context.makeLayer()
        let b = context.makeLayer()

        let updateA = LayerPropertyUpdate.decomposedFrame(.init(x: 1, y: 1, width: 1, height: 1))
        let updateB = LayerPropertyUpdate.decomposedFrame(.init(x: 2, y: 2, width: 2, height: 2))
        a.apply(updateA)
        b.apply(updateB)
        LayerTransaction.appendAmbient(.properties(layer: a.id, updateA), in: context)
        LayerTransaction.appendAmbient(.properties(layer: b.id, updateB), in: context)

        try LayerTransaction.flushImplicit(in: context)

        #expect(sink.transactions.count == 1)
        #expect(sink.transactions[0].propertyUpdates.count == 2)
    }

    @Test func transactionAnimateAppliesDefaultActionPolicy() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 6_401, commitSink: sink)

        try Application.withContext(context) {
            let view = try View()
            try Transaction.animate {
                view.frame = Rect(x: 1, y: 2, width: 30, height: 40)
            }
        }

        #expect(sink.transactions.count == 1)
        #expect(sink.transactions[0].propertyUpdates.count == 1)
        #expect(sink.transactions[0].propertyUpdates[0].properties.actionPolicy == .default)
    }

    @Test func transactionRunCanReturnClockedCompletion() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 6_402, commitSink: sink)
        var completed = false

        let completion = try Application.withContext(context) {
            let view = try View()
            return try Transaction.run(
                in: context,
                duration: 0.10,
                nowNs: 1_000_000,
                actionPolicy: .default
            ) {
                view.alphaValue = 0
            } completion: {
                completed = true
            }
        }

        #expect(sink.transactions.count == 1)
        #expect(completion?.fireIfDue(nowNs: 100_000_000) == false)
        #expect(!completed)
        #expect(completion?.fireIfDue(nowNs: 101_000_000) == true)
        #expect(completed)
        #expect(completion?.fireIfDue(nowNs: 200_000_000) == false)
    }
}
