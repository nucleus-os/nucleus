public import NucleusLayers
public import NucleusUI

// The embedder tier may name layer-model types directly; that is what
// distinguishes it from the product tier. NucleusUI used to re-export
// `CommitSink` and `Layer` as SPI typealiases, which made every downstream
// signature naming them SPI as well. They are gone — an embedder imports
// `NucleusLayers`.

@MainActor
public final class WindowScenePublicationContext: ~Sendable {
    public let semanticContext: UIContext
    /// The context embedder-owned content is minted into, so an embedder can
    /// build its own scene-attached objects (the compositor's hosted surfaces)
    /// in the same context as this scene's layers.
    public let visualContext: Context

    public init(
        visualContextID: ContextID = .shellOverlay,
        commitSink: any CommitSink,
        services: UIHostServices,
        environment: UIEnvironment = UIEnvironment()
    ) throws(UIError) {
        guard services.validateForRetainedMaterialization() else {
            throw UIError.backendFailure(
                detail: "a production text backend is required before retained UI materialization")
        }
        do {
            let visualContext = try Context(id: visualContextID, commitSink: commitSink)
            self.visualContext = visualContext
            self.semanticContext = UIContext(
                services: services,
                environment: environment,
                resourceHostHandle: visualContext.commitSink.resourceHostHandle,
                runtimeHost: visualContext.runtimeHost)
        } catch let error {
            throw UIError.invalidArgument(detail: String(describing: error))
        }
    }

    public func withSemanticContext<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try Application.withContexts(
            uiContext: semanticContext,
            visualContext: visualContext,
            body
        )
    }

    public func makeWindowScene(windows: [Window]) -> WindowScene {
        WindowScene(
            windows: windows,
            uiContext: semanticContext,
            visualContext: visualContext)
    }
}
