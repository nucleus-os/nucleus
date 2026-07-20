import NucleusTypes
@_spi(NucleusCompositor) import NucleusLayers
import Testing

@MainActor
@Suite(.uiContext) struct LayerTests {
    init() { installStubHost() }

    @Test func contextLayerTransactionAppliesPropertiesThroughInMemorySink() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 1, commitSink: sink)
        let layer = context.makeLayer(.init(
            frame: .init(x: 1, y: 2, width: 3, height: 4),
            opacity: 0.5
        ))

        #expect(layer.frame == .init(x: 1, y: 2, width: 3, height: 4))
        #expect(layer.opacity == 0.5)

        var transaction = Transaction(context: context)
        var properties = LayerPropertyUpdate.decomposedFrame(
            .init(x: 10, y: 20, width: 30, height: 40),
            actionPolicy: .default
        )
        properties.isHidden = true
        properties.opacity = 0.25
        try transaction.setProperties(properties, for: layer)

        // Eager: writes are visible on the layer immediately, before commit.
        #expect(layer.frame == .init(x: 10, y: 20, width: 30, height: 40))
        #expect(layer.isHidden)
        #expect(layer.opacity == 0.25)
        #expect(sink.transactions.count == 0)

        try transaction.commit()

        #expect(layer.frame == .init(x: 10, y: 20, width: 30, height: 40))
        #expect(sink.transactions.count == 1)
        #expect(sink.transactions[0].propertyUpdates.count == 1)
        #expect(sink.transactions[0].propertyUpdates[0].layer == layer.id)
    }

    @Test func transactionAbortDoesNotRollBackLayerProperties() throws {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: 2, commitSink: sink)
        let layer = context.makeLayer(.init(frame: .init(x: 1, y: 1, width: 20, height: 20)))

        var transaction = Transaction(context: context)
        try transaction.setProperties(.decomposedFrame(.init(x: 50, y: 60, width: 70, height: 80)), for: layer)
        transaction.abort()

        // Mirrors CATransaction: aborting does not undo property writes.
        #expect(layer.frame == .init(x: 50, y: 60, width: 70, height: 80))
        // The FFI sink was not called.
        #expect(sink.transactions.count == 0)
    }

    @Test func transactionRejectsCrossContextInsert() throws {
        let contextA = try Context(contextID: 3, commitSink: InMemoryCommitSink())
        let contextB = try Context(contextID: 4, commitSink: InMemoryCommitSink())
        let layer = contextA.makeLayer()
        let parent = contextB.makeLayer()

        var transaction = Transaction(context: contextA)
        #expect(throws: LayerError.invalidArgument(detail: "layer belongs to another context")) {
            try transaction.insert(layer, into: parent)
        }
    }

    @Test func contextRequiresExplicitProducerID() {
        #expect(throws: LayerError.invalidArgument(detail: "context id must be explicit")) {
            _ = try Context(contextID: 0, commitSink: InMemoryCommitSink())
        }
    }

    @Test func contextCanReserveProducerIDAndQueryDisplayLink() throws {
        let context = try Context(commitSink: InMemoryCommitSink())
        #expect(context.id.rawValue != 0)

        let report = try context.queryDisplayLink()
        #expect(report.predictedPresentationNanoseconds > 0)
        #expect(report.targetPresentationNanoseconds > 0)
        #expect(report.nextPresentID > 0)
    }

    // Layout drift is pinned by the generated `NucleusTypes` module, so a
    // separate Swift MemoryLayout sweep is redundant.
}
