import Foundation
import NucleusBenchmarkSupport
import NucleusReactRuntimeCxx
import NucleusUI
import Synchronization

private final class BenchmarkMountScheduler: Sendable {
    private struct State: Sendable {
        var operations: [MountDrainOperation] = []
        var head = 0
    }

    private let state = Mutex(State())

    func schedule(_ operation: @escaping MountDrainOperation) {
        state.withLock { $0.operations.append(operation) }
    }

    @MainActor
    func runAll() -> Int {
        var count = 0
        while let operation = state.withLock({
            state -> MountDrainOperation? in
            guard state.head < state.operations.count else {
                state.operations.removeAll(keepingCapacity: true)
                state.head = 0
                return nil
            }
            let operation = state.operations[state.head]
            state.head += 1
            return operation
        }) {
            operation()
            count += 1
        }
        return count
    }
}

@main
struct NucleusReactBenchmarks {
    @MainActor
    static func main() async {
        do {
            try await BenchmarkProgram.run(
                workloads: [mountWorkload(componentCount: 5_000)],
                arguments: Array(CommandLine.arguments.dropFirst()),
                productName: "NucleusReactBenchmarks")
        } catch {
            FileHandle.standardError.write(
                Data("benchmark error: \(error)\n".utf8))
            exit(1)
        }
    }
}

