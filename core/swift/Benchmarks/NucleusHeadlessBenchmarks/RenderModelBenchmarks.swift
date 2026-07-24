import NucleusBenchmarkSupport
import NucleusRenderModel

@MainActor
func renderModelBenchmarks() -> [BenchmarkWorkload] {
    [
        retainedTreeWorkload(layerCount: 10_000),
        sparseTransactionValidationWorkload(layerCount: 10_000),
        animationCompletionWorkload(animationCount: 1_000),
        damageRegionWorkload(rectangleCount: 256),
    ]
}

@MainActor
private func sparseTransactionValidationWorkload(
    layerCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "render-model",
        name: "sparse-transaction-validation-\(layerCount)",
        inputSize: UInt64(layerCount),
        seed: 0x5350_4152_5345_5458,
        budgets: [
            .exact("retained_layers", UInt64(layerCount)),
            .exact("updated_layers", 1),
            .exact("reparented_layers", 1),
            .maximum("validation_nodes_visited", 2),
            .maximum("validation_ancestor_steps", 2),
            .maximum("apply_dictionary_probes", 1),
            .maximum("reparent_validation_nodes_visited", 3),
            .maximum("reparent_validation_ancestor_steps", 2),
            .maximum("reparent_apply_dictionary_probes", 3),
        ],
        body: {
            let context = ContextID(raw: 40)
            var tree = LayerTree()
            var creation = Transaction(contextId: context)
            creation.created.reserveCapacity(layerCount)
            creation.inserted.reserveCapacity(layerCount)
            for id in 1...layerCount {
                creation.created.append(LayerCreated(
                    nodeId: UInt64(id),
                    kind: .container))
                creation.inserted.append(LayerInserted(
                    nodeId: UInt64(id),
                    parentId: id == 1 ? 0 : 1,
                    index: UInt32(id - 1)))
            }
            guard case .success = TransactionApplier.apply(
                creation,
                to: &tree)
            else {
                throw BenchmarkFailure.semantic(
                    "large retained tree setup was rejected")
            }

            var property = LayerPropertyUpdate(nodeId: 2)
            property.opacity = 0.625
            var update = Transaction(contextId: context)
            update.propertyUpdates = [property]
            var diagnostics = TransactionApplier.ApplyDiagnostics()
            guard case .success = TransactionApplier.apply(
                update,
                to: &tree,
                diagnostics: &diagnostics)
            else {
                throw BenchmarkFailure.semantic(
                    "one-node retained-tree update was rejected")
            }
            guard tree.layers.count == layerCount,
                  tree.get(2)?.model.properties.opacity == 0.625
            else {
                throw BenchmarkFailure.semantic(
                    "one-node retained-tree update changed unrelated topology")
            }

            var reparent = Transaction(contextId: context)
            reparent.inserted = [
                LayerInserted(nodeId: 2, parentId: 3, index: 0),
            ]
            var reparentDiagnostics =
                TransactionApplier.ApplyDiagnostics()
            guard case .success = TransactionApplier.apply(
                reparent,
                to: &tree,
                diagnostics: &reparentDiagnostics)
            else {
                throw BenchmarkFailure.semantic(
                    "one-node retained-tree reparent was rejected")
            }
            guard tree.get(2)?.parent == 3,
                  tree.get(3)?.children == [2],
                  tree.get(1)?.children.contains(2) == false
            else {
                throw BenchmarkFailure.semantic(
                    "one-node retained-tree reparent produced invalid topology")
            }

            var checksum = UInt64(tree.layers.count)
            checksum.mix(UInt64(
                tree.get(2)?.model.properties.opacity.bitPattern ?? 0))
            checksum.mix(tree.get(2)?.parent ?? 0)
            return BenchmarkSample(
                metrics: [
                    "retained_layers": UInt64(tree.layers.count),
                    "updated_layers": 1,
                    "reparented_layers": 1,
                    "validation_nodes_visited":
                        diagnostics.validationNodesVisited,
                    "validation_ancestor_steps":
                        diagnostics.validationAncestorSteps,
                    "apply_dictionary_probes":
                        diagnostics.applyDictionaryProbes,
                    "reparent_validation_nodes_visited":
                        reparentDiagnostics.validationNodesVisited,
                    "reparent_validation_ancestor_steps":
                        reparentDiagnostics.validationAncestorSteps,
                    "reparent_apply_dictionary_probes":
                        reparentDiagnostics.applyDictionaryProbes,
                ],
                semanticChecksum: checksum)
        })
}

