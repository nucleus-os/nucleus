// The Swift `LayerTree` becomes the authoritative scene the compositor presents.
// `RetainedTreeStore` is its live owner: it folds committed render-layer
// `Transaction`s into the tree through `TransactionApplier.apply`, tracks a
// monotonic revision and an aggregate present-dirty flag, and hands the current
// tree to the `FrameDriver` walk. This is the owner the producer feed
// (10b.6b — the layers→render lowering + commit sink) writes and the renderer
// reads.
//
// It runs on the compositor's main actor, the same executor the rest of the
// runtime services use, so ingest (driven by the producer's commit) and the
// per-frame read (driven by the reactor) never cross executors.
//
// Damage discipline: the applier marks per-node
// invalidation flags as it folds a transaction; a frame consumes them and
// `markPresented` clears them so the next frame's demand reflects only new work.

/// Owns the authoritative `LayerTree` and the present-demand bookkeeping the
/// frame loop reads, minus the renderer-owned backing/animation bookkeeping
/// that co-lands with the renderer.
@MainActor
public final class RetainedTreeStore {
    /// The process-global authoritative tree. Both the layers commit sink (the
    /// producer feed) and the renderer-owner (`RendererRuntime.store`) bind to
    /// this single instance, so committed transactions and the per-frame read
    /// share one tree whether or not a GPU renderer is up.
    public static let shared = RetainedTreeStore()

    /// The authoritative scene. Read by the frame-plan walk each frame.
    public private(set) var tree = LayerTree()

    /// Monotonic counter bumped on every non-empty ingest. The frame loop pairs
    /// it with the last-presented revision to detect un-presented work without
    /// re-scanning the tree.
    public private(set) var revision: UInt64 = 0

    /// True when committed work has not yet been presented. Set by any non-empty
    /// ingest, cleared by `markPresented`. Drives the render-demand `frameDue`
    /// term.
    public private(set) var presentDirty = false

    /// The present time the last `tick` advanced to (seconds). Spring animations
    /// integrate over `[previous, present]`, so the first tick after a record is
    /// added starts from its begin time. Mirrors the render server's
    /// `previous_animation_present_time_s`.
    public private(set) var previousPresentTimeS: Double = 0

    /// Accumulated animation lifecycle events (started on add, stopped on tick),
    /// for the producer feed's transaction-completion matching. Drained by
    /// `drainAnimationEvents`. Mirrors the render server's `animation_events`
    /// queue.
    public private(set) var animationEvents: [AnimationEvent] = []

    /// Sink the `.contents` key path drives during a presentation transition.
    /// Defaults to a no-op; the renderer installs a `PresentationOperationService`
    /// bridge once transitions are wired (a later slice). Mirrors the render
    /// server's `operationProgressSink`.
    private let transitionSink: PresentationTransitionSink

    public init(transitionSink: PresentationTransitionSink = NullPresentationTransitionSink()) {
        self.transitionSink = transitionSink
    }

    /// Fold one committed transaction into the authoritative tree. An empty
    /// transaction is a no-op — it neither bumps the revision nor dirties the
    /// present state, matching the queue's coalescing contract.
    @discardableResult
    public func ingest(_ txn: Transaction) -> Result<Void, TransactionApplier.ApplyError> {
        if txn.isEmpty { return .success(()) }
        let result = TransactionApplier.apply(txn, to: &tree)
        guard case .success = result else { return result }
        revision &+= 1
        presentDirty = true
        return result
    }

    /// The current authoritative tree. Handed to `PresentationWalk.buildFramePlan`
    /// each frame; value semantics give the walk a stable snapshot even if a
    /// commit lands mid-frame.
    public func snapshot() -> LayerTree { tree }

    /// The ids of every layer currently in the tree (across all contexts) — the
    /// liveness set the renderer reclaims per-layer GPU caches against when a
    /// layer is removed.
    public var liveLayerIDs: Set<UInt64> { Set(tree.layers.keys) }

    /// True when any retained node carries unconsumed invalidation. The aggregate
    /// the render-demand predicate reads alongside `presentDirty`.
    public var hasPendingDamage: Bool {
        for (_, node) in tree.layers where node.damage.flags.any() { return true }
        return false
    }

    /// True when any retained node has an in-flight animation. Continuous
    /// animation demand drives the frame loop independently of committed-content
    /// damage. Mirrors `RenderServer.hasActiveAnimations`.
    public var hasActiveAnimations: Bool {
        for (_, node) in tree.layers where !node.animations.isEmpty { return true }
        return false
    }

    /// Advance every layer's in-flight animations to `presentTimeNs` (nanoseconds,
    /// monotonic), applying interpolated values to presentation overrides, firing
    /// completion events, and committing final values to the model. Marks property
    /// damage on every node an animation touched so the frame loop renders it, and
    /// sets `presentDirty` while animations remain active. Returns true when any
    /// animation is still running. Mirrors `Composition.tickAnimations` →
    /// `tickTreeToPresentTimeAndApplyWithSink`.
    @discardableResult
    public func tick(presentTimeNs: UInt64) -> Bool {
        let presentTimeS = Double(presentTimeNs) / 1_000_000_000.0
        let previous = previousPresentTimeS
        previousPresentTimeS = presentTimeS

        var anyActive = false
        // Snapshot the keys first: iterating `tree.layers.keys` directly holds a
        // second reference to the dictionary storage, so each in-loop subscript
        // assignment would trigger a full copy-on-write — O(n²) per animated frame.
        for id in Array(tree.layers.keys) {
            guard var node = tree.layers[id], !node.animations.isEmpty else { continue }
            let active = node.tickAnimations(
                previousPresentTimeS: previous, presentTimeS: presentTimeS,
                events: &animationEvents, sink: transitionSink)
            // The tick wrote presentation overrides / model values; mark the
            // node dirty so the frame loop re-composites it.
            node.damage.flags.property = true
            tree.layers[id] = node
            if active { anyActive = true }
        }
        if anyActive { presentDirty = true }
        return anyActive
    }

    /// Add (or velocity-preservingly replace) an animation record on a layer and
    /// seed its presentation override to the record's start value. The producer
    /// feed's entry for in-flight animations; also dirties the node. No-op when
    /// the layer is absent. Mirrors `addAnimationToLayer` +
    /// `seedAnimationStartValueOnLayer`.
    public func addAnimation(layerId: UInt64, _ record: AnimationRecord, seedStartValue: Bool = true) {
        guard var node = tree.layers[layerId] else { return }
        node.addAnimation(record, events: &animationEvents)
        if seedStartValue { node.seedAnimationStartValue(record, sink: transitionSink) }
        node.damage.flags.property = true
        tree.layers[layerId] = node
        presentDirty = true
    }

    /// Drain the accumulated animation lifecycle events (clearing the buffer).
    /// The producer feed consumes these for transaction-completion matching.
    public func drainAnimationEvents() -> [AnimationEvent] {
        let events = animationEvents
        animationEvents.removeAll(keepingCapacity: true)
        return events
    }

    /// Acknowledge that a frame carrying the committed work has presented: clear
    /// the present-dirty flag and every node's per-frame damage so the next
    /// frame's demand reflects only work committed after this point. Mirrors the
    /// render server clearing `DamageState` once a frame consumes it.
    public func markPresented() {
        presentDirty = false
        // Array() snapshot avoids the copy-on-write-per-iteration hazard (see `tick`).
        for id in Array(tree.layers.keys) {
            tree.layers[id]?.damage.flags = .none
        }
    }
}
