import NucleusTypes
@_spi(NucleusCompositor) @testable import NucleusUI
@_spi(NucleusCompositor) @testable import NucleusLayers
import Testing

@MainActor
@Suite(.uiContext) struct LayerTransactionImplicitTests {
    @Test func implicitWritesAreEagerOnLocalState() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 1, commitSink: sink)
        let layer = context.makeLayer(.init(frame: .init(x: 0, y: 0, width: 10, height: 10)))

        // Writing through the ambient append path mutates local state at
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
            let view = View()
            let publisher = ViewLayerPublisher(context: context)
            _ = try publisher.publish(roots: [view])
            try Transaction.animate(in: view) {
                view.frame = Rect(x: 1, y: 2, width: 30, height: 40)
            }
            _ = try publisher.publish(roots: [view])
        }

        let authoredUpdates = sink.transactions.flatMap(\.propertyUpdates)
        #expect(authoredUpdates.count == 1)
        #expect(authoredUpdates[0].properties.actionPolicy == .default)
    }

    @Test func laterPolicyDoesNotRewriteEarlierMutation() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 6_403, commitSink: sink)

        try Application.withContext(context) {
            let view = View()
            let publisher = ViewLayerPublisher(context: context)
            _ = try publisher.publish(roots: [view])
            try Transaction.animate(in: view) {
                view.frame = Rect(x: 1, y: 2, width: 30, height: 40)
            }
            view.alphaValue = 0.5
            _ = try publisher.publish(roots: [view])
        }

        let updates = sink.transactions.flatMap(\.propertyUpdates)
        let frame = try #require(updates.first {
            $0.properties.position != nil && $0.properties.bounds != nil
        })
        let opacity = try #require(updates.first {
            $0.properties.opacity == 0.5
        })
        #expect(frame.properties.actionPolicy == .default)
        #expect(opacity.properties.actionPolicy == .none)
    }

    @Test func transactionCompletionWaitsForPublicationAcceptance() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 6_402, commitSink: sink)
        var outcomes: [TransactionOutcome] = []

        let completion = try Application.withContext(context) {
            let view = View()
            let publisher = ViewLayerPublisher(context: context)
            _ = try publisher.publish(roots: [view])
            let handle = try Transaction.run(
                in: view,
                configuration: .animated,
                completion: { outcomes.append($0) }
            ) {
                view.alphaValue = 0
            }
            #expect(handle.outcome == nil)
            _ = try publisher.publish(roots: [view])
            return handle
        }

        #expect(sink.transactions.count >= 2)
        #expect(sink.transactions.contains { $0.completionToken != 0 })
        #expect(completion.outcome == .completed)
        #expect(outcomes == [.completed])
    }
}
