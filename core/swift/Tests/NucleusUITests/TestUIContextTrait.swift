import Testing
@testable import NucleusUI

/// Every behavior suite gets a fresh explicit semantic owner. The task-local
/// scope follows async child tasks while keeping concurrently running suites in
/// distinct identity and environment namespaces.
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
        let context = UIContext()
        try await Application.withUIContext(context, function)
    }
}

extension Trait where Self == UIContextTrait {
    static var uiContext: Self { UIContextTrait() }
}
