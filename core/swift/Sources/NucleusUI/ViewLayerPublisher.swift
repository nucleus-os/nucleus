@_spi(NucleusCompositor) package import NucleusLayers
internal import enum NucleusTypes.LayerKind
import Tracy

package struct ViewLayerRootPlacement: Sendable, Equatable {
    package var id: WindowID
    package var frame: Rect

    package init(id: WindowID, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

package struct ViewLayerRootPublication: ~Sendable {
    package var view: View
    package var placement: ViewLayerRootPlacement?

    package init(view: View, placement: ViewLayerRootPlacement? = nil) {
        self.view = view
        self.placement = placement
    }
}

@MainActor
package final class ViewLayerPublisher: ~Sendable {
    package let context: Context

    var rootLayer: Layer?
    var rootCreated = false
    var rootAttached = false
    var rootParentID: LayerID?
    var rootSiblingIndex: UInt32 = UInt32.max
    weak var semanticContext: UIContext?
    var visualLayers: [ViewID: VisualLayerCache] = [:]
    var placementLayers: [WindowID: PlacementLayerCache] = [:]
    var paintCache: [PaintCacheKey: [PaintCacheEntry]] = [:]
    var retainedPaintRegistrationCountStorage = 0
    var publishedRootViewIDs: [ViewID] = []
    var hiddenVisualLayerCount = 0
    package private(set) var lastMetrics = ViewPublicationMetrics()

    package init(context: Context) {
        self.context = context
    }

    isolated deinit {
        do {
            try invalidate()
        } catch {
            preconditionFailure(
                "view-layer publisher teardown failed: \(error)")
        }
    }

    package func publish(
        roots: [View],
        rootParent: Layer? = nil,
        rootSiblingIndex: UInt32 = UInt32.max
    ) throws(UIError) -> [PublishedVisualContent] {
        try publish(
            roots: roots.map { ViewLayerRootPublication(view: $0) },
            rootParent: rootParent,
            rootSiblingIndex: rootSiblingIndex
        )
    }

    package func publish(
        roots: [ViewLayerRootPublication],
        rootParent: Layer? = nil,
        rootSiblingIndex: UInt32 = UInt32.max
    ) throws(UIError) -> [PublishedVisualContent] {
        precondition(
            rootParent == nil || rootParent?.context === context,
            "published root parent belongs to another visual context"
        )
        let traceZone = Trace.beginZone("nucleus.view_layer.publish", color: Trace.Color.blue)
        defer { traceZone.end() }

        if let firstContext = roots.first?.view.uiContext {
            precondition(
                roots.allSatisfy { $0.view.uiContext === firstContext },
                "one publication cannot mix UI contexts"
            )
            semanticContext = firstContext
        }

        // Layout and display produce pure semantic snapshots. No visual mutation
        // occurs until the commit sink accepts the journal assembled below.
        LayoutScheduler.run(roots: roots.map(\.view))

        var metrics = ViewPublicationMetrics()
        if canSkipPublication(
            roots: roots,
            rootParent: rootParent,
            rootSiblingIndex: rootSiblingIndex)
        {
            metrics.nodesVisited = UInt64(roots.count)
            metrics.cleanSubtreesSkipped = UInt64(roots.count)
            metrics.layersRetained = UInt64(visualLayers.count)
            metrics.layersHidden = UInt64(hiddenVisualLayerCount)
            for handle in semanticContext?.takeTransactionCompletions() ?? [] {
                handle.resolve(.completed)
            }
            lastMetrics = metrics
            publishMetrics(metrics)
            return publishedContents(for: roots)
        }

        var snapshots: [ViewLayerSnapshot] = []
        var traversalUpdates: [ViewID: TraversalUpdate] = [:]
        let currentRootViewIDs = Set(roots.map(\.view.id))
        var removalCandidates = Set(
            publishedRootViewIDs.filter {
                !currentRootViewIDs.contains($0)
            })
        var structurallyPresent = currentRootViewIDs
        var placementSnapshots: [PlacementSnapshot] = []
        var traversalWork: [TraversalWorkItem] = []
        for (index, publication) in roots.enumerated().reversed() {
            traversalWork.append(TraversalWorkItem(
                view: publication.view,
                parentViewID: nil,
                rootPlacementID: publication.placement?.id,
                siblingIndex: publication.placement == nil
                    ? UInt32(clamping: index)
                    : 0,
                forceSnapshot: false))
        }
        placementSnapshots.reserveCapacity(roots.count)
        for (index, publication) in roots.enumerated() {
            guard let placement = publication.placement else { continue }
            placementSnapshots.append(PlacementSnapshot(
                id: placement.id,
                frame: SnapshotRect(
                    x: placement.frame.origin.x,
                    y: placement.frame.origin.y,
                    width: placement.frame.size.width,
                    height: placement.frame.size.height
                ).geometryRect,
                siblingIndex: UInt32(clamping: index)
            ))
        }
        appendDirtyViewTrees(
            work: &traversalWork,
            snapshots: &snapshots,
            traversalUpdates: &traversalUpdates,
            removalCandidates: &removalCandidates,
            structurallyPresent: &structurallyPresent,
            metrics: &metrics)
        let removedViewIDs = removedCachedSubtrees(
            rootedAt: removalCandidates.subtracting(structurallyPresent))
        Trace.plot("swift.nucleus.view_layer.snapshots", UInt64(snapshots.count))

        try publish(
            snapshots: snapshots,
            placements: placementSnapshots,
            removedViewIDs: removedViewIDs,
            traversalUpdates: traversalUpdates,
            rootParent: rootParent,
            rootSiblingIndex: rootSiblingIndex,
            metrics: &metrics
        )
        for snapshot in snapshots {
            if let generation = visualLayers[snapshot.viewID]?.animationGeneration {
                snapshot.view.markAnimationRequestsPublished(through: generation)
            }
        }
        publishedRootViewIDs = roots.map(\.view.id)
        metrics.layersRetained = UInt64(visualLayers.count)
        metrics.layersHidden = UInt64(hiddenVisualLayerCount)
        lastMetrics = metrics
        publishMetrics(metrics)

        return publishedContents(for: roots)
    }

    func publishedContents(
        for roots: [ViewLayerRootPublication]
    ) -> [PublishedVisualContent] {
        roots.enumerated().compactMap { index, publication in
            guard let state = visualLayers[publication.view.id] else { return nil }
            let rootLayerID = publication.placement.flatMap {
                placementLayers[$0.id]?.layer.id.rawValue
            } ?? state.layer.id.rawValue
            return PublishedVisualContent(
                id: publication.placement?.id.rawValue ??
                    publication.view.id.rawValue,
                rootLayerID: rootLayerID,
                orderIndex: UInt32(clamping: index),
                visible: !publication.view.isHidden
            )
        }
    }

    func canSkipPublication(
        roots: [ViewLayerRootPublication],
        rootParent: Layer?,
        rootSiblingIndex: UInt32
    ) -> Bool {
        guard rootCreated,
              rootAttached,
              rootParentID == rootParent?.id,
              self.rootSiblingIndex == rootSiblingIndex,
              publishedRootViewIDs == roots.map(\.view.id),
              placementLayers.count
                == roots.lazy.filter({ $0.placement != nil }).count
        else {
            return false
        }
        for (index, publication) in roots.enumerated() {
            let view = publication.view
            guard let state = visualLayers[view.id],
                  state.parentViewID == nil,
                  state.rootPlacementID == publication.placement?.id,
                  state.siblingIndex == (
                    publication.placement == nil
                        ? UInt32(clamping: index)
                        : 0),
                  state.dirtyGenerations == view.dirtyGenerations,
                  state.subtreeDirtyGenerations
                    == view.subtreeDirtyGenerations
            else {
                return false
            }
            if let placement = publication.placement {
                guard let placementState = placementLayers[placement.id],
                      placementState.siblingIndex
                        == UInt32(clamping: index),
                      placementState.frame == SnapshotRect(
                        x: placement.frame.origin.x,
                        y: placement.frame.origin.y,
                        width: placement.frame.size.width,
                        height: placement.frame.size.height
                      ).geometryRect
                else {
                    return false
                }
            }
        }
        return true
    }

    package func visualLayer(for view: View) -> Layer? {
        visualLayers[view.id]?.layer
    }

    package func placementLayer(for window: Window) -> Layer? {
        placementLayers[window.id]?.layer
    }

    package var publishedRootLayer: Layer? {
        rootCreated && rootAttached ? rootLayer : nil
    }

    package var retainedPaintRegistrationCount: Int {
        retainedPaintRegistrationCountStorage
    }

    package var publishedVisualLayerCount: Int {
        visualLayers.count
    }

    package func invalidate() throws(UIError) {
        guard rootCreated, let rootLayer else {
            visualLayers.removeAll()
            placementLayers.removeAll()
            paintCache.removeAll()
            retainedPaintRegistrationCountStorage = 0
            publishedRootViewIDs.removeAll()
            hiddenVisualLayerCount = 0
            lastMetrics = ViewPublicationMetrics()
            return
        }

        var transaction = LayerTransaction(context: context)
        let orderedViewIDs = removalOrder(for: visualLayers.keys)
        for viewID in orderedViewIDs {
            if let state = visualLayers[viewID] {
                transaction.mutations.append(.removed(state.layer.id))
            }
        }
        for placement in placementLayers.values {
            transaction.mutations.append(.removed(placement.layer.id))
        }
        transaction.mutations.append(.removed(rootLayer.id))

        do {
            try transaction.commit()
            applyAcceptedMutations(transaction.mutations)
            visualLayers.removeAll()
            placementLayers.removeAll()
            paintCache.removeAll()
            retainedPaintRegistrationCountStorage = 0
            self.rootLayer = nil
            rootCreated = false
            rootAttached = false
            rootParentID = nil
            rootSiblingIndex = UInt32.max
            publishedRootViewIDs.removeAll()
            hiddenVisualLayerCount = 0
            lastMetrics = ViewPublicationMetrics()
        } catch let error {
            transaction.abort()
            throw UIError(error)
        }
    }

    func publish(
        snapshots: [ViewLayerSnapshot],
        placements: [PlacementSnapshot],
        removedViewIDs: [ViewID],
        traversalUpdates: [ViewID: TraversalUpdate],
        rootParent: Layer?,
        rootSiblingIndex: UInt32,
        metrics: inout ViewPublicationMetrics
    ) throws(UIError) {
        var transaction = LayerTransaction(context: context)
        var cacheDelta = PublicationCacheDelta()
        cacheDelta.traversalUpdates = traversalUpdates
        var newLayerIDs: [LayerID] = []
        var didMutate = false
        let transactionCompletionHandles =
            semanticContext?.takeTransactionCompletions() ?? []
        var transactionCompletionToken: PresentationCompletionToken?

        let root = ensureRootLayer()
        if !rootCreated {
            transaction.mutations.append(.created(root.id, root.descriptor))
            didMutate = true
        }
        if !rootAttached ||
            rootParentID != rootParent?.id ||
            self.rootSiblingIndex != rootSiblingIndex
        {
            transaction.mutations.append(
                .inserted(
                    layer: root.id,
                    parent: rootParent?.id,
                    index: rootSiblingIndex
                ))
            didMutate = true
        }

        // Pass 1: create every missing placement and view layer. The encoded transaction has a
        // complete create set before any hierarchy or property record.
        for placement in placements
        where cacheDelta.placement(placement.id, base: placementLayers) == nil {
            let descriptor = LayerDescriptor(
                kind: .container,
                frame: placement.frame,
                opacity: 1
            )
            let layer = context.makeLayer(descriptor)
            newLayerIDs.append(layer.id)
            transaction.mutations.append(.created(layer.id, descriptor))
            cacheDelta.upsertPlacement(PlacementLayerCache(
                layer: layer,
                frame: placement.frame,
                siblingIndex: UInt32.max
            ), for: placement.id)
            didMutate = true
        }

        for snapshot in snapshots
        where cacheDelta.visual(snapshot.viewID, base: visualLayers) == nil {
            let initialFrame = snapshot.creationFrame?.geometryRect ?? snapshot.frame.geometryRect
            let initialOpacity = snapshot.creationOpacity ?? snapshot.opacity
            let initialBackdrop = snapshot.layerKind == .backdrop
                ? snapshot.backdropMaterial
                : .none
            let descriptor = LayerDescriptor(
                kind: snapshot.layerKind,
                role: snapshot.role.layersRole,
                frame: initialFrame,
                opacity: initialOpacity,
                isHidden: snapshot.isHidden,
                backdropMaterial: initialBackdrop,
                backdropGroupID: snapshot.backdropGroup.rawValue
            )
            let layer = context.makeLayer(descriptor)
            newLayerIDs.append(layer.id)
            transaction.mutations.append(.created(layer.id, descriptor))
            cacheDelta.upsertVisual(VisualLayerCache(
                layer: layer,
                parentViewID: nil,
                rootPlacementID: nil,
                siblingIndex: UInt32.max,
                frame: initialFrame,
                opacity: initialOpacity,
                isHidden: snapshot.isHidden,
                boundsOrigin: .zero,
                clipsToBounds: false,
                transform: .identity,
                cornerRadius: 0,
                shadow: nil,
                backdropGroup: .none,
                backdropMaterial: snapshot.layerKind == .backdrop ? initialBackdrop : nil,
                paintWidth: nil,
                paintHeight: nil,
                paintRecording: PaintRecording(),
                paintCacheKey: nil,
                animationGeneration: 0,
                dirtyGenerations: ViewDirtyGenerations(),
                subtreeDirtyGenerations: ViewDirtyGenerations(),
                childViewIDs: []
            ), for: snapshot.viewID)
            if snapshot.isHidden {
                cacheDelta.hiddenLayerCountDelta += 1
            }
            didMutate = true
            metrics.layersCreated &+= 1
        }

        // Pass 2: establish or change hierarchy after every referenced layer
        // has a create record.
        for placement in placements {
            guard var state = cacheDelta.placement(
                placement.id,
                base: placementLayers
            ) else { continue }
            if state.siblingIndex != placement.siblingIndex {
                transaction.mutations.append(.inserted(
                    layer: state.layer.id,
                    parent: root.id,
                    index: placement.siblingIndex
                ))
                state.siblingIndex = placement.siblingIndex
                cacheDelta.upsertPlacement(state, for: placement.id)
                didMutate = true
            }
        }

        var siblingReorders: [(
            parentLayer: Layer,
            desired: [ViewID],
            moves: [(viewID: ViewID, index: UInt32)]
        )] = []
        for snapshot in snapshots {
            guard let acceptedParent = visualLayers[snapshot.viewID] else {
                continue
            }
            let desired = snapshot.view.childViews.map(\.id)
            guard desired != acceptedParent.childViewIDs,
                  let moves = retainedSiblingReorderMoves(
                    from: acceptedParent.childViewIDs,
                    to: desired),
                  desired.allSatisfy({ childID in
                      guard let child = visualLayers[childID] else {
                          return false
                      }
                      return child.parentViewID == snapshot.viewID
                          && child.rootPlacementID == nil
                  })
            else {
                continue
            }
            siblingReorders.append((
                parentLayer: acceptedParent.layer,
                desired: desired,
                moves: moves))
        }
        for reorder in siblingReorders {
            for (index, viewID) in reorder.desired.enumerated() {
                guard var state = cacheDelta.visual(
                    viewID,
                    base: visualLayers
                ) else { continue }
                state.siblingIndex = UInt32(clamping: index)
                cacheDelta.upsertVisual(state, for: viewID)
            }
            for move in reorder.moves {
                guard let state = cacheDelta.visual(
                    move.viewID,
                    base: visualLayers
                ) else { continue }
                transaction.mutations.append(.inserted(
                    layer: state.layer.id,
                    parent: reorder.parentLayer.id,
                    index: move.index
                ))
                didMutate = true
                metrics.layersReparented &+= 1
            }
        }

        for snapshot in snapshots {
            guard var state = cacheDelta.visual(
                snapshot.viewID,
                base: visualLayers
            ) else { continue }
            if state.parentViewID != snapshot.parentViewID ||
                state.rootPlacementID != snapshot.rootPlacementID ||
                state.siblingIndex != snapshot.siblingIndex
            {
                let parent = snapshot.parentViewID.flatMap {
                    cacheDelta.visual($0, base: visualLayers)?.layer
                } ?? snapshot.rootPlacementID.flatMap {
                    cacheDelta.placement($0, base: placementLayers)?.layer
                } ?? root
                transaction.mutations.append(.inserted(
                    layer: state.layer.id,
                    parent: parent.id,
                    index: snapshot.siblingIndex
                ))
                state.parentViewID = snapshot.parentViewID
                state.rootPlacementID = snapshot.rootPlacementID
                state.siblingIndex = snapshot.siblingIndex
                cacheDelta.upsertVisual(state, for: snapshot.viewID)
                didMutate = true
                metrics.layersReparented &+= 1
            }
        }

        do {
            // Pass 3: sparse property/content changes and semantic animation
            // requests target a now-created, now-inserted visual layer.
            for placement in placements {
                guard var state = cacheDelta.placement(
                    placement.id,
                    base: placementLayers
                ) else { continue }
                if state.frame != placement.frame {
                    transaction.mutations.append(.properties(
                        layer: state.layer.id,
                        LayerPropertyUpdate.decomposedFrame(placement.frame)
                    ))
                    state.frame = placement.frame
                    cacheDelta.upsertPlacement(state, for: placement.id)
                    didMutate = true
                }
            }

            for snapshot in snapshots {
                guard var state = cacheDelta.visual(
                    snapshot.viewID,
                    base: visualLayers
                ) else { continue }
                let wasHidden = state.isHidden
                for update in propertyUpdates(for: snapshot, state: &state) {
                    transaction.mutations.append(.properties(
                        layer: state.layer.id,
                        update
                    ))
                    didMutate = true
                    metrics.propertyUpdates &+= 1
                }
                try publishPaint(
                    snapshot: snapshot,
                    state: &state,
                    transaction: &transaction,
                    cacheDelta: &cacheDelta,
                    didMutate: &didMutate,
                    metrics: &metrics
                )
                if state.isHidden != wasHidden {
                    cacheDelta.hiddenLayerCountDelta +=
                        state.isHidden ? 1 : -1
                }
                publishAnimations(
                    snapshot: snapshot,
                    state: &state,
                    transaction: &transaction,
                    didMutate: &didMutate,
                    metrics: &metrics
                )
                cacheDelta.upsertVisual(state, for: snapshot.viewID)
            }

            // Pass 4: remove absent descendants deepest-first. This avoids a
            // parent removal implicitly erasing a child before its one explicit
            // removal record is applied.
            for viewID in removedViewIDs {
                guard let state = cacheDelta.removeVisual(
                    viewID,
                    base: visualLayers
                ) else { continue }
                if state.isHidden {
                    cacheDelta.hiddenLayerCountDelta -= 1
                }
                stagePaintReferenceRemoval(
                    for: state,
                    cacheDelta: &cacheDelta)
                transaction.mutations.append(.removed(state.layer.id))
                didMutate = true
                metrics.layersRemoved &+= 1
            }

            let seenPlacements = Set(placements.map(\.id))
            for placementID in placementLayers.keys
            where !seenPlacements.contains(placementID) {
                guard let state = cacheDelta.removePlacement(
                    placementID,
                    base: placementLayers
                ) else { continue }
                transaction.mutations.append(.removed(state.layer.id))
                didMutate = true
            }

            metrics.cacheUpserts = UInt64(
                Set(cacheDelta.visualUpserts.keys)
                    .union(cacheDelta.traversalUpdates.keys)
                    .count
                    + cacheDelta.placementUpserts.count)
            metrics.cacheRemovals = UInt64(
                cacheDelta.visualRemovals.count
                    + cacheDelta.placementRemovals.count)
            metrics.paintCacheKeysReconciled = UInt64(
                Set(cacheDelta.paintInsertions.keys)
                    .union(
                        cacheDelta.paintReferenceChanges.map(\.key))
                    .count)

            guard didMutate else {
                transaction.abort()
                apply(cacheDelta: cacheDelta)
                for handle in transactionCompletionHandles {
                    handle.resolve(.completed)
                }
                return
            }

            transactionCompletionToken = bindTransactionCompletions(
                transactionCompletionHandles,
                to: &transaction)
            try bindAnimationPresentationTiming(to: &transaction)

            try transaction.commit()
            metrics.commits &+= 1
            applyAcceptedMutations(transaction.mutations)
            resolveAcceptedInMemoryCompletions(
                transaction: transaction,
                transactionToken: transactionCompletionToken)
            apply(cacheDelta: cacheDelta)
            rootCreated = true
            rootAttached = true
            rootParentID = rootParent?.id
            self.rootSiblingIndex = rootSiblingIndex
        } catch let error {
            transaction.abort()
            resolveRejectedCompletions(
                transaction: transaction,
                transactionToken: transactionCompletionToken,
                handles: transactionCompletionHandles)
            for id in newLayerIDs {
                context.layers.removeValue(forKey: id)
            }
            discardUnacceptedRootIfNeeded()
            throw UIError(error)
        }
    }

}