@MainActor
private func mountWorkload(
    componentCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "host-projection",
        name: "rn-mount-create-update-delete-\(componentCount)",
        inputSize: UInt64(componentCount),
        seed: 0x524e_4d4f_554e_5401,
        budgets: [
            .exact("batches_queued", 3),
            .exact("drain_tasks_scheduled", 3),
            .exact("batches_drained", 3),
            .exact("mutations_materialized", UInt64(componentCount * 5)),
            .exact("stale_batches_rejected", 0),
            .exact("pure_removal_batches", 1),
            .exact("bulk_removal_groups", 1),
            .exact("bulk_removed_children", UInt64(componentCount)),
            .exact("initial_components", UInt64(componentCount + 1)),
            .exact("initial_subviews", UInt64(componentCount)),
            .exact("updated_components", UInt64(componentCount + 1)),
            .exact("remaining_components", 1),
            .exact("remaining_subviews", 0),
            .exact("queued_after_teardown", 0),
            .exact("generations_after_teardown", 0),
            .exact("retired_after_teardown", 0),
            .exact("in_flight_after_teardown", 0),
        ],
        body: {
            let uiContext = UIContext(services: .inMemory())
            return try uiContext.construct {
                let surfaceID = 1
                let scheduler = BenchmarkMountScheduler()
                let consumer = MountConsumer(
                    scheduleDrain: scheduler.schedule)
                let root = View()
                let registry = ViewComponentViewRegistry()
                let context = MountSurfaceContext(
                    surfaceID: surfaceID,
                    rootView: root,
                    registry: registry,
                    environment: ReactSurfaceEnvironment())
                var phases = BenchmarkPhaseRecorder()
                phases.measure("setup") {
                    consumer.registerContext(context)
                }

                phases.measure("initial_enqueue") {
                    for index in 0..<componentCount {
                        let tag = index + 2
                        consumer.enqueue(.create(
                            surfaceID: surfaceID,
                            tag: tag,
                            componentName: "View",
                            component: .view(
                                MountViewSnapshot(
                                    nativeID: "node-\(index)",
                                    frame: Rect(
                                        x: 0,
                                        y: Double(index),
                                        width: 100,
                                        height: 1)),
                                backgroundColor: nil)))
                        consumer.enqueue(.insert(
                            surfaceID: surfaceID,
                            parentTag: surfaceID,
                            childTag: tag,
                            index: index))
                    }
                    consumer.didFinishTransaction(
                        surfaceID: Int32(surfaceID))
                }
                let initialDrainTasks = phases.measure("initial_drain") {
                    scheduler.runAll()
                }
                guard initialDrainTasks == 1 else {
                    throw BenchmarkFailure.semantic(
                        "initial RN mount burst scheduled \(initialDrainTasks) drains")
                }
                let initialComponents = registry.components.count
                let initialSubviews = root.subviews.count

                phases.measure("update_enqueue") {
                    for index in 0..<componentCount {
                        consumer.enqueue(.update(
                            surfaceID: surfaceID,
                            tag: index + 2,
                            component: .view(
                                MountViewSnapshot(
                                    nativeID: "updated-\(index)",
                                    frame: Rect(
                                        x: 1,
                                        y: Double(index),
                                        width: 101,
                                        height: 1)),
                                backgroundColor: nil)))
                    }
                    consumer.didFinishTransaction(
                        surfaceID: Int32(surfaceID))
                }
                let updateDrainTasks = phases.measure("update_drain") {
                    scheduler.runAll()
                }
                guard updateDrainTasks == 1 else {
                    throw BenchmarkFailure.semantic(
                        "RN update burst scheduled \(updateDrainTasks) drains")
                }
                let updatedComponents = registry.components.count

                phases.measure("delete_enqueue") {
                    for index in 0..<componentCount {
                        let tag = index + 2
                        consumer.enqueue(.remove(
                            surfaceID: surfaceID,
                            childTag: tag))
                        consumer.enqueue(.delete(
                            surfaceID: surfaceID,
                            tag: tag))
                    }
                    consumer.didFinishTransaction(
                        surfaceID: Int32(surfaceID))
                }
                let deleteDrainTasks = phases.measure("delete_drain") {
                    scheduler.runAll()
                }
                guard deleteDrainTasks == 1 else {
                    throw BenchmarkFailure.semantic(
                        "RN delete burst scheduled \(deleteDrainTasks) drains")
                }
                let remainingComponents = registry.components.count
                let remainingSubviews = root.subviews.count
                let metrics = consumer.metricsSnapshot()
                var bookkeeping = consumer.bookkeepingCounts()
                phases.measure("teardown") {
                    consumer.unregisterContext(surfaceID: surfaceID)
                    bookkeeping = consumer.bookkeepingCounts()
                }

                var checksum = UInt64(initialComponents)
                checksum.mix(UInt64(updatedComponents))
                checksum.mix(UInt64(remainingComponents))
                checksum.mix(metrics.mutationsMaterialized)
                let copiedBytes = metrics.copiedComponentNameBytes
                    + metrics.copiedTextBytes
                    + metrics.copiedNativeIDBytes
                    + metrics.copiedImageBytes
                return BenchmarkSample(
                    metrics: [
                        "batches_queued": metrics.completedBatchesQueued,
                        "drain_tasks_scheduled": metrics.drainTasksScheduled,
                        "batches_drained": metrics.batchesDrained,
                        "mutations_materialized": metrics.mutationsMaterialized,
                        "stale_batches_rejected": metrics.staleBatchesRejected,
                        "pure_removal_batches": metrics.pureRemovalBatches,
                        "bulk_removal_groups": metrics.bulkRemovalGroups,
                        "bulk_removed_children": metrics.bulkRemovedChildren,
                        "initial_components": UInt64(initialComponents),
                        "initial_subviews": UInt64(initialSubviews),
                        "updated_components": UInt64(updatedComponents),
                        "remaining_components": UInt64(remainingComponents),
                        "remaining_subviews": UInt64(remainingSubviews),
                        "queued_after_teardown":
                            UInt64(bookkeeping.queuedBatches),
                        "generations_after_teardown":
                            UInt64(bookkeeping.generations),
                        "retired_after_teardown":
                            UInt64(bookkeeping.retiredSurfaces),
                        "in_flight_after_teardown":
                            UInt64(bookkeeping.inFlightSurfaces),
                        "copied_bytes": copiedBytes,
                    ],
                    semanticChecksum: checksum,
                    phaseNanoseconds: phases.phaseNanoseconds)
            }
        })
}
