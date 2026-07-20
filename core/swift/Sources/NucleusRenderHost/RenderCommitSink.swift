// The Swift-direct producer commit sink.
//
// `RenderCommitSink` is the `NucleusLayers.CommitSink` the layers `Context`
// writes to. Each `commit(_:)` lowers the encoded layers transaction through
// `RenderTransactionLowering` and folds the result into an owned
// `RetainedTreeStore`. Nothing wires this live yet; it lands additive +
// fixture-proven.

import NucleusLayers
import NucleusRenderModel

/// Installed by a presentation host to turn an accepted, damaging scene
/// transaction into hardware frame demand. The retained store and the wakeup are
/// one commit consequence; callers no longer race a request made before authoring.
@MainActor
public enum SceneCommitFrameDemand {
    private static var handler: (@MainActor () -> Void)?

    public static func install(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public static func clear() {
        handler = nil
    }

    static func request() {
        handler?()
    }
}

@MainActor
public final class RenderCommitSink: NucleusLayers.CommitSink {
    /// The authoritative retained tree this sink feeds. Exposed for inspection by
    /// the frame walk (at the cutover) and by fixtures.
    public let store: NucleusRenderModel.RetainedTreeStore

    /// The layers `Context`'s resource-host handle. Non-zero so the Swift
    /// resource-host registrars (paint/snapshot/image) accept registrations from
    /// contexts on this sink; the handle itself is ignored (the resource host is
    /// a process global).
    public let resourceHostHandle: UInt64

    /// The most recently lowered transaction (before ingest). Exposed for
    /// inspection by fixtures that assert the lowered deltas directly — the
    /// retained tree only retains the folded result, not the wire deltas.
    public private(set) var lastLowered: NucleusRenderModel.Transaction?
    private var completionObserverID: UInt64 = 0

    public init(
        store: NucleusRenderModel.RetainedTreeStore = .shared,
        resourceHostHandle: UInt64 = RenderCommitSink.productionResourceHostHandle
    ) {
        self.store = store
        self.resourceHostHandle = resourceHostHandle
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
            PresentationCompletionCenter.resolve(
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

    /// The well-known non-zero resource-host handle the Swift-direct path uses.
    /// The layers paint/snapshot/image registrars validate `handle != 0` and
    /// otherwise ignore it (the Swift resource host is a process global), so any
    /// stable non-zero value works; `1` matches the legacy production handle.
    public static let productionResourceHostHandle: UInt64 = 1

    public func commit(_ transaction: NucleusLayers.EncodedTransaction) throws(NucleusLayers.LayerError) {
        let lowered = RenderTransactionLowering.lower(transaction)
        lastLowered = lowered
        if case let .failure(error) = store.ingest(lowered) {
            var tokens = Set(
                transaction.animationsAdded.map { $0.animation.completionToken }
            )
            tokens.insert(transaction.completionToken)
            for token in tokens where token != 0 {
                PresentationCompletionCenter.resolve(
                    rawToken: token,
                    result: .failed
                )
            }
            throw .backendFailure(detail: "render transaction rejected: \(error)")
        }
        SceneCommitFrameDemand.request()
    }
}
