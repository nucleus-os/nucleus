// The Swift `LayerTree` becomes the authoritative scene the compositor presents.
// `RetainedTreeStore` is its live owner: it folds committed render-layer
// `Transaction`s into the tree through `TransactionApplier.apply`, tracks a
// monotonic revision and an aggregate present-dirty flag, and hands the current
// tree to the `FrameDriver` walk. The producer feed writes it and the renderer
// reads it.
//
// It runs on the compositor's main actor, the same executor the rest of the
// runtime services use, so ingest (driven by the producer's commit) and the
// per-frame read (driven by the reactor) never cross executors.
//
// Damage discipline: the applier marks per-node
// invalidation flags as it folds a transaction; a frame consumes them and
// `markPresented` clears them so the next frame's demand reflects only new work.

/// Owns the authoritative `LayerTree` and the present-demand bookkeeping the
/// frame loop reads.
@MainActor
public final class RetainedTreeStore {
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
    /// added starts from its begin time.
    public private(set) var previousPresentTimeS: Double = 0

    /// Accumulated animation lifecycle events (started on add, stopped on tick),
    /// for the producer feed's transaction-completion matching. Drained by
    /// `drainAnimationEvents`.
    public private(set) var animationEvents: [AnimationEvent] = []
    private var activeAnimationsByCompletionToken: [UInt64: Int] = [:]
    private var terminalCompletionsAwaitingPresentation: [
        UInt64: PresentationCompletionOutcome
    ] = [:]
    private var completionObservers: [
        UInt64: @MainActor (PresentationCompletionEvent) -> Void
    ] = [:]
    private var nextCompletionObserverID: UInt64 = 1
    private var nextImplicitAnimationID: UInt64 = 1
    public let resourceHost: SwiftResourceHost

    public init(
        resourceHost: SwiftResourceHost
    ) {
        self.resourceHost = resourceHost
    }

    /// Fold one committed transaction into the authoritative tree. An empty
    /// transaction is a no-op — it neither bumps the revision nor dirties the
    /// present state, matching the queue's coalescing contract.
    @discardableResult
    public func ingest(
        _ incoming: Transaction
    ) -> Result<Void, TransactionApplier.ApplyError> {
        var txn = incoming
        if txn.isEmpty { return .success(()) }
        txn.animationsAdded.append(contentsOf: expandImplicitActions(in: txn))
        var lifecycleEvents: [AnimationEvent] = []
        for removal in txn.removed {
            guard let layer = tree.layers[removal.nodeId] else { continue }
            for record in layer.animations {
                lifecycleEvents.append(.stopped(
                    animationId: record.id,
                    layerId: record.layerId,
                    keyPath: record.keyPath,
                    completionToken: record.completionToken,
                    transactionId: record.transactionId,
                    finished: false,
                    reason: .layerRemoved
                ))
            }
        }
        let result = TransactionApplier.apply(txn, to: &tree)
        guard case .success = result else { return result }
        for record in txn.animationsAdded {
            guard let index = tree.layers.index(forKey: record.layerId) else {
                if record.completionToken.raw != 0 {
                    terminalCompletionsAwaitingPresentation[
                        record.completionToken.raw
                    ] = .failed
                }
                continue
            }
            var node = MutableRef(&tree.layers.values[index])
            node.value.addAnimation(record, events: &lifecycleEvents)
            node.value.seedAnimationStartValue(record)
            node.value.damage.flags.property = true
        }
        for removal in txn.animationsRemoved {
            guard let index = tree.layers.index(forKey: removal.layerId) else {
                continue
            }
            var node = MutableRef(&tree.layers.values[index])
            node.value.removeAnimation(
                for: removal.keyPath,
                events: &lifecycleEvents
            )
            node.value.damage.flags.property = true
        }
        animationEvents.append(contentsOf: lifecycleEvents)
        processAnimationLifecycle(lifecycleEvents)
        if txn.completionToken != 0,
           !txn.animationsAdded.contains(where: {
               $0.completionToken.raw == txn.completionToken
           })
        {
            mergeTerminalOutcome(.completed, for: txn.completionToken)
        }
        revision &+= 1
        presentDirty = true
        return result
    }

