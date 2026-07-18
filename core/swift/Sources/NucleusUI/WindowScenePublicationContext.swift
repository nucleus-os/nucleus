import NucleusLayers

@_spi(NucleusCompositor) public typealias CommitSink = NucleusLayers.CommitSink
@_spi(NucleusCompositor) public typealias Layer = NucleusLayers.Layer

@MainActor
@_spi(NucleusCompositor) public final class WindowScenePublicationContext: ~Sendable {
    package let semanticContext: Context
    /// The context embedder-owned content is minted into, so an embedder can
    /// build its own scene-attached objects (the compositor's hosted surfaces)
    /// in the same context as this scene's layers.
    @_spi(NucleusCompositor) public let visualContext: Context

    @_spi(NucleusCompositor) public init(
        visualContextID: ContextID = .shellOverlay,
        commitSink: any CommitSink
    ) throws(UIError) {
        do {
            self.semanticContext = try Context(id: .root, commitSink: InMemoryCommitSink())
            self.visualContext = try Context(id: visualContextID, commitSink: commitSink)
        } catch let error {
            throw UIError.invalidArgument(detail: String(describing: error))
        }
    }

    @_spi(NucleusCompositor) public func withSemanticContext<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try Application.withContext(semanticContext, body)
    }

    @_spi(NucleusCompositor) public func makeWindowScene(windows: [Window]) -> WindowScene {
        WindowScene(windows: windows, visualContext: visualContext)
    }
}
