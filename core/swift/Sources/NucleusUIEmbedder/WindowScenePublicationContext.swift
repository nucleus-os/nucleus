import NucleusLayers
import NucleusUI

// The embedder tier may name layer-model types directly; that is what
// distinguishes it from the product tier. NucleusUI used to re-export
// `CommitSink` and `Layer` as SPI typealiases, which made every downstream
// signature naming them SPI as well. They are gone — an embedder imports
// `NucleusLayers`.

@MainActor
public final class WindowScenePublicationContext: ~Sendable {
    public let semanticContext: Context
    /// The context embedder-owned content is minted into, so an embedder can
    /// build its own scene-attached objects (the compositor's hosted surfaces)
    /// in the same context as this scene's layers.
    public let visualContext: Context

    public init(
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

    public func withSemanticContext<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try Application.withContext(semanticContext, body)
    }

    public func makeWindowScene(windows: [Window]) -> WindowScene {
        WindowScene(windows: windows, visualContext: visualContext)
    }
}
