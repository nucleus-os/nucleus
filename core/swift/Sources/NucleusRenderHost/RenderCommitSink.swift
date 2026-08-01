// The Swift-direct producer commit sink.
//
// `RenderCommitSink` is the `NucleusLayers.CommitSink` the layers `Context`
// writes to. Each `commit(_:)` lowers the materialized layer batch through
// `RenderTransactionLowering` and folds the result into an owned
// `RetainedTreeStore`.

package import NucleusLayers
package import NucleusRenderModel

@MainActor
package final class RenderCommitSink: NucleusLayers.CommitSink {
    /// The authoritative retained tree this sink feeds. Exposed for inspection by
    /// the frame walk (at the cutover) and by fixtures.
    package let store: NucleusRenderModel.RetainedTreeStore

    /// The layers `Context`'s resource-host identity. Registrars validate it
    /// against this sink's concrete runtime graph.
    package let resourceHostHandle: UInt64
    package let runtimeHost: LayerRuntimeHost

    /// The most recently lowered transaction (before ingest). Exposed for
    /// inspection by fixtures that assert the lowered deltas directly — the
    /// retained tree only retains the folded result, not the transaction deltas.
    package private(set) var lastLowered: NucleusRenderModel.Transaction?
    private var completionObserverID: UInt64 = 0
    private let requestFrame: @MainActor () -> Void

    package init(
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

    package func commit(
        _ transaction: NucleusLayers.LayerTransactionBatch
    ) throws(NucleusLayers.LayerError) {
        let lowered = RenderTransactionLowering.lower(transaction)
        lastLowered = lowered
        if case .failure(let error) = store.ingest(lowered) {
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
