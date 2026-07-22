import Testing
@testable import NucleusRenderer
import NucleusRenderModel

@Suite struct ImageResourceManagerTests {
    private func source(_ name: String) -> ImageSource {
        ImageSource(path: name, maxWidth: 100, maxHeight: 100)
    }

    @Test func residencyInvalidatesOnlyOutputsThatConsumedTheResource() {
        var ledger = ImageResidencyLedger()
        ledger.register(handle: 7, source: source("wallpaper"))
        ledger.consume(handle: 7, outputID: 10)
        ledger.consume(handle: 7, outputID: 30)

        ledger.transition(handle: 7, to: .decoding)
        ledger.transition(handle: 7, to: .decoded)
        ledger.transition(handle: 7, to: .uploading)
        let changed = ledger.transition(
            handle: 7,
            to: .resident,
            changesVisibleContent: true)

        #expect(changed == [10, 30])
        #expect(ledger.outputRevision(10) > 0)
        #expect(ledger.outputRevision(20) == 0)
        #expect(ledger.outputRevision(30) == ledger.outputRevision(10))
    }

    @Test func dependencyIdentityContainsEveryResourceNotOnlyAMaxGeneration() {
        var ledger = ImageResidencyLedger()
        ledger.register(handle: 3, source: source("icon"))
        ledger.register(handle: 9, source: source("photo"))

        let both = ledger.dependencies(for: [3, 9])
        let iconOnly = ledger.dependencies(for: [3])
        let photoOnly = ledger.dependencies(for: [9])

        #expect(both != iconOnly)
        #expect(both != photoOnly)
        #expect(both.versions.map(\.handle) == [3, 9])
    }

    @Test func paintContentPrecomputesStableUniqueImageDependencies() {
        let content = PaintContentStore.Content(commands: [
            PaintDrawCommand(
                kind: .image, x: 0, y: 0, w: 1, h: 1,
                imageHandle: 9),
            PaintDrawCommand(
                kind: .rect, x: 0, y: 0, w: 1, h: 1),
            PaintDrawCommand(
                kind: .image, x: 0, y: 0, w: 1, h: 1,
                imageHandle: 3),
            PaintDrawCommand(
                kind: .image, x: 0, y: 0, w: 1, h: 1,
                imageHandle: 9),
        ], width: 10, height: 10)

        #expect(content.imageDependencies == [3, 9])
    }

    @Test func evictionTargetsPriorConsumersAndDropsDependencyState() {
        var ledger = ImageResidencyLedger()
        ledger.register(handle: 4, source: source("wallpaper"))
        ledger.consume(handle: 4, outputID: 2)
        ledger.transition(handle: 4, to: .decoding)
        ledger.transition(handle: 4, to: .decoded)
        ledger.transition(handle: 4, to: .uploading)
        ledger.transition(
            handle: 4,
            to: .resident,
            changesVisibleContent: true)
        let beforeEviction = ledger.outputRevision(2)

        #expect(ledger.evict(4) == [2])
        #expect(ledger.phase(for: 4) == nil)
        #expect(ledger.outputRevision(2) > beforeEviction)
    }
}
