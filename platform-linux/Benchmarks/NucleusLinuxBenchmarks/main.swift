import Foundation // FileHandle.standardError reports benchmark failures.
import NucleusBenchmarkSupport
import NucleusLinuxAccessibility
import NucleusUI

@main
struct NucleusLinuxBenchmarks {
    @MainActor
    static func main() async {
        do {
            try await BenchmarkProgram.run(
                workloads: [
                    atSPIProjectionWorkload(nodeCount: 10_000),
                    reactorWakeCoalescingWorkload(wakeCount: 10_000),
                    reactorReadinessBacklogWorkload(
                        descriptorCount: 256,
                        completionBudget: 32),
                    reactorCancellationChurnWorkload(replacementCount: 4_096),
                ],
                arguments: Array(CommandLine.arguments.dropFirst()),
                productName: "NucleusLinuxBenchmarks")
        } catch {
            FileHandle.standardError.write(
                Data("benchmark error: \(error)\n".utf8))
            exit(1)
        }
    }
}

@MainActor
private func atSPIProjectionWorkload(
    nodeCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "host-projection",
        name: "at-spi-initial-clean-one-node-\(nodeCount)",
        inputSize: UInt64(nodeCount),
        seed: 0x4154_5350_4932_0001,
        budgets: [
            .exact("initial_objects_projected", UInt64(nodeCount + 1)),
            .exact("initial_exported_objects", UInt64(nodeCount + 1)),
            .exact("initial_added_paths", UInt64(nodeCount + 1)),
            .exact("clean_objects_projected", 0),
            .exact("clean_events", 0),
            .exact("incremental_objects_projected", 1),
            .exact("incremental_objects_reused", UInt64(nodeCount)),
            .exact("incremental_events", 1),
            .exact("incremental_added_paths", 0),
            .exact("incremental_removed_paths", 0),
        ],
        body: {
            precondition(nodeCount >= 3)
            var phases = BenchmarkPhaseRecorder()
            var initialSnapshot = AccessibilityTreeSnapshot()
            var initialUpdate = AccessibilityTreeUpdate(
                revision: 0,
                rootIDs: [],
                inserted: [],
                updated: [],
                removed: [],
                notifications: [])
            let targetID = AccessibilityID(
                context: 1,
                ordinal: UInt64(nodeCount))
            var copiedBytes: UInt64 = 0

            phases.measure("setup") {
                let windowID = AccessibilityID(context: 1, ordinal: 1)
                let listID = AccessibilityID(context: 1, ordinal: 2)
                let itemIDs = (3...nodeCount).map {
                    AccessibilityID(context: 1, ordinal: UInt64($0))
                }
                var nodes: [
                    AccessibilityID: AccessibilityNodeSnapshot
                ] = [:]
                nodes.reserveCapacity(nodeCount)
                nodes[windowID] = benchmarkAccessibilityNode(
                    id: windowID,
                    parentID: nil,
                    childIDs: [listID],
                    role: .window,
                    label: "Benchmark")
                nodes[listID] = benchmarkAccessibilityNode(
                    id: listID,
                    parentID: windowID,
                    childIDs: itemIDs,
                    role: .list,
                    label: "Items")
                for (index, id) in itemIDs.enumerated() {
                    let label = "item-\(index)"
                    copiedBytes += UInt64(label.utf8.count)
                    nodes[id] = benchmarkAccessibilityNode(
                        id: id,
                        parentID: listID,
                        childIDs: [],
                        role: .listItem,
                        label: label)
                }
                initialSnapshot = AccessibilityTreeSnapshot(
                    revision: 1,
                    rootIDs: [windowID],
                    nodes: nodes)
                initialUpdate = AccessibilityTreeUpdate(
                    revision: 1,
                    rootIDs: [windowID],
                    inserted: nodes.values.sorted { $0.id < $1.id },
                    updated: [],
                    removed: [],
                    notifications: [])
            }

            var model: AtSPIExportModel? = AtSPIExportModel(
                applicationName: "NucleusBenchmark")
            let initial = phases.measure("initial_projection") {
                model!.project(
                    snapshot: initialSnapshot,
                    update: initialUpdate)
            }
            let clean = phases.measure("clean_projection") {
                model!.project(
                    snapshot: initialSnapshot,
                    update: AccessibilityTreeUpdate(
                        revision: 1,
                        rootIDs: initialSnapshot.rootIDs,
                        inserted: [],
                        updated: [],
                        removed: [],
                        notifications: []))
            }

            var revisedSnapshot = initialSnapshot
            var revisedNode = revisedSnapshot.nodes[targetID]!
            revisedNode.label = "changed-item"
            revisedSnapshot.revision = 2
            revisedSnapshot.nodes[targetID] = revisedNode
            copiedBytes += UInt64("changed-item".utf8.count)
            let incremental = phases.measure("incremental_projection") {
                model!.project(
                    snapshot: revisedSnapshot,
                    update: AccessibilityTreeUpdate(
                        revision: 2,
                        rootIDs: revisedSnapshot.rootIDs,
                        inserted: [],
                        updated: [revisedNode],
                        removed: [],
                        notifications: []))
            }
            phases.measure("teardown") {
                model = nil
            }

            var checksum = initial.exportedObjects
            checksum.mix(initial.emittedEvents)
            checksum.mix(clean.objectsReused)
            checksum.mix(incremental.emittedEvents)
            return BenchmarkSample(
                metrics: [
                    "initial_objects_projected": initial.objectsProjected,
                    "initial_exported_objects": initial.exportedObjects,
                    "initial_added_paths": initial.addedPaths,
                    "initial_events": initial.emittedEvents,
                    "clean_objects_projected": clean.objectsProjected,
                    "clean_objects_reused": clean.objectsReused,
                    "clean_events": clean.emittedEvents,
                    "incremental_objects_projected":
                        incremental.objectsProjected,
                    "incremental_objects_reused": incremental.objectsReused,
                    "incremental_events": incremental.emittedEvents,
                    "incremental_added_paths": incremental.addedPaths,
                    "incremental_removed_paths": incremental.removedPaths,
                    "copied_bytes": copiedBytes,
                ],
                semanticChecksum: checksum,
                phaseNanoseconds: phases.phaseNanoseconds)
        })
}

private func benchmarkAccessibilityNode(
    id: AccessibilityID,
    parentID: AccessibilityID?,
    childIDs: [AccessibilityID],
    role: AccessibilityRole,
    label: String
) -> AccessibilityNodeSnapshot {
    AccessibilityNodeSnapshot(
        id: id,
        parentID: parentID,
        childIDs: childIDs,
        windowID: WindowID(rawValue: 1),
        role: role,
        label: label,
        description: nil,
        value: nil,
        state: [.enabled, .visible],
        actions: [],
        orientation: nil,
        rangeValue: nil,
        textSelection: nil,
        relationships: [:],
        frameInScene: .zero,
        liveRegion: .off)
}