    /// The current authoritative tree. Handed to `PresentationWalk.buildFramePlan`
    /// each frame; value semantics give the walk a stable snapshot even if a
    /// commit lands mid-frame.
    public func snapshot() -> LayerTree { tree }

    /// Producer-authored final value for an animatable property.
    public func modelValue(
        layerID: UInt64,
        keyPath: AnimationKeyPath
    ) -> AnimationValue? {
        guard let layer = tree.layers[layerID] else { return nil }
        return value(for: keyPath, on: layer, usesPresentation: false)
    }

    /// Value currently displayed by the renderer, including any in-flight
    /// presentation override.
    public func presentationValue(
        layerID: UInt64,
        keyPath: AnimationKeyPath
    ) -> AnimationValue? {
        guard let layer = tree.layers[layerID] else { return nil }
        return value(for: keyPath, on: layer, usesPresentation: true)
    }

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
        let firstNewEvent = animationEvents.count
        // Snapshot stable indices before taking exclusive MutableRefs. Iterating
        // the dictionary directly would keep an overlapping read access alive;
        // the index snapshot also avoids hashing every already-known key again.
        for index in Array(tree.layers.indices) {
            var node = MutableRef(&tree.layers.values[index])
            guard !node.value.animations.isEmpty else { continue }
            let active = node.value.tickAnimations(
                previousPresentTimeS: previous, presentTimeS: presentTimeS,
                events: &animationEvents)
            // The tick wrote presentation overrides / model values; mark the
            // node dirty so the frame loop re-composites it.
            node.value.damage.flags.property = true
            if active { anyActive = true }
        }
        processAnimationLifecycle(Array(animationEvents[firstNewEvent...]))
        if anyActive { presentDirty = true }
        return anyActive
    }

    /// Add (or velocity-preservingly replace) an animation record on a layer and
    /// seed its presentation override to the record's start value. The producer
    /// feed's entry for in-flight animations; also dirties the node. No-op when
    /// the layer is absent. Mirrors `addAnimationToLayer` +
    /// `seedAnimationStartValueOnLayer`.
    public func addAnimation(layerId: UInt64, _ record: AnimationRecord, seedStartValue: Bool = true) {
        guard let index = tree.layers.index(forKey: layerId) else { return }
        var node = MutableRef(&tree.layers.values[index])
        let firstNewEvent = animationEvents.count
        node.value.addAnimation(record, events: &animationEvents)
        if seedStartValue { node.value.seedAnimationStartValue(record) }
        node.value.damage.flags.property = true
        processAnimationLifecycle(Array(animationEvents[firstNewEvent...]))
        presentDirty = true
    }

    /// Drain the accumulated animation lifecycle events (clearing the buffer).
    /// The producer feed consumes these for transaction-completion matching.
    public func drainAnimationEvents() -> [AnimationEvent] {
        let events = animationEvents
        animationEvents.removeAll(keepingCapacity: true)
        return events
    }

    @discardableResult
    public func addCompletionObserver(
        _ observer: @escaping @MainActor (PresentationCompletionEvent) -> Void
    ) -> UInt64 {
        let id = nextCompletionObserverID
        nextCompletionObserverID &+= 1
        precondition(nextCompletionObserverID != 0, "completion observer space exhausted")
        completionObservers[id] = observer
        return id
    }

    public func removeCompletionObserver(_ id: UInt64) {
        completionObservers[id] = nil
    }

    /// Acknowledge that a frame carrying the committed work has presented: clear
    /// the present-dirty flag and every node's per-frame damage so the next
    /// frame's demand reflects only work committed after this point.
    public func markPresented() {
        presentDirty = false
        // As in `tick`, snapshot indices before taking exclusive references and
        // avoid re-hashing every retained layer just to clear frame-local state.
        for index in Array(tree.layers.indices) {
            var node = MutableRef(&tree.layers.values[index])
            node.value.damage = DamageState()
        }
        let completions: [PresentationCompletionEvent] =
            terminalCompletionsAwaitingPresentation.keys.sorted().compactMap { token in
                guard let outcome = terminalCompletionsAwaitingPresentation[token] else {
                    return nil
                }
                return PresentationCompletionEvent(token: token, outcome: outcome)
            }
        terminalCompletionsAwaitingPresentation.removeAll(keepingCapacity: true)
        for event in completions {
            for observer in completionObservers.values {
                observer(event)
            }
        }
    }

    private func processAnimationLifecycle(_ events: [AnimationEvent]) {
        var affectedTokens = Set<UInt64>()
        for event in events {
            switch event {
            case .started(_, _, _, let completionToken, _):
                guard completionToken.raw != 0 else { continue }
                affectedTokens.insert(completionToken.raw)
                activeAnimationsByCompletionToken[completionToken.raw, default: 0] += 1
            case .stopped(
                _, _, _, let completionToken, _, _, let reason
            ):
                guard completionToken.raw != 0 else { continue }
                affectedTokens.insert(completionToken.raw)
                let count = activeAnimationsByCompletionToken[
                    completionToken.raw,
                    default: 0
                ]
                activeAnimationsByCompletionToken[completionToken.raw] = max(0, count - 1)
                mergeTerminalOutcome(
                    completionOutcome(for: reason),
                    for: completionToken.raw
                )
            }
        }
        for token in affectedTokens
        where activeAnimationsByCompletionToken[token, default: 0] > 0 {
            terminalCompletionsAwaitingPresentation[token] = nil
        }
        for token in affectedTokens
        where activeAnimationsByCompletionToken[token, default: 0] == 0 {
            activeAnimationsByCompletionToken[token] = nil
        }
    }

    private func completionOutcome(
        for reason: AnimationStopReason
    ) -> PresentationCompletionOutcome {
        switch reason {
        case .completed:
            .completed
        case .replaced:
            .superseded
        case .removed, .layerRemoved, .cancelledBeforeStart:
            .cancelled
        case .targetMissing:
            .failed
        }
    }

    private func mergeTerminalOutcome(
        _ outcome: PresentationCompletionOutcome,
        for token: UInt64
    ) {
        guard token != 0 else { return }
        guard let current = terminalCompletionsAwaitingPresentation[token] else {
            terminalCompletionsAwaitingPresentation[token] = outcome
            return
        }
        if completionPriority(outcome) > completionPriority(current) {
            terminalCompletionsAwaitingPresentation[token] = outcome
        }
    }

    private func completionPriority(_ outcome: PresentationCompletionOutcome) -> Int {
        switch outcome {
        case .completed: 0
        case .superseded: 1
        case .cancelled: 2
        case .failed: 3
        }
    }

    private func expandImplicitActions(
        in transaction: Transaction
    ) -> [AnimationRecord] {
        let table = resourceHost.implicitActions
        var records: [AnimationRecord] = []

        for update in transaction.propertyUpdates {
            guard let layer = tree.layers[update.nodeId] else { continue }

            if update.usesDefaultFrameAction,
               let target = update.frame,
               let parameters = table.frameFor(layer.role),
               !transaction.animationsAdded.contains(where: {
                   $0.layerId == update.nodeId && $0.slotKey == .frame
               })
            {
                let position = layer.effectivePosition()
                let bounds = layer.effectiveBounds()
                let from = Frame(
                    left: position.x,
                    top: position.y,
                    right: position.x + bounds.w,
                    bottom: position.y + bounds.h
                )
                if from != target {
                    records.append(AnimationRecord(
                        id: allocateImplicitAnimationID(),
                        layerId: update.nodeId,
                        animation: .springFrame(SpringFrameAnimation(
                            keyPath: .frame,
                            fromValue: from,
                            toValue: target,
                            mass: parameters.mass,
                            stiffness: parameters.stiffness,
                            damping: parameters.damping,
                            beginTime: transaction.animationBeginTimeSeconds
                        )),
                        completionToken: CompletionToken(
                            raw: transaction.completionToken
                        ),
                        transactionId: transaction.revision,
                        beginTimePending:
                            transaction.animationBeginTimePending
                    ))
                }
            }

            if update.usesDefaultOpacityAction,
               let target = update.opacity,
               let parameters = table.opacityFor(layer.role),
               !transaction.animationsAdded.contains(where: {
                   $0.layerId == update.nodeId && $0.slotKey == .opacity
               })
            {
                let from = layer.effectiveOpacity()
                if from != target {
                    records.append(AnimationRecord(
                        id: allocateImplicitAnimationID(),
                        layerId: update.nodeId,
                        animation: .basic(BasicAnimation(
                            keyPath: .opacity,
                            fromValue: from,
                            toValue: target,
                            duration: parameters.duration,
                            timingFunction: parameters.timingFunction,
                            beginTime: transaction.animationBeginTimeSeconds
                        )),
                        completionToken: CompletionToken(
                            raw: transaction.completionToken
                        ),
                        transactionId: transaction.revision,
                        beginTimePending:
                            transaction.animationBeginTimePending
                    ))
                }
            }
        }
        return records
    }

    private func allocateImplicitAnimationID() -> AnimationID {
        let id = nextImplicitAnimationID
        nextImplicitAnimationID &+= 1
        precondition(
            nextImplicitAnimationID != 0,
            "implicit animation identity exhausted"
        )
        // Reserve the high bit to avoid collisions with ordinary producer IDs.
        return AnimationID(raw: id | (1 << 63))
    }

    private func value(
        for keyPath: AnimationKeyPath,
        on layer: Layer,
        usesPresentation: Bool
    ) -> AnimationValue? {
        let position = usesPresentation
            ? layer.effectivePosition()
            : layer.model.properties.position
        let bounds = usesPresentation
            ? layer.effectiveBounds()
            : layer.model.properties.bounds
        let anchor = usesPresentation
            ? layer.effectiveAnchorPoint()
            : layer.model.properties.anchorPoint
        let scroll = usesPresentation
            ? layer.effectiveScrollOffset()
            : layer.model.properties.scrollOffset
        return switch keyPath {
        case .positionX: .scalar(position.x)
        case .positionY: .scalar(position.y)
        case .opacity:
            .scalar(
                usesPresentation
                    ? layer.effectiveOpacity()
                    : layer.model.properties.opacity
            )
        case .transform:
            .transform(
                usesPresentation
                    ? layer.effectiveTransform()
                    : layer.model.properties.transform
            )
        case .anchorPointX: .scalar(anchor.x)
        case .anchorPointY: .scalar(anchor.y)
        case .cornerRadius:
            .scalar(
                usesPresentation
                    ? layer.effectiveCornerRadii().0
                    : layer.model.visualStyle?.cornerRadii.0 ?? 0
            )
        case .boundsWidth: .scalar(bounds.w)
        case .boundsHeight: .scalar(bounds.h)
        case .scrollOffsetX: .scalar(scroll.x)
        case .scrollOffsetY: .scalar(scroll.y)
        case .frame:
            .frame(Frame(
                left: position.x,
                top: position.y,
                right: position.x + bounds.w,
                bottom: position.y + bounds.h
            ))
        case .transformScaleX, .transformScaleY, .transformScaleZ,
             .transformRotationX, .transformRotationY, .transformRotationZ,
             .transformTranslationX, .transformTranslationY,
             .transformTranslationZ:
            nil
        }
    }
}
