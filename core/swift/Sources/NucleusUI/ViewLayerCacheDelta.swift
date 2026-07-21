@_spi(NucleusCompositor) import NucleusLayers

extension ViewLayerPublisher {
    struct VisualLayerCache: ~Sendable {
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
        var paintCacheKey: PaintCacheKey?
        var animationGeneration: UInt64
        var dirtyGenerations: ViewDirtyGenerations
        var subtreeDirtyGenerations: ViewDirtyGenerations
        var childViewIDs: [ViewID]
    }

    struct PlacementLayerCache: ~Sendable {
        var layer: Layer
        var frame: GeometryRect
        var siblingIndex: UInt32
    }

    struct PublicationCacheDelta {
        var visualUpserts: [ViewID: VisualLayerCache] = [:]
        var visualRemovals: Set<ViewID> = []
        var placementUpserts: [WindowID: PlacementLayerCache] = [:]
        var placementRemovals: Set<WindowID> = []
        var hiddenLayerCountDelta = 0
        var traversalUpdates: [ViewID: TraversalUpdate] = [:]
        var paintInsertions: [PaintCacheKey: [PaintCacheEntry]] = [:]
        var paintReferenceChanges: [PaintReferenceChange] = []

        func visual(
            _ id: ViewID,
            base: [ViewID: VisualLayerCache]
        ) -> VisualLayerCache? {
            guard !visualRemovals.contains(id) else { return nil }
            return visualUpserts[id] ?? base[id]
        }

        mutating func upsertVisual(
            _ state: VisualLayerCache,
            for id: ViewID
        ) {
            visualRemovals.remove(id)
            visualUpserts[id] = state
        }

        mutating func removeVisual(
            _ id: ViewID,
            base: [ViewID: VisualLayerCache]
        ) -> VisualLayerCache? {
            guard let state = visual(id, base: base) else { return nil }
            visualUpserts[id] = nil
            visualRemovals.insert(id)
            return state
        }

        func placement(
            _ id: WindowID,
            base: [WindowID: PlacementLayerCache]
        ) -> PlacementLayerCache? {
            guard !placementRemovals.contains(id) else { return nil }
            return placementUpserts[id] ?? base[id]
        }

        mutating func upsertPlacement(
            _ state: PlacementLayerCache,
            for id: WindowID
        ) {
            placementRemovals.remove(id)
            placementUpserts[id] = state
        }

        mutating func removePlacement(
            _ id: WindowID,
            base: [WindowID: PlacementLayerCache]
        ) -> PlacementLayerCache? {
            guard let state = placement(id, base: base) else { return nil }
            placementUpserts[id] = nil
            placementRemovals.insert(id)
            return state
        }
    }

    func apply(cacheDelta: PublicationCacheDelta) {
        for viewID in cacheDelta.visualRemovals {
            visualLayers[viewID] = nil
        }
        for (viewID, state) in cacheDelta.visualUpserts {
            visualLayers[viewID] = state
        }
        for placementID in cacheDelta.placementRemovals {
            placementLayers[placementID] = nil
        }
        for (placementID, state) in cacheDelta.placementUpserts {
            placementLayers[placementID] = state
        }

        for (viewID, update) in cacheDelta.traversalUpdates {
            guard var state = visualLayers[viewID] else { continue }
            state.dirtyGenerations = update.dirty
            state.subtreeDirtyGenerations = update.subtree
            if let children = update.children {
                state.childViewIDs = children
            }
            visualLayers[viewID] = state
            update.view.dirtyChildViewIDs.removeAll(
                keepingCapacity: true)
        }

        hiddenVisualLayerCount += cacheDelta.hiddenLayerCountDelta
        applyPaintCacheDelta(cacheDelta)
    }
}
