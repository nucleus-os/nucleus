@testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext)
struct UIHostServicesTests {
    private final class LifecyclePasteboardAdapter: PasteboardAdapter {
        var string: String?
        private(set) var shutdownCount = 0

        func readString() async throws(PasteboardFailure) -> String? {
            string
        }

        func writeString(
            _ string: String
        ) async throws(PasteboardFailure) {
            self.string = string
        }

        func clear() async throws(PasteboardFailure) {
            string = nil
        }

        func shutdown() {
            shutdownCount += 1
        }
    }

    @Test
    func pasteboardsAreContextLocalAndNativeEmptyDoesNotRevealOldContent()
        async throws
    {
        let first = UIContext(services: .inMemory())
        let second = UIContext(services: .inMemory())

        try await first.services.pasteboard.writeString("first")
        try await second.services.pasteboard.writeString("second")
        #expect(try await first.services.pasteboard.readString() == "first")
        #expect(try await second.services.pasteboard.readString() == "second")

        try await first.services.pasteboard.clear()
        #expect(try await first.services.pasteboard.readString() == nil)
        #expect(try await second.services.pasteboard.readString() == "second")
    }

    @Test
    func pasteboardStronglyOwnsAndShutsDownEachAdapterExactlyOnce() {
        var first: LifecyclePasteboardAdapter? =
            LifecyclePasteboardAdapter()
        weak let weakFirst = first
        var pasteboard: Pasteboard? = Pasteboard(adapter: first!)
        first = nil

        #expect(weakFirst != nil)

        let second = LifecyclePasteboardAdapter()
        pasteboard?.replaceAdapter(second)
        #expect(weakFirst == nil)
        #expect(second.shutdownCount == 0)

        pasteboard?.shutdown()
        #expect(second.shutdownCount == 1)
        pasteboard = nil
        #expect(second.shutdownCount == 1)
    }

    @Test
    func requiredTextBackendFailureUsesTheTypedDiagnosticSink() {
        let textSystem = TextSystem()
        var diagnostics: [UIHostDiagnostic] = []
        let services = UIHostServices(
            textSystem: textSystem,
            pasteboard: Pasteboard(
                adapter: UnavailablePasteboardAdapter()),
            imageSourceResolver: .directResourcesOnly,
            diagnosticSink: { diagnostics.append($0) })

        #expect(!services.validateForRetainedMaterialization())
        #expect(diagnostics == [
            UIHostDiagnostic(
                service: .text,
                operation: "materialize-retained-ui",
                generation: 0,
                failure: .text(.missingBackend)),
        ])
    }
}
