@_spi(NucleusCompositor) import NucleusLayers
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

package struct ViewPublicationMetrics: Sendable, Equatable {
    package var nodesVisited: UInt64 = 0
    package var cleanSubtreesSkipped: UInt64 = 0
    package var snapshotsAuthored: UInt64 = 0
    package var dirtyStructure: UInt64 = 0
    package var dirtyGeometry: UInt64 = 0
    package var dirtyVisibility: UInt64 = 0
    package var dirtyStyle: UInt64 = 0
    package var dirtyContent: UInt64 = 0
    package var dirtyTransform: UInt64 = 0
    package var dirtyScrolling: UInt64 = 0
    package var dirtyAccessibility: UInt64 = 0
    package var dirtyAnimation: UInt64 = 0
    package var layersCreated: UInt64 = 0
    package var layersRetained: UInt64 = 0
    package var layersHidden: UInt64 = 0
    package var layersReparented: UInt64 = 0
    package var layersRemoved: UInt64 = 0
    package var propertyUpdates: UInt64 = 0
    package var contentRegistrations: UInt64 = 0
    package var contentCacheHits: UInt64 = 0
    package var paintBytes: UInt64 = 0
    package var localizedPaintUpdates: UInt64 = 0
    package var fullPaintUpdates: UInt64 = 0
    package var damageRegions: UInt64 = 0
    package var animationRequests: UInt64 = 0
    package var commits: UInt64 = 0

    package init() {}
}