@MainActor
private func retainedTreeWorkload(layerCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "render-model",
        name: "transaction-apply-snapshot-\(layerCount)",
        inputSize: UInt64(layerCount),
        seed: 0x5245_4e44_4552_5452,
        budgets: [
            .exact("created_layers", UInt64(layerCount)),
            .exact("initial_revision", 1),
            .exact("empty_ingest_revision_delta", 0),
            .exact("clean_pending_damage", 0),
            .exact("invalid_transactions_accepted", 0),
            .exact("remaining_layers", UInt64(layerCount - 1_000)),
        ],
        body: {
            let context = ContextID(raw: 41)
            let resourceHost = SwiftResourceHost()
            let store = RetainedTreeStore(resourceHost: resourceHost)
            var creation = Transaction(contextId: context)
            creation.created.reserveCapacity(layerCount)
            creation.inserted.reserveCapacity(layerCount)
            for id in 1...layerCount {
                var layer = LayerCreated(
                    nodeId: UInt64(id),
                    kind: .container)
                layer.bounds = Bounds(
                    w: Float(32 + id % 257),
                    h: Float(24 + id % 193))
                if id % 7 == 0 {
                    layer.initialContent = .paint(
                        PaintContentHandle(raw: UInt64(id)))
                }
                creation.created.append(layer)
                creation.inserted.append(LayerInserted(
                    nodeId: UInt64(id),
                    parentId: id == 1 ? 0 : 1,
                    index: UInt32(id - 1)))
            }
            guard case .success = store.ingest(creation) else {
                throw BenchmarkFailure.semantic(
                    "large render transaction was rejected")
            }
            let initialRevision = store.revision
            let initialShape: (Int, Int) = {
                let snapshot = store.snapshot()
                return (
                    snapshot.layers.count,
                    snapshot.get(1)?.children.count ?? -1)
            }()
            guard initialShape == (layerCount, layerCount - 1) else {
                throw BenchmarkFailure.semantic(
                    "large render transaction produced the wrong topology")
            }

            store.markPresented()
            let cleanDamage = store.hasPendingDamage ? 1 : 0
            let beforeEmpty = store.revision
            _ = store.ingest(Transaction(contextId: context))
            let emptyDelta = store.revision - beforeEmpty

            var invalid = Transaction(contextId: context)
            invalid.propertyUpdates.append(LayerPropertyUpdate(
                nodeId: UInt64(layerCount + 1)))
            let beforeInvalid = store.revision
            let invalidAccepted: UInt64
            switch store.ingest(invalid) {
            case .success:
                invalidAccepted = 1
            case .failure:
                invalidAccepted = 0
            }
            guard store.revision == beforeInvalid else {
                throw BenchmarkFailure.semantic(
                    "rejected render transaction changed the revision")
            }

            var updates = Transaction(contextId: context)
            updates.propertyUpdates.reserveCapacity(1_000)
            for id in 2...1_001 {
                var update = LayerPropertyUpdate(nodeId: UInt64(id))
                update.position = Point2D(x: Float(id), y: Float(id / 2))
                update.contentDamage = Rect(x: 1, y: 2, w: 8, h: 9)
                updates.propertyUpdates.append(update)
            }
            guard case .success = store.ingest(updates) else {
                throw BenchmarkFailure.semantic("render updates were rejected")
            }

            var removals = Transaction(contextId: context)
            removals.removed.reserveCapacity(1_000)
            for id in (layerCount - 999)...layerCount {
                removals.removed.append(LayerRemoved(nodeId: UInt64(id)))
            }
            guard case .success = store.ingest(removals) else {
                throw BenchmarkFailure.semantic("render removals were rejected")
            }
            let remaining = store.snapshot().layers.count
            guard remaining == layerCount - 1_000 else {
                throw BenchmarkFailure.semantic(
                    "render removal count mismatch: \(remaining)")
            }
            let copiedBytes = UInt64(layerCount)
                * UInt64(MemoryLayout<LayerCreated>.stride)
                + UInt64(layerCount)
                    * UInt64(MemoryLayout<LayerInserted>.stride)
                + 1_000 * UInt64(MemoryLayout<LayerPropertyUpdate>.stride)
            var checksum = UInt64(remaining)
            checksum.mix(store.revision)
            checksum.mix(UInt64(store.liveLayerIDs.count))
            return BenchmarkSample(
                metrics: [
                    "created_layers": UInt64(layerCount),
                    "insertions": UInt64(layerCount),
                    "initial_revision": initialRevision,
                    "empty_ingest_revision_delta": emptyDelta,
                    "clean_pending_damage": UInt64(cleanDamage),
                    "invalid_transactions_accepted": invalidAccepted,
                    "property_updates": 1_000,
                    "removed_layers": 1_000,
                    "remaining_layers": UInt64(remaining),
                    "copied_bytes": copiedBytes,
                    "resource_operations": 0,
                ],
                semanticChecksum: checksum)
        })
}

