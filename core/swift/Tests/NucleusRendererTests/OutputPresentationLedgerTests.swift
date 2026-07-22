import Testing
@testable import NucleusRenderer

@Suite struct OutputPresentationLedgerTests {
    @Test func resourceCompletionRequiresEveryOutputToPresent() {
        var ledger = OutputPresentationLedger()
        ledger.attach(1)
        ledger.attach(2)

        #expect(!ledger.needsResourceGeneration(0, outputID: 1))
        #expect(ledger.needsResourceGeneration(1, outputID: 1))
        #expect(ledger.needsResourceGeneration(1, outputID: 2))

        ledger.acknowledge(
            1,
            treeRevision: 4,
            lockGeneration: 2,
            resourceGeneration: 1)
        #expect(!ledger.needsResourceGeneration(1, outputID: 1))
        #expect(ledger.needsResourceGeneration(1, outputID: 2))

        ledger.acknowledge(
            2,
            treeRevision: 4,
            lockGeneration: 2,
            resourceGeneration: 1)
        #expect(!ledger.needsResourceGeneration(1, outputID: 2))
        #expect(ledger.needsResourceGeneration(2, outputID: 1))
        #expect(ledger.needsResourceGeneration(2, outputID: 2))
    }

    @Test func resourceAndCompositionTransitionsForceAccumulatorRedraw() {
        var ledger = OutputPresentationLedger()
        ledger.attach(7)
        ledger.acknowledge(
            7,
            treeRevision: 4,
            lockGeneration: 2,
            resourceGeneration: 1)

        let treeOnly = ledger.invalidation(
            outputID: 7,
            treeRevision: 5,
            lockGeneration: 2,
            resourceGeneration: 1)
        #expect(treeOnly.treeRevisionChanged)
        #expect(!treeOnly.forceFullDamage)

        let resource = ledger.invalidation(
            outputID: 7,
            treeRevision: 4,
            lockGeneration: 2,
            resourceGeneration: 2)
        #expect(resource.resourceGenerationChanged)
        #expect(resource.forceFullDamage)

        let lock = ledger.invalidation(
            outputID: 7,
            treeRevision: 4,
            lockGeneration: 3,
            resourceGeneration: 1)
        #expect(lock.lockGenerationChanged)
        #expect(lock.forceFullDamage)
    }
}