@MainActor
package final class ViewLayerPublisher: ~Sendable {
    private struct SnapshotRect: Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = Self.canonical(x)
            self.y = Self.canonical(y)
            self.width = max(0, Self.canonical(width))
            self.height = max(0, Self.canonical(height))
        }

        var geometryRect: GeometryRect {
            GeometryRect(x: x, y: y, width: width, height: height)
        }

        private static func canonical(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return value == 0 ? 0 : value
        }
    }

    private struct ViewLayerSnapshot {
        var view: View
        var viewID: ViewID
        var parentViewID: ViewID?
        var rootPlacementID: WindowID?
        var siblingIndex: UInt32
        var frame: SnapshotRect
        var opacity: Double
        var isHidden: Bool
        var boundsOrigin: Point
        var clipsToBounds: Bool
        var transform: Transform
        var cornerRadius: Double
        var shadow: Shadow?
        var layerKind: LayerKind
        var backdropMaterial: BackdropMaterial
        var recording: PaintRecording
        var paintDamage: SnapshotRect?
        var role: LayerRole
        var backdropGroup: BackdropGroup
        var actionPolicies: [ViewDirtyDomain: ActionPolicy]
        var dirtyGenerations: ViewDirtyGenerations
        var subtreeDirtyGenerations: ViewDirtyGenerations
        var creationFrame: SnapshotRect?
        var creationOpacity: Double?
        var animationRequests: [ViewAnimationRequest]
    }

    private struct VisualLayerCache: ~Sendable {
        var layer: Layer
        var parentViewID: ViewID?
        var rootPlacementID: WindowID?
        var siblingIndex: UInt32
        var frame: GeometryRect
        var opacity: Double
        var isHidden: Bool
        var boundsOrigin: Point
        var clipsToBounds: Bool
        var transform: Transform
        var cornerRadius: Double
        var shadow: Shadow?
        var backdropGroup: BackdropGroup
        var backdropMaterial: BackdropMaterial?
        var paintWidth: Float?
        var paintHeight: Float?
        var paintRecording: PaintRecording
        var animationGeneration: UInt64
        var dirtyGenerations: ViewDirtyGenerations
        var subtreeDirtyGenerations: ViewDirtyGenerations
        var childViewIDs: [ViewID]
    }

    private struct PlacementSnapshot: Sendable, Equatable {
        var id: WindowID
        var frame: GeometryRect
        var siblingIndex: UInt32
    }

    private struct PlacementLayerCache: ~Sendable {
        var layer: Layer
        var frame: GeometryRect
        var siblingIndex: UInt32
    }

    private struct PaintCacheKey: Hashable {
        var widthBits: UInt32
        var heightBits: UInt32
        var digest: Int
    }

    private struct PaintCacheEntry {
        var recording: PaintRecording
        var registered: RegisteredPaint
    }

    private struct TraversalWorkItem {
        var view: View
        var parentViewID: ViewID?
        var rootPlacementID: WindowID?
        var siblingIndex: UInt32
        var forceSnapshot: Bool
    }

    package let context: Context

    private var rootLayer: Layer?
    private var rootCreated = false
    private var rootAttached = false
    private var rootParentID: LayerID?
    private var rootSiblingIndex: UInt32 = UInt32.max
    private weak var semanticContext: UIContext?
    private var visualLayers: [ViewID: VisualLayerCache] = [:]
    private var placementLayers: [WindowID: PlacementLayerCache] = [:]
    private var paintCache: [PaintCacheKey: [PaintCacheEntry]] = [:]
    private var publishedRootViewIDs: [ViewID] = []
    private var hiddenVisualLayerCount = 0
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

    package func ensureRootAttached() throws(UIError) -> Layer {
        let root = ensureRootLayer()
        guard !rootCreated || !rootAttached else { return root }

        var transaction = LayerTransaction(context: context)
        if !rootCreated {
            transaction.mutations.append(.created(root.id, root.descriptor))
        }
        if !rootAttached {
            transaction.mutations.append(
                .inserted(layer: root.id, parent: nil, index: UInt32.max))
        }

        do {
            try transaction.commit()
            applyAcceptedMutations(transaction.mutations)
            rootCreated = true
            rootAttached = true
            return root
        } catch let error {
            transaction.abort()
            discardUnacceptedRootIfNeeded()
            throw UIError(error)
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
        var traversalUpdates: [
            ViewID: (
                view: View,
                dirty: ViewDirtyGenerations,
                subtree: ViewDirtyGenerations,
                children: [ViewID]?
            )
        ] = [:]
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

    private func publishedContents(
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

    private func canSkipPublication(
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
        paintCache.values.reduce(into: 0) {
            $0 += $1.count
        }
    }

    package var publishedVisualLayerCount: Int {
        visualLayers.count
    }

    package func invalidate() throws(UIError) {
        guard rootCreated, let rootLayer else {
            visualLayers.removeAll()
            placementLayers.removeAll()
            paintCache.removeAll()
            publishedRootViewIDs.removeAll()
            hiddenVisualLayerCount = 0
            lastMetrics = ViewPublicationMetrics()
            return
        }

        var transaction = LayerTransaction(context: context)
        let orderedViewIDs = visualLayers.keys.sorted {
            removalDepth(of: $0) > removalDepth(of: $1)
        }
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

    private func appendDirtyViewTrees(
        work: inout [TraversalWorkItem],
        snapshots: inout [ViewLayerSnapshot],
        traversalUpdates: inout [
            ViewID: (
                view: View,
                dirty: ViewDirtyGenerations,
                subtree: ViewDirtyGenerations,
                children: [ViewID]?
            )
        ],
        removalCandidates: inout Set<ViewID>,
        structurallyPresent: inout Set<ViewID>,
        metrics: inout ViewPublicationMetrics
    ) {
        // This is one flat parent-before-child traversal. `work` is the only
        // traversal allocation; no recursive call stack or per-parent child
        // snapshot array grows with tree depth.
        var dirtyChildren: [(index: Int, view: View)] = []
        while let item = work.popLast() {
            let view = item.view
            metrics.nodesVisited &+= 1
            let state = visualLayers[view.id]
            let hierarchyChanged =
                state?.parentViewID != item.parentViewID
                    || state?.rootPlacementID != item.rootPlacementID
                    || state?.siblingIndex != item.siblingIndex
            let ownChanged =
                state == nil || state?.dirtyGenerations != view.dirtyGenerations
            let subtreeChanged =
                state == nil
                    || state?.subtreeDirtyGenerations
                        != view.subtreeDirtyGenerations

            guard item.forceSnapshot || hierarchyChanged || ownChanged ||
                    subtreeChanged
            else {
                metrics.cleanSubtreesSkipped &+= 1
                continue
            }

            let structureChanged =
                state == nil
                    || state?.dirtyGenerations.structure
                        != view.dirtyGenerations.structure
            let childIDs: [ViewID]?
            if structureChanged {
                let ids = view.childViews.map(\.id)
                childIDs = ids
                let oldChildren = state?.childViewIDs ?? []
                removalCandidates.formUnion(
                    oldChildren.filter { view.childViewsByID[$0] == nil })
                structurallyPresent.formUnion(ids)
            } else {
                childIDs = nil
            }

            traversalUpdates[view.id] = (
                view,
                view.dirtyGenerations,
                view.subtreeDirtyGenerations,
                childIDs)

            recordDirtyDomains(
                previous: state?.dirtyGenerations,
                current: view.dirtyGenerations,
                metrics: &metrics)

            if item.forceSnapshot || hierarchyChanged || ownChanged ||
                    state == nil
            {
                snapshots.append(makeSnapshot(
                    view,
                    parentViewID: item.parentViewID,
                    rootPlacementID: item.rootPlacementID,
                    siblingIndex: item.siblingIndex))
                metrics.snapshotsAuthored &+= 1
            }

            if structureChanged {
                // Reverse insertion makes the next pop preserve semantic child
                // order while retaining a single flat work buffer.
                for index in view.childViews.indices.reversed() {
                    work.append(TraversalWorkItem(
                        view: view.childViews[index],
                        parentViewID: view.id,
                        rootPlacementID: nil,
                        siblingIndex: UInt32(clamping: index),
                        forceSnapshot: true))
                }
                continue
            }

            dirtyChildren.removeAll(keepingCapacity: true)
            for childID in view.dirtyChildViewIDs {
                guard let child = view.childViewsByID[childID],
                      let index = view.childViewIndices[childID]
                else {
                    continue
                }
                dirtyChildren.append((index, child))
            }
            dirtyChildren.sort { $0.index > $1.index }
            for child in dirtyChildren {
                work.append(TraversalWorkItem(
                    view: child.view,
                    parentViewID: view.id,
                    rootPlacementID: nil,
                    siblingIndex: UInt32(clamping: child.index),
                    forceSnapshot: false))
            }
        }
    }

    private func makeSnapshot(
        _ view: View,
        parentViewID: ViewID?,
        rootPlacementID: WindowID?,
        siblingIndex: UInt32
    ) -> ViewLayerSnapshot {
        let content = view.layerContent
        let presentation = content.presentation
        let frame = view.frame
        let backdropMaterial = view.properties.backdropMaterial ?? view.semanticBackdropMaterial
        let creationFrame = presentation.creationFrame.map {
            SnapshotRect(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.size.width,
                height: $0.size.height
            )
        }
        let requests = view.animationRequests.values.sorted {
            if $0.generation != $1.generation {
                return $0.generation < $1.generation
            }
            return animationKeyPath(of: $0).rawValue < animationKeyPath(of: $1).rawValue
        }

        return ViewLayerSnapshot(
            view: view,
            viewID: view.id,
            parentViewID: parentViewID,
            rootPlacementID: rootPlacementID,
            siblingIndex: siblingIndex,
            frame: SnapshotRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            ),
            opacity: view.alphaValue,
            isHidden: view.isHidden,
            boundsOrigin: view.boundsOrigin,
            clipsToBounds: view.clipsToBounds,
            transform: view.transform,
            cornerRadius: view.cornerRadius,
            shadow: content.shadow,
            layerKind: view.semanticLayerKind,
            backdropMaterial: backdropMaterial,
            recording: content.recording,
            paintDamage: content.recording.supportsLocalizedDamage
                ? content.damage.map {
                    SnapshotRect(
                        x: $0.origin.x,
                        y: $0.origin.y,
                        width: $0.size.width,
                        height: $0.size.height)
                }
                : nil,
            role: presentation.role,
            backdropGroup: presentation.backdropGroup,
            actionPolicies: presentation.actionPolicy == .none
                ? view.storedMutationActionPolicies
                : Dictionary(
                    uniqueKeysWithValues: ViewDirtyDomain.allCases.map {
                        ($0, presentation.actionPolicy)
                    }
            ),
            dirtyGenerations: view.dirtyGenerations,
            subtreeDirtyGenerations: view.subtreeDirtyGenerations,
            creationFrame: creationFrame,
            creationOpacity: presentation.creationOpacity,
            animationRequests: requests
        )
    }

    private func publish(
        snapshots: [ViewLayerSnapshot],
        placements: [PlacementSnapshot],
        removedViewIDs: [ViewID],
        traversalUpdates: [
            ViewID: (
                view: View,
                dirty: ViewDirtyGenerations,
                subtree: ViewDirtyGenerations,
                children: [ViewID]?
            )
        ],
        rootParent: Layer?,
        rootSiblingIndex: UInt32,
        metrics: inout ViewPublicationMetrics
    ) throws(UIError) {
        var transaction = LayerTransaction(context: context)
        var nextVisualLayers = visualLayers
        var nextPlacementLayers = placementLayers
        var nextHiddenVisualLayerCount = hiddenVisualLayerCount
        var newLayerIDs: [LayerID] = []
        var retainedRegistrations: [RegisteredPaint] = []
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
        for placement in placements where nextPlacementLayers[placement.id] == nil {
            let descriptor = LayerDescriptor(
                kind: .container,
                frame: placement.frame,
                opacity: 1
            )
            let layer = context.makeLayer(descriptor)
            newLayerIDs.append(layer.id)
            transaction.mutations.append(.created(layer.id, descriptor))
            nextPlacementLayers[placement.id] = PlacementLayerCache(
                layer: layer,
                frame: placement.frame,
                siblingIndex: UInt32.max
            )
            didMutate = true
        }

        for snapshot in snapshots where nextVisualLayers[snapshot.viewID] == nil {
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
            nextVisualLayers[snapshot.viewID] = VisualLayerCache(
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
                animationGeneration: 0,
                dirtyGenerations: ViewDirtyGenerations(),
                subtreeDirtyGenerations: ViewDirtyGenerations(),
                childViewIDs: []
            )
            if snapshot.isHidden {
                nextHiddenVisualLayerCount += 1
            }
            didMutate = true
            metrics.layersCreated &+= 1
        }

        // Pass 2: establish or change hierarchy after every referenced layer
        // has a create record.
        for placement in placements {
            guard var state = nextPlacementLayers[placement.id] else { continue }
            if state.siblingIndex != placement.siblingIndex {
                transaction.mutations.append(.inserted(
                    layer: state.layer.id,
                    parent: root.id,
                    index: placement.siblingIndex
                ))
                state.siblingIndex = placement.siblingIndex
                nextPlacementLayers[placement.id] = state
                didMutate = true
            }
        }

        for snapshot in snapshots {
            guard var state = nextVisualLayers[snapshot.viewID] else { continue }
            if state.parentViewID != snapshot.parentViewID ||
                state.rootPlacementID != snapshot.rootPlacementID ||
                state.siblingIndex != snapshot.siblingIndex
            {
                let parent = snapshot.parentViewID.flatMap {
                    nextVisualLayers[$0]?.layer
                } ?? snapshot.rootPlacementID.flatMap {
                    nextPlacementLayers[$0]?.layer
                } ?? root
                transaction.mutations.append(.inserted(
                    layer: state.layer.id,
                    parent: parent.id,
                    index: snapshot.siblingIndex
                ))
                state.parentViewID = snapshot.parentViewID
                state.rootPlacementID = snapshot.rootPlacementID
                state.siblingIndex = snapshot.siblingIndex
                nextVisualLayers[snapshot.viewID] = state
                didMutate = true
                metrics.layersReparented &+= 1
            }
        }

        do {
            // Pass 3: sparse property/content changes and semantic animation
            // requests target a now-created, now-inserted visual layer.
            for placement in placements {
                guard var state = nextPlacementLayers[placement.id] else { continue }
                if state.frame != placement.frame {
                    transaction.mutations.append(.properties(
                        layer: state.layer.id,
                        LayerPropertyUpdate.decomposedFrame(placement.frame)
                    ))
                    state.frame = placement.frame
                    nextPlacementLayers[placement.id] = state
                    didMutate = true
                }
            }

            for snapshot in snapshots {
                guard var state = nextVisualLayers[snapshot.viewID] else { continue }
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
                    retainedRegistrations: &retainedRegistrations,
                    didMutate: &didMutate,
                    metrics: &metrics
                )
                if state.isHidden != wasHidden {
                    nextHiddenVisualLayerCount += state.isHidden ? 1 : -1
                }
                publishAnimations(
                    snapshot: snapshot,
                    state: &state,
                    transaction: &transaction,
                    didMutate: &didMutate,
                    metrics: &metrics
                )
                nextVisualLayers[snapshot.viewID] = state
            }

            // Pass 4: remove absent descendants deepest-first. This avoids a
            // parent removal implicitly erasing a child before its one explicit
            // removal record is applied.
            for viewID in removedViewIDs {
                guard let state = nextVisualLayers.removeValue(forKey: viewID) else { continue }
                if state.isHidden {
                    nextHiddenVisualLayerCount -= 1
                }
                transaction.mutations.append(.removed(state.layer.id))
                didMutate = true
                metrics.layersRemoved &+= 1
            }

            let seenPlacements = Set(placements.map(\.id))
            for placementID in placementLayers.keys
            where !seenPlacements.contains(placementID) {
                guard let state = nextPlacementLayers.removeValue(
                    forKey: placementID)
                else {
                    continue
                }
                transaction.mutations.append(.removed(state.layer.id))
                didMutate = true
            }

            guard didMutate else {
                transaction.abort()
                applyTraversalUpdates(
                    traversalUpdates,
                    to: &nextVisualLayers)
                visualLayers = nextVisualLayers
                hiddenVisualLayerCount = nextHiddenVisualLayerCount
                for handle in transactionCompletionHandles {
                    handle.resolve(.completed)
                }
                return
            }

            if !transactionCompletionHandles.isEmpty {
                let handles = transactionCompletionHandles
                let token = PresentationCompletionCenter.register { result in
                    let outcome = TransactionOutcome(result)
                    for handle in handles {
                        handle.resolve(outcome)
                    }
                }
                transactionCompletionToken = token
                transaction.completionToken = token.rawValue
            }

            if transaction.mutations.contains(where: {
                if case .animationAdded = $0 { return true }
                return false
            }), !(context.commitSink is InMemoryCommitSink)
            {
                let report = try context.queryDisplayLink()
                transaction.predictedPresentationNanoseconds =
                    report.predictedPresentationNanoseconds
                transaction.targetPresentationNanoseconds =
                    report.targetPresentationNanoseconds
            }

            try transaction.commit()
            metrics.commits &+= 1
            applyAcceptedMutations(transaction.mutations)
            if context.commitSink is InMemoryCommitSink {
                if let transactionCompletionToken {
                    PresentationCompletionCenter.resolve(
                        transactionCompletionToken,
                        result: .completed
                    )
                }
                for token in transaction.mutations.compactMap({
                    if case .animationAdded(_, let animation) = $0 {
                        return animation.completionToken
                    }
                    return nil
                }) where token != 0 {
                    PresentationCompletionCenter.resolve(
                        rawToken: token,
                        result: .completed
                    )
                }
            }
            withExtendedLifetime(retainedRegistrations) {}
            applyTraversalUpdates(
                traversalUpdates,
                to: &nextVisualLayers)
            visualLayers = nextVisualLayers
            placementLayers = nextPlacementLayers
            hiddenVisualLayerCount = nextHiddenVisualLayerCount
            prunePaintCache(liveLayers: visualLayers)
            rootCreated = true
            rootAttached = true
            rootParentID = rootParent?.id
            self.rootSiblingIndex = rootSiblingIndex
        } catch let error {
            transaction.abort()
            for token in transaction.mutations.compactMap({
                if case .animationAdded(_, let animation) = $0 {
                    return animation.completionToken
                }
                return nil
            }) where token != 0 {
                PresentationCompletionCenter.resolve(
                    rawToken: token,
                    result: .failed
                )
            }
            if let transactionCompletionToken {
                PresentationCompletionCenter.resolve(
                    transactionCompletionToken,
                    result: .failed
                )
            } else {
                for handle in transactionCompletionHandles {
                    handle.resolve(.failed)
                }
            }
            for id in newLayerIDs {
                context.layers.removeValue(forKey: id)
            }
            discardUnacceptedRootIfNeeded()
            prunePaintCache(liveLayers: visualLayers)
            withExtendedLifetime(retainedRegistrations) {}
            throw UIError(error)
        }
    }

    private struct AuthoredPropertyUpdate {
        var generation: UInt64
        var sequence: Int
        var update: LayerPropertyUpdate
    }

    private func propertyUpdates(
        for snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache
    ) -> [LayerPropertyUpdate] {
        var authored: [AuthoredPropertyUpdate] = []
        var sequence = 0

        func append(
            _ update: LayerPropertyUpdate,
            domain: ViewDirtyDomain
        ) {
            authored.append(AuthoredPropertyUpdate(
                generation: snapshot.dirtyGenerations[domain],
                sequence: sequence,
                update: update
            ))
            sequence += 1
        }

        let frame = snapshot.frame.geometryRect
        let frameChanged = state.frame != frame
        if frameChanged {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .geometry, snapshot: snapshot)
            )
            update.position = GeometryPoint(x: frame.x, y: frame.y)
            update.bounds = GeometrySize(
                width: frame.width,
                height: frame.height
            )
            if snapshot.clipsToBounds {
                update.clip = ClipOp(
                    rectX: 0,
                    rectY: 0,
                    rectW: Float(snapshot.frame.width),
                    rectH: Float(snapshot.frame.height)
                )
            }
            state.frame = frame
            append(update, domain: .geometry)
        }

        let opacityChanged = state.opacity != snapshot.opacity
        let hiddenChanged = state.isHidden != snapshot.isHidden
        if opacityChanged || hiddenChanged {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .visibility, snapshot: snapshot)
            )
            // The render model represents hidden state as an effective opacity.
            // An alpha edit while hidden updates semantic cache only; unhiding
            // restores the latest semantic alpha instead of remaining stuck at
            // the zero written by the hide.
            if hiddenChanged {
                update.opacity = snapshot.isHidden ? 0 : snapshot.opacity
            } else if !snapshot.isHidden {
                update.opacity = snapshot.opacity
            }
            state.opacity = snapshot.opacity
            state.isHidden = snapshot.isHidden
            if update.opacity != nil {
                append(update, domain: .visibility)
            }
        }

        if state.boundsOrigin != snapshot.boundsOrigin {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .scrolling, snapshot: snapshot)
            )
            update.scrollOffset = GeometryPoint(
                x: snapshot.boundsOrigin.x,
                y: snapshot.boundsOrigin.y
            )
            state.boundsOrigin = snapshot.boundsOrigin
            append(update, domain: .scrolling)
        }

        if state.transform != snapshot.transform {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .transform, snapshot: snapshot)
            )
            update.transform = snapshot.transform.layersTransform
            state.transform = snapshot.transform
            append(update, domain: .transform)
        }

        var styleUpdate = LayerPropertyUpdate(
            actionPolicy: policy(for: .style, snapshot: snapshot)
        )
        var styleChanged = false
        if state.clipsToBounds != snapshot.clipsToBounds {
            let size = snapshot.clipsToBounds ? snapshot.frame : SnapshotRect(
                x: 0, y: 0, width: 0, height: 0)
            styleUpdate.clip = ClipOp(
                rectX: 0,
                rectY: 0,
                rectW: Float(size.width),
                rectH: Float(size.height)
            )
            state.clipsToBounds = snapshot.clipsToBounds
            styleChanged = true
        }
        if state.cornerRadius != snapshot.cornerRadius {
            styleUpdate.cornerRadii = CornerRadii(
                uniform: Float(snapshot.cornerRadius)
            )
            state.cornerRadius = snapshot.cornerRadius
            styleChanged = true
        }
        if state.shadow != snapshot.shadow {
            styleUpdate.shadow = (snapshot.shadow ?? .none).layersShadow
            state.shadow = snapshot.shadow
            styleChanged = true
        }
        if state.backdropGroup != snapshot.backdropGroup {
            styleUpdate.backdropGroupID = snapshot.backdropGroup.rawValue
            state.backdropGroup = snapshot.backdropGroup
            styleChanged = true
        }
        if snapshot.layerKind == .backdrop,
           state.backdropMaterial != snapshot.backdropMaterial
        {
            styleUpdate.backdropMaterial = snapshot.backdropMaterial
            state.backdropMaterial = snapshot.backdropMaterial
            styleChanged = true
        }
        if styleChanged {
            append(styleUpdate, domain: .style)
        }

        return authored.sorted {
            if $0.generation != $1.generation {
                return $0.generation < $1.generation
            }
            return $0.sequence < $1.sequence
        }.map(\.update)
    }

    private func policy(
        for domain: ViewDirtyDomain,
        snapshot: ViewLayerSnapshot
    ) -> NucleusLayers.ActionPolicy {
        (snapshot.actionPolicies[domain] ?? .none).layersPolicy
    }

    private func publishPaint(
        snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache,
        transaction: inout LayerTransaction,
        retainedRegistrations: inout [RegisteredPaint],
        didMutate: inout Bool,
        metrics: inout ViewPublicationMetrics
    ) throws(LayerError) {
        let width = Float(snapshot.frame.width)
        let height = Float(snapshot.frame.height)
        let recording = snapshot.recording

        if recording.isEmpty {
            if !state.paintRecording.isEmpty {
                transaction.mutations.append(.properties(
                    layer: state.layer.id,
                    LayerPropertyUpdate(content: LayerContent.none)
                ))
                state.paintWidth = nil
                state.paintHeight = nil
                state.paintRecording = PaintRecording()
                didMutate = true
            }
            return
        }

        guard state.paintWidth != width ||
                state.paintHeight != height ||
                state.paintRecording != recording
        else {
            return
        }

        let cacheKey = paintCacheKey(
            recording: recording,
            width: width,
            height: height)
        let registered: RegisteredPaint
        if let cached = paintCache[cacheKey]?.first(where: {
            $0.recording == recording
        }) {
            registered = cached.registered
            metrics.contentCacheHits &+= 1
        } else {
            registered = try PaintRegistration.register(
                recording,
                width: width,
                height: height,
                in: context
            )
            paintCache[cacheKey, default: []].append(PaintCacheEntry(
                recording: recording,
                registered: registered))
            metrics.contentRegistrations &+= 1
        }
        retainedRegistrations.append(registered)
        var update = registered.update
        let canLocalize =
            state.paintWidth == width
                && state.paintHeight == height
                && !state.paintRecording.isEmpty
        if canLocalize, let damage = snapshot.paintDamage {
            update.contentDamage = damage.geometryRect
            metrics.localizedPaintUpdates &+= 1
            metrics.damageRegions &+= 1
        } else {
            update.contentDamage = nil
            metrics.fullPaintUpdates &+= 1
        }
        transaction.mutations.append(.properties(
            layer: state.layer.id,
            update
        ))
        state.paintWidth = width
        state.paintHeight = height
        state.paintRecording = recording
        didMutate = true
        metrics.paintBytes &+= UInt64(recording.payload.count)
            &+ UInt64(recording.commands.count)
                &* UInt64(MemoryLayout<PaintCommand>.stride)
    }

    private func publishAnimations(
        snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache,
        transaction: inout LayerTransaction,
        didMutate: inout Bool,
        metrics: inout ViewPublicationMetrics
    ) {
        for request in snapshot.animationRequests
        where request.generation > state.animationGeneration {
            switch request.operation {
            case .add(let animation):
                transaction.mutations.append(.animationAdded(
                    layer: state.layer.id,
                    animation
                ))
            case .remove(let keyPath):
                transaction.mutations.append(.animationRemoved(
                    layer: state.layer.id,
                    keyPath
                ))
            }
            state.animationGeneration = max(state.animationGeneration, request.generation)
            didMutate = true
            metrics.animationRequests &+= 1
        }
    }

    private func recordDirtyDomains(
        previous: ViewDirtyGenerations?,
        current: ViewDirtyGenerations,
        metrics: inout ViewPublicationMetrics
    ) {
        for domain in ViewDirtyDomain.allCases {
            let changed = previous.map {
                $0[domain] != current[domain]
            } ?? (current[domain] != 0)
            guard changed else { continue }
            switch domain {
            case .structure:
                metrics.dirtyStructure &+= 1
            case .geometry:
                metrics.dirtyGeometry &+= 1
            case .visibility:
                metrics.dirtyVisibility &+= 1
            case .style:
                metrics.dirtyStyle &+= 1
            case .content:
                metrics.dirtyContent &+= 1
            case .transform:
                metrics.dirtyTransform &+= 1
            case .scrolling:
                metrics.dirtyScrolling &+= 1
            case .accessibility:
                metrics.dirtyAccessibility &+= 1
            case .animation:
                metrics.dirtyAnimation &+= 1
            }
        }
    }

    private func ensureRootLayer() -> Layer {
        if let rootLayer { return rootLayer }
        let root = context.makeLayer(.init(frame: .zero, opacity: 1))
        rootLayer = root
        return root
    }

    private func discardUnacceptedRootIfNeeded() {
        guard !rootCreated, let rootLayer else { return }
        context.layers.removeValue(forKey: rootLayer.id)
        self.rootLayer = nil
    }

    private func removalDepth(of viewID: ViewID) -> Int {
        var depth = 0
        var parent = visualLayers[viewID]?.parentViewID
        while let current = parent {
            depth += 1
            parent = visualLayers[current]?.parentViewID
        }
        return depth
    }

    private func removedCachedSubtrees(
        rootedAt roots: Set<ViewID>
    ) -> [ViewID] {
        var removed = Set<ViewID>()
        var pending = Array(roots)
        while let viewID = pending.popLast(),
              removed.insert(viewID).inserted
        {
            pending.append(
                contentsOf: visualLayers[viewID]?.childViewIDs ?? [])
        }
        return removed.sorted {
            removalDepth(of: $0) > removalDepth(of: $1)
        }
    }

    private func applyTraversalUpdates(
        _ updates: [
            ViewID: (
                view: View,
                dirty: ViewDirtyGenerations,
                subtree: ViewDirtyGenerations,
                children: [ViewID]?
            )
        ],
        to layers: inout [ViewID: VisualLayerCache]
    ) {
        for (viewID, update) in updates {
            guard var state = layers[viewID] else { continue }
            state.dirtyGenerations = update.dirty
            state.subtreeDirtyGenerations = update.subtree
            if let children = update.children {
                state.childViewIDs = children
            }
            layers[viewID] = state
            update.view.dirtyChildViewIDs.removeAll(
                keepingCapacity: true)
        }
    }

    private func publishMetrics(_ metrics: ViewPublicationMetrics) {
        Trace.plot(
            "swift.nucleus.view_layer.nodes_visited",
            metrics.nodesVisited)
        Trace.plot(
            "swift.nucleus.view_layer.clean_subtrees_skipped",
            metrics.cleanSubtreesSkipped)
        Trace.plot(
            "swift.nucleus.view_layer.snapshots_authored",
            metrics.snapshotsAuthored)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_structure",
            metrics.dirtyStructure)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_geometry",
            metrics.dirtyGeometry)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_visibility",
            metrics.dirtyVisibility)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_style",
            metrics.dirtyStyle)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_content",
            metrics.dirtyContent)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_transform",
            metrics.dirtyTransform)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_scrolling",
            metrics.dirtyScrolling)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_accessibility",
            metrics.dirtyAccessibility)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_animation",
            metrics.dirtyAnimation)
        Trace.plot(
            "swift.nucleus.view_layer.layers_created",
            metrics.layersCreated)
        Trace.plot(
            "swift.nucleus.view_layer.layers_retained",
            metrics.layersRetained)
        Trace.plot(
            "swift.nucleus.view_layer.layers_hidden",
            metrics.layersHidden)
        Trace.plot(
            "swift.nucleus.view_layer.layers_reparented",
            metrics.layersReparented)
        Trace.plot(
            "swift.nucleus.view_layer.layers_removed",
            metrics.layersRemoved)
        Trace.plot(
            "swift.nucleus.view_layer.property_updates",
            metrics.propertyUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.content_registrations",
            metrics.contentRegistrations)
        Trace.plot(
            "swift.nucleus.view_layer.content_cache_hits",
            metrics.contentCacheHits)
        Trace.plot(
            "swift.nucleus.view_layer.paint_bytes",
            metrics.paintBytes)
        Trace.plot(
            "swift.nucleus.view_layer.localized_paint_updates",
            metrics.localizedPaintUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.full_paint_updates",
            metrics.fullPaintUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.damage_regions",
            metrics.damageRegions)
        Trace.plot(
            "swift.nucleus.view_layer.animation_requests",
            metrics.animationRequests)
        Trace.plot(
            "swift.nucleus.view_layer.retained_paint_registrations",
            UInt64(retainedPaintRegistrationCount))
        Trace.plot(
            "swift.nucleus.view_layer.commits",
            metrics.commits)
    }

    private func paintCacheKey(
        recording: PaintRecording,
        width: Float,
        height: Float
    ) -> PaintCacheKey {
        var hasher = Hasher()
        hasher.combine(recording.commands.count)
        hasher.combine(recording.payload.count)
        for command in recording.commands {
            hasher.combine(command.kind.rawValue)
            hasher.combine(command.flags.rawValue)
            hasher.combine(command.shading.rawValue)
            hasher.combine(command.blend.rawValue)
            hasher.combine(command.x.bitPattern)
            hasher.combine(command.y.bitPattern)
            hasher.combine(command.w.bitPattern)
            hasher.combine(command.h.bitPattern)
            hasher.combine(command.radius.bitPattern)
            hasher.combine(command.strokeWidth.bitPattern)
            hasher.combine(command.fontSize.bitPattern)
            hasher.combine(command.alpha.bitPattern)
            hasher.combine(command.blurSigma.bitPattern)
            hasher.combine(command.saturation.bitPattern)
            hasher.combine(command.color.r.bitPattern)
            hasher.combine(command.color.g.bitPattern)
            hasher.combine(command.color.b.bitPattern)
            hasher.combine(command.color.a.bitPattern)
            hasher.combine(command.imageHandle)
            hasher.combine(command.textLayoutHandle)
            hasher.combine(command.effectHandle)
            hasher.combine(command.payloadOffset)
            hasher.combine(command.payloadLength)
            hasher.combine(command.transformA.bitPattern)
            hasher.combine(command.transformB.bitPattern)
            hasher.combine(command.transformC.bitPattern)
            hasher.combine(command.transformD.bitPattern)
            hasher.combine(command.transformTX.bitPattern)
            hasher.combine(command.transformTY.bitPattern)
        }
        for byte in recording.payload {
            hasher.combine(byte)
        }
        for layout in recording.textLayouts {
            hasher.combine(layout.text)
            hasher.combine(layout.lines.count)
        }
        return PaintCacheKey(
            widthBits: width.bitPattern,
            heightBits: height.bitPattern,
            digest: hasher.finalize())
    }

    private func prunePaintCache(
        liveLayers: [ViewID: VisualLayerCache]
    ) {
        var liveRecordings: [PaintCacheKey: [PaintRecording]] = [:]
        for state in liveLayers.values {
            guard !state.paintRecording.isEmpty,
                  let width = state.paintWidth,
                  let height = state.paintHeight
            else {
                continue
            }
            let key = paintCacheKey(
                recording: state.paintRecording,
                width: width,
                height: height)
            if liveRecordings[key]?.contains(state.paintRecording) != true {
                liveRecordings[key, default: []].append(
                    state.paintRecording)
            }
        }
        for key in Array(paintCache.keys) {
            guard let recordings = liveRecordings[key] else {
                paintCache[key] = nil
                continue
            }
            paintCache[key]?.removeAll {
                !recordings.contains($0.recording)
            }
            if paintCache[key]?.isEmpty == true {
                paintCache[key] = nil
            }
        }
    }

    /// Mirror the accepted journal into the producer-side retained model only
    /// after the commit sink has accepted it.
    private func applyAcceptedMutations(_ mutations: [LayerMutation]) {
        for mutation in mutations {
            switch mutation {
            case .created:
                break
            case .inserted(let layerID, let parentID, let index):
                guard let layer = context.layers[layerID] else { continue }
                let parent = parentID.flatMap { context.layers[$0] }
                layer.attach(to: parent, at: index)
            case .properties(let layerID, let update):
                context.layers[layerID]?.apply(update)
            case .detached(let layerID):
                context.layers[layerID]?.detach()
            case .removed(let layerID):
                context.layers[layerID]?.detach()
                context.layers.removeValue(forKey: layerID)
            case .animationAdded, .animationRemoved:
                break
            }
        }
    }

    private func animationKeyPath(of request: ViewAnimationRequest) -> AnimationKeyPath {
        switch request.operation {
        case .add(let animation): animation.keyPath
        case .remove(let keyPath): keyPath
        }
    }
}