@MainActor
private func animationCompletionWorkload(
    animationCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "render-model",
        name: "animation-completion-batch-\(animationCount)",
        inputSize: UInt64(animationCount),
        seed: 0x414e_494d_434f_4d50,
        budgets: [
            .exact("animations_started", UInt64(animationCount)),
            .exact("animations_remaining", 0),
            .exact("completion_records", 1),
            .exact("completion_callbacks", 1),
            .exact("completion_observers_after_teardown", 0),
        ],
        body: {
            let store = RetainedTreeStore(resourceHost: SwiftResourceHost())
            let context = ContextID(raw: 42)
            let completionToken = CompletionToken(raw: 0x4242)
            var transaction = Transaction(contextId: context)
            transaction.completionToken = completionToken.raw
            transaction.created.reserveCapacity(animationCount)
            transaction.inserted.reserveCapacity(animationCount)
            transaction.animationsAdded.reserveCapacity(animationCount)
            for index in 0..<animationCount {
                let id = UInt64(index + 1)
                transaction.created.append(LayerCreated(
                    nodeId: id,
                    kind: .container))
                transaction.inserted.append(LayerInserted(
                    nodeId: id,
                    parentId: index == 0 ? 0 : 1,
                    index: UInt32(index)))
                transaction.animationsAdded.append(AnimationRecord(
                    id: AnimationID(raw: id),
                    layerId: id,
                    animation: .basic(BasicAnimation(
                        keyPath: .opacity,
                        fromValue: 0,
                        toValue: 1,
                        duration: 0.25,
                        timingFunction: .linear)),
                    completionToken: completionToken,
                    transactionId: 99))
            }
            var completionEvents: [PresentationCompletionEvent] = []
            let observer = store.addCompletionObserver {
                completionEvents.append($0)
            }
            guard case .success = store.ingest(transaction) else {
                throw BenchmarkFailure.semantic(
                    "animation batch transaction was rejected")
            }
            let started = store.drainAnimationEvents().reduce(into: 0) {
                if case .started = $1 { $0 += 1 }
            }
            _ = store.tick(presentTimeNs: 250_000_000)
            let terminalEvents = store.drainAnimationEvents()
            let stopped = terminalEvents.reduce(into: 0) {
                if case .stopped = $1 { $0 += 1 }
            }
            store.markPresented()
            guard completionEvents == [PresentationCompletionEvent(
                token: completionToken.raw,
                outcome: .completed)]
            else {
                throw BenchmarkFailure.semantic(
                    "animation batch completion did not resolve once")
            }
            store.removeCompletionObserver(observer)
            var checksum = UInt64(started)
            checksum.mix(UInt64(stopped))
            checksum.mix(UInt64(completionEvents.count))
            return BenchmarkSample(
                metrics: [
                    "animations_started": UInt64(started),
                    "animations_stopped": UInt64(stopped),
                    "animations_remaining": store.hasActiveAnimations ? 1 : 0,
                    "completion_records": UInt64(completionEvents.count),
                    "completion_callbacks": UInt64(completionEvents.count),
                    "completion_observers_after_teardown": 0,
                    "copied_bytes": UInt64(animationCount)
                        * UInt64(MemoryLayout<AnimationRecord>.stride),
                ],
                semanticChecksum: checksum)
        })
}

@MainActor
private func damageRegionWorkload(
    rectangleCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "render-model",
        name: "damage-region-simplification-\(rectangleCount)",
        inputSize: UInt64(rectangleCount),
        seed: 0x4441_4d41_4745_5247,
        budgets: [
            .exact("rectangles_before", UInt64(rectangleCount)),
            .exact("rectangles_after", 1),
            .exact("coverage_checks_failed", 0),
        ],
        body: {
            let rectangles = (0..<rectangleCount).map { index in
                RegionRect(
                    x: Int32((index % 32) * 12),
                    y: Int32((index / 32) * 12),
                    width: 8,
                    height: 8)
            }
            let exact = Region(rectangles: rectangles)
            let conservative = exact.conservative(maxRectangles: 8)
            var failedCoverage: UInt64 = 0
            for rectangle in rectangles where !conservative.contains(rectangle) {
                failedCoverage &+= 1
            }
            guard conservative.bounds == exact.bounds else {
                throw BenchmarkFailure.semantic(
                    "conservative damage changed the aggregate bounds")
            }
            var checksum = UInt64(exact.rectangleCount)
            checksum.mix(UInt64(conservative.rectangleCount))
            checksum.mix(UInt64(bitPattern: Int64(exact.bounds?.width ?? 0)))
            return BenchmarkSample(
                metrics: [
                    "rectangles_before": UInt64(exact.rectangleCount),
                    "rectangles_after": UInt64(conservative.rectangleCount),
                    "coverage_checks_failed": failedCoverage,
                    "copied_bytes": UInt64(rectangles.count)
                        * UInt64(MemoryLayout<RegionRect>.stride),
                ],
                semanticChecksum: checksum)
        })
}
