import NucleusLayers

public enum Application {
    @MainActor
    package static let defaultContext: Context = {
        // Fallback for code that reads `currentContext` before any real
        // context is pushed. `InMemoryCommitSink` captures transactions
        // without forwarding to a host, so `NucleusUI` doesn't pull the render
        // host.
        do {
            return try Context(id: .root, commitSink: InMemoryCommitSink())
        } catch {
            preconditionFailure("root in-memory NucleusUI context must be constructible: \(error)")
        }
    }()

    @MainActor
    private static var contextStack: [Context] = []

    @MainActor
    package static var currentContext: Context {
        contextStack.last ?? defaultContext
    }

    @MainActor
    package static func withContext<T>(
        _ context: Context,
        _ body: () throws -> T
    ) rethrows -> T {
        pushContext(context)
        defer { popContext() }
        return try body()
    }

    /// Imperative counterpart to `withContext` for callers that cannot express their
    /// context scope as a single closure — chiefly an app entry (`NucleusApp`) that
    /// materializes a scene graph capturing non-`Sendable` state the closure form would
    /// flag under region isolation. Push before materializing, `popContext()` after
    /// (pair them with `defer`). Main-actor state, like `withContext`.
    @MainActor
    package static func pushContext(_ context: Context) {
        contextStack.append(context)
    }

    @MainActor
    package static func popContext() {
        _ = contextStack.popLast()
    }

    public static func run(_ body: () throws(UIError) -> Void) throws(UIError) {
        try body()
    }
}
