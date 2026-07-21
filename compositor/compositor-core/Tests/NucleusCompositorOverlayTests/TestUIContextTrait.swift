import NucleusUI
import NucleusTextBackend
import Testing

private struct TestUIContextScope: @unchecked Sendable {
    let context: UIContext
}

private enum TestUIContextStorage {
    @TaskLocal static var scope: TestUIContextScope?
}

/// Give every UI behavior case an independent explicit semantic owner.
struct UIContextTrait: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Self.provideMainActorScope(performing: function)
    }

    @MainActor
    private static func provideMainActorScope(
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let textSystem = TextSystem()
        SkiaTextLayoutBackend.install(in: textSystem)
        let context = UIContext(services: UIHostServices(
            textSystem: textSystem,
            pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
            imageSourceResolver: .directResourcesOnly,
            diagnosticSink: { _ in }))
        try await TestUIContextStorage.$scope.withValue(
            TestUIContextScope(context: context)
        ) {
            try await context.construct(function)
        }
    }
}

extension Trait where Self == UIContextTrait {
    static var uiContext: Self { UIContextTrait() }
}

@MainActor
func testUIContext() -> UIContext {
    guard let context = TestUIContextStorage.scope?.context else {
        preconditionFailure("a compositor UI test requires .uiContext")
    }
    return context
}

@MainActor
func testHostServices() -> UIHostServices {
    testUIContext().services
}

@MainActor
func testTextSystem() -> TextSystem {
    testHostServices().textSystem
}
