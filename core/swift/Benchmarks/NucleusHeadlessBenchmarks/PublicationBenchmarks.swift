@_spi(NucleusCompositor) import NucleusLayers
import NucleusBenchmarkSupport
import NucleusUI

@MainActor
func publicationBenchmarks() -> [BenchmarkWorkload] {
    [
        flatPublicationWorkload(nodeCount: 1_000),
        flatPublicationWorkload(nodeCount: 10_000),
        deepPublicationWorkload(nodeCount: 4_096),
    ]
}

@MainActor
private func flatPublicationWorkload(nodeCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "publication",
        name: "flat-retained-\(nodeCount)",
        inputSize: UInt64(nodeCount),
        seed: 0x5055_424c_4943_4154,
        budgets: [
            .exact("initial_nodes_visited", UInt64(nodeCount)),
            .exact("clean_nodes_visited", 1),
            .exact("clean_subtrees_skipped", 1),
            .exact("clean_commits", 0),
            .exact("dirty_nodes_visited", 2),
            .exact("dirty_snapshots_authored", 1),
            .exact("dirty_property_updates", 1),
            .exact("reorder_topology_mutations", 1),
            .maximum("allocation_units", UInt64(nodeCount + 2)),
            .exact("retained_after_teardown", 0),
        ],
        body: {
            var phases = BenchmarkPhaseRecorder()
            let visualContext = Application.makeInMemoryVisualContext()
            return try Application.withContext(visualContext) {
                let (root, children, publisher) = phases.measure("setup") {
                    let root = View()
                    var children: [View] = []
                    children.reserveCapacity(nodeCount - 1)
                    for _ in 1..<nodeCount {
                        let child = View()
                        root.addSubview(child)
                        children.append(child)
                    }
                    return (
                        root,
                        children,
                        ViewLayerPublisher(context: visualContext))
                }

                _ = try phases.measure("initial_publication") {
                    try publisher.publish(roots: [root])
                }
                let initial = publisher.lastMetrics

                _ = try phases.measure("clean_publication") {
                    try publisher.publish(roots: [root])
                }
                let clean = publisher.lastMetrics

                let dirtyTarget = children[nodeCount / 2]
                dirtyTarget.alphaValue = 0.5
                _ = try phases.measure("dirty_publication") {
                    try publisher.publish(roots: [root])
                }
                let dirty = publisher.lastMetrics

                // A retained reorder must preserve the existing visual object.
                let targetLayer = publisher.visualLayer(for: dirtyTarget)
                root.addSubview(dirtyTarget)
                _ = try phases.measure("reorder_publication") {
                    try publisher.publish(roots: [root])
                }
                guard publisher.visualLayer(for: dirtyTarget) === targetLayer else {
                    throw BenchmarkFailure.semantic(
                        "flat publication replaced a retained visual during reorder")
                }
                let reorder = publisher.lastMetrics
                let allocations = UInt64(
                    publisher.publishedVisualLayerCount
                        + publisher.retainedPaintRegistrationCount
                        + 1)

                try phases.measure("teardown") {
                    try publisher.invalidate()
                }
                let retainedAfterTeardown = UInt64(
                    publisher.publishedVisualLayerCount
                        + publisher.retainedPaintRegistrationCount
                        + visualContext.layers.count)
                var checksum = UInt64(nodeCount)
                checksum.mix(initial.layersCreated)
                checksum.mix(dirty.propertyUpdates)
                checksum.mix(reorder.layersReparented)
                return BenchmarkSample(
                    metrics: [
                        "initial_nodes_visited": initial.nodesVisited,
                        "initial_layers_staged": initial.layersCreated,
                        "initial_topology_mutations": initial.layersCreated
                            + initial.layersReparented,
                        "initial_paint_bytes": initial.paintBytes,
                        "clean_nodes_visited": clean.nodesVisited,
                        "clean_subtrees_skipped": clean.cleanSubtreesSkipped,
                        "clean_commits": clean.commits,
                        "dirty_nodes_visited": dirty.nodesVisited,
                        "dirty_snapshots_authored": dirty.snapshotsAuthored,
                        "dirty_property_updates": dirty.propertyUpdates,
                        "reorder_nodes_visited": reorder.nodesVisited,
                        "reorder_topology_mutations": reorder.layersReparented,
                        "allocation_units": allocations,
                        "copied_bytes": 0,
                        "retained_after_teardown": retainedAfterTeardown,
                    ],
                    semanticChecksum: checksum,
                    phaseNanoseconds: phases.phaseNanoseconds)
            }
        })
}

@MainActor
private func deepPublicationWorkload(nodeCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "publication",
        name: "deep-localized-dirty-\(nodeCount)",
        inputSize: UInt64(nodeCount),
        seed: 0x4445_4550_5452_4545,
        budgets: [
            .exact("initial_nodes_visited", UInt64(nodeCount)),
            .exact("clean_nodes_visited", 1),
            .exact("clean_commits", 0),
            .exact("dirty_nodes_visited", UInt64(nodeCount)),
            .exact("dirty_snapshots_authored", 1),
            .exact("dirty_property_updates", 1),
            .exact("retained_after_teardown", 0),
        ],
        body: {
            var phases = BenchmarkPhaseRecorder()
            let visualContext = Application.makeInMemoryVisualContext()
            return try Application.withContext(visualContext) {
                let (root, leaf, publisher) = phases.measure("setup") {
                    let root = View()
                    var leaf = root
                    for _ in 1..<nodeCount {
                        let child = View()
                        leaf.addSubview(child)
                        leaf = child
                    }
                    return (
                        root,
                        leaf,
                        ViewLayerPublisher(context: visualContext))
                }
                _ = try phases.measure("initial_publication") {
                    try publisher.publish(roots: [root])
                }
                let initial = publisher.lastMetrics
                _ = try phases.measure("clean_publication") {
                    try publisher.publish(roots: [root])
                }
                let clean = publisher.lastMetrics
                leaf.alphaValue = 0.25
                _ = try phases.measure("dirty_publication") {
                    try publisher.publish(roots: [root])
                }
                let dirty = publisher.lastMetrics
                let allocationUnits = UInt64(publisher.publishedVisualLayerCount + 1)
                try phases.measure("teardown") {
                    try publisher.invalidate()
                }
                let retained = UInt64(
                    publisher.publishedVisualLayerCount + visualContext.layers.count)
                var checksum = UInt64(nodeCount)
                checksum.mix(initial.layersCreated)
                checksum.mix(dirty.propertyUpdates)
                return BenchmarkSample(
                    metrics: [
                        "initial_nodes_visited": initial.nodesVisited,
                        "initial_layers_staged": initial.layersCreated,
                        "clean_nodes_visited": clean.nodesVisited,
                        "clean_subtrees_skipped": clean.cleanSubtreesSkipped,
                        "clean_commits": clean.commits,
                        "dirty_nodes_visited": dirty.nodesVisited,
                        "dirty_snapshots_authored": dirty.snapshotsAuthored,
                        "dirty_property_updates": dirty.propertyUpdates,
                        "allocation_units": allocationUnits,
                        "copied_bytes": 0,
                        "retained_after_teardown": retained,
                    ],
                    semanticChecksum: checksum,
                    phaseNanoseconds: phases.phaseNanoseconds)
            }
        })
}
