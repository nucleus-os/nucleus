@_spi(NucleusCompositor) import NucleusLayers

extension ViewLayerPublisher {
    struct SnapshotRect: Sendable, Equatable {
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

    struct ViewLayerSnapshot {
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

    struct PlacementSnapshot: Sendable, Equatable {
        var id: WindowID
        var frame: GeometryRect
        var siblingIndex: UInt32
    }

    struct TraversalUpdate {
        var view: View
        var dirty: ViewDirtyGenerations
        var subtree: ViewDirtyGenerations
        var children: [ViewID]?
    }

    struct TraversalWorkItem {
        var view: View
        var parentViewID: ViewID?
        var rootPlacementID: WindowID?
        var siblingIndex: UInt32
        var forceSnapshot: Bool
    }

    func appendDirtyViewTrees(
        work: inout [TraversalWorkItem],
        snapshots: inout [ViewLayerSnapshot],
        traversalUpdates: inout [ViewID: TraversalUpdate],
        removalCandidates: inout Set<ViewID>,
        structurallyPresent: inout Set<ViewID>,
        metrics: inout ViewPublicationMetrics
    ) {
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

            traversalUpdates[view.id] = TraversalUpdate(
                view: view,
                dirty: view.dirtyGenerations,
                subtree: view.subtreeDirtyGenerations,
                children: childIDs)
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

    func makeSnapshot(
        _ view: View,
        parentViewID: ViewID?,
        rootPlacementID: WindowID?,
        siblingIndex: UInt32
    ) -> ViewLayerSnapshot {
        let content = view.layerContent
        let presentation = content.presentation
        let frame = view.frame
        let backdropMaterial =
            view.properties.backdropMaterial ?? view.semanticBackdropMaterial
        let creationFrame = presentation.creationFrame.map {
            SnapshotRect(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.size.width,
                height: $0.size.height)
        }
        let requests = view.animationRequests.values.sorted {
            if $0.generation != $1.generation {
                return $0.generation < $1.generation
            }
            return animationKeyPath(of: $0).rawValue
                < animationKeyPath(of: $1).rawValue
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
                height: frame.size.height),
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
                    }),
            dirtyGenerations: view.dirtyGenerations,
            subtreeDirtyGenerations: view.subtreeDirtyGenerations,
            creationFrame: creationFrame,
            creationOpacity: presentation.creationOpacity,
            animationRequests: requests)
    }

    func recordDirtyDomains(
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

    func removalDepth(of viewID: ViewID) -> Int {
        var depth = 0
        var parent = visualLayers[viewID]?.parentViewID
        while let current = parent {
            depth += 1
            parent = visualLayers[current]?.parentViewID
        }
        return depth
    }

    func removedCachedSubtrees(
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

    func animationKeyPath(
        of request: ViewAnimationRequest
    ) -> AnimationKeyPath {
        switch request.operation {
        case .add(let animation): animation.keyPath
        case .remove(let keyPath): keyPath
        }
    }
}
