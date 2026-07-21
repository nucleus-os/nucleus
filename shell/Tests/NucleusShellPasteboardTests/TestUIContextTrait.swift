import NucleusUI
import Testing

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
        try await UIContext(services: .inMemory()).construct(function)
    }
}

extension Trait where Self == UIContextTrait {
    static var uiContext: Self { UIContextTrait() }
}
