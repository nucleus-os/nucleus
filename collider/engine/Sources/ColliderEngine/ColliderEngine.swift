import ColliderCore
import ColliderPersistence
import ColliderPlanning
import ColliderRuntime
import Foundation
import SystemPackage

public struct ColliderEngine: Sendable {
    public let runtime: ColliderRuntime

    public init(runtime: ColliderRuntime) {
        self.runtime = runtime
    }

    public func execute(
        graph: TaskGraph,
        selected: [TaskID],
        stateRoot: FilePath,
        workflowLocks: [TaskLock] = [],
        lowerings: [any TaskPlanLowering] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        try FileManager.default.createDirectory(
            atPath: stateRoot.string,
            withIntermediateDirectories: true)
        let state = try TaskStateStore(root: stateRoot).snapshot()
        let planningInputs = PlanningInputProvider(
            digestIndex: stateRoot.appending("artifact-digests.json"))
        let outputValidator = TaskOutputValidator(
            fileSystem: runtime.actionFileSystem())
        let services = TaskPlanningServices(
            resourceCapacity: hostResourceCapacity(),
            digestBytes: planningInputs.digest(bytes:),
            digestFile: planningInputs.digest(file:),
            digestTree: planningInputs.digest(tree:),
            optionalTreeDigest: planningInputs.optionalTreeDigest,
            semanticToolIdentity: planningInputs.semanticToolIdentity,
            taskState: state.lookup,
            validateOutputs: outputValidator.validate)
        let planningStart = ContinuousClock().now
        let plan = try ColliderPlanner().plan(
            graph: graph,
            selected: selected,
            rebuildSelected: options.rebuildSelected,
            lowerings: lowerings,
            services: services)
        let planningDuration = elapsedNanoseconds(since: planningStart)
        let hashingDuration = planningInputs.hashingDurationNanoseconds
        try planningInputs.persistDigestIndex()
        return try await runtime.execute(
            plan: plan,
            stateRoot: stateRoot,
            workflowLocks: workflowLocks,
            run: run,
            registry: registry,
            options: options,
            planningDurationNanoseconds: planningDuration,
            selectedInputHashingDurationNanoseconds: hashingDuration)
    }
}

private func hostResourceCapacity() -> TaskResourceCapacity {
    let processors = UInt32(ProcessInfo.processInfo.activeProcessorCount)
    let memory = ProcessInfo.processInfo.physicalMemory
    let reservedMemory: UInt64 = 16 * 1_024 * 1_024 * 1_024
    return TaskResourceCapacity(
        cpuCount: processors > 2 ? processors - 2 : 1,
        memoryBytes: memory > reservedMemory ? memory - reservedMemory : memory)
}

private func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}
