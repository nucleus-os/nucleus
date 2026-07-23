// The Swift-direct producer commit sink.
//
// `RenderCommitSink` is the `NucleusLayers.CommitSink` the layers `Context`
// writes to. Each `commit(_:)` lowers the encoded layers transaction through
// `RenderTransactionLowering` and folds the result into an owned
// `RetainedTreeStore`. Nothing wires this live yet; it lands additive +
// fixture-proven.

public import NucleusLayers
public import NucleusRenderModel

@MainActor
public final class RenderCommitSink: NucleusLayers.CommitSink {
    /// The authoritative retained tree this sink feeds. Exposed for inspection by
    /// the frame walk (at the cutover) and by fixtures.
    public let store: NucleusRenderModel.RetainedTreeStore

    /// The layers `Context`'s resource-host identity in its C-compatible scalar
    /// form. Registrars validate it against this sink's concrete runtime graph.
    public let resourceHostHandle: UInt64
    public let runtimeHost: LayerRuntimeHost

    /// The most recently lowered transaction (before ingest). Exposed for
    /// inspection by fixtures that assert the lowered deltas directly — the
    /// retained tree only retains the folded result, not the wire deltas.
    public private(set) var lastLowered: NucleusRenderModel.Transaction?
    private var completionObserverID: UInt64 = 0
    private let requestFrame: @MainActor () -> Void

    public init(
        store: NucleusRenderModel.RetainedTreeStore,
        resourceHost: NucleusRenderModel.SwiftResourceHost,
        runtimeHost: LayerRuntimeHost,
        requestFrame: @escaping @MainActor () -> Void = {}
    ) {
        precondition(
            store.resourceHost === resourceHost,
            "commit sink store and resource host must share one runtime graph")
        self.store = store
        self.resourceHostHandle = resourceHost.identity.rawValue
        self.runtimeHost = runtimeHost
        self.requestFrame = requestFrame
        completionObserverID = store.addCompletionObserver { event in
            let result: PresentationCompletionResult
            switch event.outcome {
            case .completed:
                result = .completed
            case .cancelled:
                result = .cancelled
            case .superseded:
                result = .superseded
            case .failed:
                result = .failed
            }
            runtimeHost.presentationCompletions.resolve(
                rawToken: event.token,
                result: result
            )
        }
    }

    isolated deinit {
        if completionObserverID != 0 {
            store.removeCompletionObserver(completionObserverID)
        }
    }

    public func commit(_ transaction: NucleusLayers.EncodedTransaction) throws(NucleusLayers.LayerError) {
        let lowered = RenderTransactionLowering.lower(transaction)
        lastLowered = lowered
        if case let .failure(error) = store.ingest(lowered) {
            var tokens = Set(
                transaction.animationsAdded.map { $0.animation.completionToken }
            )
            tokens.insert(transaction.completionToken)
            for token in tokens where token != 0 {
                runtimeHost.presentationCompletions.resolve(
                    rawToken: token,
                    result: .failed
                )
            }
            throw .backendFailure(detail: "render transaction rejected: \(error)")
        }
        requestFrame()
    }
}
