import NucleusTextBackend
import NucleusUI
import Testing

private enum TestUIClockScope {
    @TaskLocal static var current: ManualUIClock?
}

/// Gives every UI behavior suite a fresh explicit semantic owner. The task-local
/// scope follows async child tasks while keeping concurrently running suites in
/// distinct identity and environment namespaces.
package struct UIContextTrait: SuiteTrait, TestScoping {
    package var isRecursive: Bool { false }

    package init() {}

    package func provideScope(
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
        let clock = ManualUIClock()
        let context = UIContext(
            services: UIHostServices(
                textSystem: textSystem,
                pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
                imageSourceResolver: .directResourcesOnly,
                diagnosticSink: { _ in }
            ),
            clock: clock.clock
        )
        try await TestUIClockScope.$current.withValue(clock) {
            try await Application.withUIContext(context, function)
        }
    }
}

@MainActor
package func testUIContext() -> UIContext {
    Application.currentUIContext
}

@MainActor
package func testTextSystem() -> TextSystem {
    testUIContext().services.textSystem
}

@MainActor
package func testUIClock() -> ManualUIClock {
    guard let clock = TestUIClockScope.current else {
        preconditionFailure("UI clock requested outside UIContextTrait scope")
    }
    return clock
}

extension Trait where Self == UIContextTrait {
    package static var uiContext: Self { UIContextTrait() }
}
