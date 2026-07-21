import NucleusLayers

public enum Application {
    private struct Scope: @unchecked Sendable {
        var uiContext: UIContext
    }

    /// Construction context follows the task instead of living on a
    /// process-wide push/pop stack. The references remain main-actor confined;
    /// `@unchecked Sendable` only permits task-local propagation of the holder.
    @TaskLocal
    private static var constructionScope: Scope?

    @MainActor
    package static var currentUIContext: UIContext {
        guard let uiContext = constructionScope?.uiContext else {
            preconditionFailure(
                "semantic UI construction requires an explicit UIContext; "
                    + "use UIContext.construct { ... } or a host-owned scene "
                    + "construction scope"
            )
        }
        return uiContext
    }

    @MainActor
    package static func makeInMemoryVisualContext(
        runtimeHost: LayerRuntimeHost = .inMemory()
    ) -> Context {
        do {
            return try Context(
                commitSink: InMemoryCommitSink(runtimeHost: runtimeHost))
        } catch {
            preconditionFailure(
                "in-memory visual context must be constructible: \(error)")
        }
    }

    @MainActor
    package static func withContext<T>(
        _ context: Context,
        _ body: () throws -> T
    ) rethrows -> T {
        let uiContext = UIContext(
            services: .inMemory(),
            resourceHostHandle: context.commitSink.resourceHostHandle,
            runtimeHost: context.runtimeHost)
        return try withContexts(
            uiContext: uiContext,
            visualContext: context,
            body
        )
    }

    @MainActor
    package static func withContexts<T>(
        uiContext: UIContext,
        visualContext: Context,
        _ body: () throws -> T
    ) rethrows -> T {
        precondition(
            uiContext.resourceHostHandle == 0
                || uiContext.resourceHostHandle
                    == visualContext.commitSink.resourceHostHandle,
            "UIContext and visual Context belong to different resource hosts")
        precondition(
            uiContext.runtimeHost === visualContext.runtimeHost,
            "UIContext and visual Context belong to different runtime hosts")
        return try $constructionScope.withValue(
            Scope(uiContext: uiContext),
            operation: body
        )
    }

    @MainActor
    package static func withUIContext<T>(
        _ uiContext: UIContext,
        _ body: () throws -> T
    ) rethrows -> T {
        try $constructionScope.withValue(
            Scope(uiContext: uiContext),
            operation: body
        )
    }

    @MainActor
    package static func withUIContext<T>(
        _ uiContext: UIContext,
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $constructionScope.withValue(
            Scope(uiContext: uiContext),
            operation: body
        )
    }

    public static func run(_ body: () throws(UIError) -> Void) throws(UIError) {
        try body()
    }
}
