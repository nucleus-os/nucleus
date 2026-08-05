import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

public struct TaskExecutionOptions: Sendable {
    public var dryRun: Bool
    public var rebuildSelected: Bool
    public var explain: Bool
    public var verbose: Bool
    public var quiet: Bool
    public var machineReadable: Bool
    public var maximumParallelism: Int

    public init(
        dryRun: Bool = false,
        rebuildSelected: Bool = false,
        explain: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        machineReadable: Bool = false,
        maximumParallelism: Int = 2
    ) {
        self.dryRun = dryRun
        self.rebuildSelected = rebuildSelected
        self.explain = explain
        self.verbose = verbose
        self.quiet = quiet
        self.machineReadable = machineReadable
        self.maximumParallelism = max(1, maximumParallelism)
    }
}

public struct TaskExecutionReport: Codable, Sendable {
    public let plan: [TaskPlanEntry]
    public let executed: [TaskID]
    public let planningDurationNanoseconds: UInt64
    public let selectedInputHashingDurationNanoseconds: UInt64
    public let swiftPMInvocationCount: Int
    public let executionDurationNanoseconds: UInt64

    public init(
        plan: [TaskPlanEntry],
        executed: [TaskID],
        planningDurationNanoseconds: UInt64,
        selectedInputHashingDurationNanoseconds: UInt64,
        swiftPMInvocationCount: Int,
        executionDurationNanoseconds: UInt64
    ) {
        self.plan = plan
        self.executed = executed
        self.planningDurationNanoseconds = planningDurationNanoseconds
        self.selectedInputHashingDurationNanoseconds =
            selectedInputHashingDurationNanoseconds
        self.swiftPMInvocationCount = swiftPMInvocationCount
        self.executionDurationNanoseconds = executionDurationNanoseconds
    }
}

private enum ScheduledTask: Hashable, Sendable {
    case swiftBuild(Int)
    case declared(Int)
}

private struct ScheduledTaskExecution: Sendable {
    let scheduledTask: ScheduledTask
    let task: TaskDeclaration
    let plan: TaskPlanEntry
    let swiftBuildAttribution: String?
    let recordsActiveArtifact: Bool
}

private func canSchedule(
    _ candidate: ScheduledTask,
    swiftBuilds: [LoweredExecutionTask],
    swiftBuildPlans: [TaskPlanEntry],
    declaredTasks: [TaskDeclaration],
    declaredPlans: [TaskPlanEntry],
    running: [ScheduledTask: PlannedTaskResources],
    runningLocks: [ScheduledTask: Set<TaskLock>],
    capacity: TaskResourceCapacity
) -> Bool {
    let resources: PlannedTaskResources
    let locks: Set<TaskLock>
    switch candidate {
    case .swiftBuild(let index):
        resources = swiftBuildPlans[index].resources
        locks = Set(swiftBuilds[index].task.locks)
    case .declared(let index):
        let task = declaredTasks[index]
        resources = declaredPlans[index].resources
        locks = Set(task.locks)
    }

    if running.isEmpty {
        return true
    }
    guard !resources.exclusive,
        !running.values.contains(where: \.exclusive),
        runningLocks.values.allSatisfy({ $0.isDisjoint(with: locks) })
    else { return false }

    let usedCPU = running.values.reduce(UInt32(0)) { $0 + $1.cpuCount }
    let usedMemory = running.values.reduce(UInt64(0)) { $0 + $1.memoryBytes }
    return usedCPU + resources.cpuCount <= capacity.cpuCount
        && usedMemory + resources.memoryBytes <= capacity.memoryBytes
}

extension ColliderRuntime {
    public func execute(
        plan frozenPlan: ExecutionPlan,
        stateRoot: FilePath,
        workflowLocks: [TaskLock] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions(),
        planningDurationNanoseconds: UInt64,
        selectedInputHashingDurationNanoseconds: UInt64
    ) async throws -> TaskExecutionReport {
        let previousOutputPresentation = taskOutputPresentation
        taskOutputPresentation =
            options.quiet || options.machineReadable ? .quiet : .stream
        defer { taskOutputPresentation = previousOutputPresentation }

        try FileManager.default.createDirectory(
            atPath: stateRoot.string, withIntermediateDirectories: true)
        let taskStateStore = TaskStateStore(root: stateRoot)
        let eventRegistry = registry ?? logging?.registry
        let eventRun = run ?? logging?.run
        let workflowHeldLocks: [ColliderFileLock]
        if options.dryRun {
            workflowHeldLocks = []
        } else {
            workflowHeldLocks = try acquireTaskLocks(
                workflowLocks,
                stateRoot: stateRoot,
                run: eventRun,
                purpose: "workflow")
        }
        defer { withExtendedLifetime(workflowHeldLocks) {} }

        let ordered = frozenPlan.declaredTasks
        let plan = frozenPlan.declaredEntries
        let swiftBuilds = frozenPlan.loweredTasks
        let swiftBuildPlans = frozenPlan.loweredEntries
        let reportedPlan = swiftBuildPlans + plan
        let swiftPMInvocationCount = swiftBuildPlans.count
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordPlan(reportedPlan, in: eventRun)
            try await eventRegistry.recordPlanningDuration(
                planningDurationNanoseconds,
                in: eventRun)
            try await eventRegistry.recordPlanningMetrics(
                selectedInputHashingDurationNanoseconds:
                    selectedInputHashingDurationNanoseconds,
                swiftPMInvocationCount: swiftPMInvocationCount,
                in: eventRun)
        }
        if options.dryRun {
            return TaskExecutionReport(
                plan: reportedPlan,
                executed: [],
                planningDurationNanoseconds: planningDurationNanoseconds,
                selectedInputHashingDurationNanoseconds:
                    selectedInputHashingDurationNanoseconds,
                swiftPMInvocationCount: swiftPMInvocationCount,
                executionDurationNanoseconds: 0)
        }
        let executionStart = ContinuousClock().now
        if let eventRun, let eventRegistry {
            for entry in swiftBuildPlans where entry.isClean {
                try await eventRegistry.record(
                    kind: .taskSkipped,
                    task: entry.task,
                    message: entry.explanation,
                    in: eventRun)
            }
            for entry in plan where entry.isClean {
                try await eventRegistry.record(
                    kind: .taskSkipped,
                    task: entry.task,
                    message: entry.explanation,
                    in: eventRun)
            }
            for entry in plan where entry.isSubsumed {
                try await eventRegistry.record(
                    kind: .taskSkipped,
                    task: entry.task,
                    message: entry.explanation,
                    in: eventRun)
            }
        }

        let buildsByOwner = swiftBuilds.reduce(
            into: [TaskID: Set<TaskID>]()
        ) { result, build in
            for owner in build.logicalOwners {
                result[owner, default: []].insert(build.task.id)
            }
        }
        let buildPrerequisites = Dictionary(
            uniqueKeysWithValues: swiftBuilds.map {
                ($0.task.id, $0.prerequisites)
            })
        var completed = Set(plan.filter(\.isClean).map(\.task))
        completed.formUnion(swiftBuildPlans.filter(\.isClean).map(\.task))
        var pendingBuilds = swiftBuilds.indices.filter {
            !swiftBuildPlans[$0].isClean
        }
        var pendingTasks = ordered.indices.filter {
            !plan[$0].isClean && !plan[$0].isSubsumed
        }
        var executed: [TaskID] = []
        let resourceCapacity = frozenPlan.resourceCapacity
        var running: [ScheduledTask: PlannedTaskResources] = [:]
        var runningLocks: [ScheduledTask: Set<TaskLock>] = [:]

        try await withThrowingTaskGroup(of: ScheduledTask.self) { group in
            while !pendingBuilds.isEmpty || !pendingTasks.isEmpty || !running.isEmpty {
                while running.count < options.maximumParallelism {
                    let candidate =
                        pendingBuilds.compactMap { index -> ScheduledTask? in
                            buildPrerequisites[swiftBuilds[index].task.id, default: []]
                                .isSubset(of: completed)
                                ? .swiftBuild(index) : nil
                        }.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuilds: swiftBuilds,
                                swiftBuildPlans: swiftBuildPlans,
                                declaredTasks: ordered,
                                declaredPlans: plan,
                                running: running,
                                runningLocks: runningLocks,
                                capacity: resourceCapacity)
                        })
                        ?? pendingTasks.compactMap { index -> ScheduledTask? in
                            let task = ordered[index]
                            let dependenciesReady = task.executionDependencies.allSatisfy {
                                completed.contains($0)
                                    || task.subsumedDependencies.contains($0)
                            }
                            let swiftBuildsReady = buildsByOwner[
                                task.id, default: []
                            ].isSubset(of: completed)
                            return dependenciesReady && swiftBuildsReady
                                ? .declared(index) : nil
                        }.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuilds: swiftBuilds,
                                swiftBuildPlans: swiftBuildPlans,
                                declaredTasks: ordered,
                                declaredPlans: plan,
                                running: running,
                                runningLocks: runningLocks,
                                capacity: resourceCapacity)
                        })

                    guard let candidate else { break }
                    let task: TaskDeclaration
                    let resources: PlannedTaskResources
                    let execution: ScheduledTaskExecution
                    switch candidate {
                    case .swiftBuild(let index):
                        pendingBuilds.removeAll { $0 == index }
                        task = swiftBuilds[index].task
                        resources = swiftBuildPlans[index].resources
                        execution = ScheduledTaskExecution(
                            scheduledTask: candidate,
                            task: task,
                            plan: swiftBuildPlans[index],
                            swiftBuildAttribution: swiftBuilds[index].attribution,
                            recordsActiveArtifact: false)
                    case .declared(let index):
                        pendingTasks.removeAll { $0 == index }
                        task = ordered[index]
                        resources = plan[index].resources
                        execution = ScheduledTaskExecution(
                            scheduledTask: candidate,
                            task: task,
                            plan: plan[index],
                            swiftBuildAttribution: nil,
                            recordsActiveArtifact: true)
                    }
                    running[candidate] = resources
                    runningLocks[candidate] = Set(task.locks)
                    executed.append(task.id)

                    group.addTask {
                        if let attribution = execution.swiftBuildAttribution {
                            do {
                                try await self.executePlannedTask(
                                    execution.task,
                                    plan: execution.plan,
                                    stateRoot: stateRoot,
                                    stateStore: taskStateStore,
                                    eventRun: eventRun,
                                    eventRegistry: eventRegistry,
                                    options: options,
                                    recordsActiveArtifact: false)
                            } catch {
                                throw RuntimeFailure.swiftBuildFailed(
                                    attribution: attribution,
                                    reason: String(describing: error))
                            }
                        } else {
                            try await self.executePlannedTask(
                                execution.task,
                                plan: execution.plan,
                                stateRoot: stateRoot,
                                stateStore: taskStateStore,
                                eventRun: eventRun,
                                eventRegistry: eventRegistry,
                                options: options,
                                recordsActiveArtifact: execution.recordsActiveArtifact)
                        }
                        return execution.scheduledTask
                    }
                }

                guard !running.isEmpty else {
                    let blocked =
                        pendingBuilds.map {
                            swiftBuilds[$0].task.id.rawValue
                        }
                        + pendingTasks.map {
                            ordered[$0].id.rawValue
                        }
                    throw RuntimeFailure.unschedulableTaskPlan(blocked.sorted())
                }
                guard let finished = try await group.next() else {
                    preconditionFailure("task group ended with scheduled tasks still running")
                }
                running.removeValue(forKey: finished)
                runningLocks.removeValue(forKey: finished)
                switch finished {
                case .swiftBuild(let index):
                    completed.insert(swiftBuilds[index].task.id)
                case .declared(let index):
                    let task = ordered[index]
                    completed.insert(task.id)
                    completed.formUnion(task.subsumedDependencies)
                }
            }
        }

        for (index, task) in ordered.enumerated()
        where plan[index].isSubsumed {
            try TaskOutputValidator(fileSystem: actionFileSystem()).validate(task)
            try taskStateStore.persist(
                TaskStateRecord(
                    task: task.id,
                    identity: plan[index].identity,
                    outputs: task.outputs.map { $0.path.string },
                    completedAt: ISO8601DateFormatter().string(from: Date())))
        }
        let executionDuration = elapsedNanoseconds(since: executionStart)
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordExecutionDuration(
                executionDuration,
                in: eventRun)
        }
        return TaskExecutionReport(
            plan: reportedPlan,
            executed: executed,
            planningDurationNanoseconds: planningDurationNanoseconds,
            selectedInputHashingDurationNanoseconds:
                selectedInputHashingDurationNanoseconds,
            swiftPMInvocationCount: swiftPMInvocationCount,
            executionDurationNanoseconds: executionDuration)
    }

    private func executePlannedTask(
        _ task: TaskDeclaration,
        plan: TaskPlanEntry,
        stateRoot: FilePath,
        stateStore: TaskStateStore,
        eventRun: RunHandle?,
        eventRegistry: RunRegistry?,
        options: TaskExecutionOptions,
        recordsActiveArtifact: Bool
    ) async throws {
        let taskStart = ContinuousClock().now
        let heldLocks = try acquireTaskLocks(
            task.locks,
            stateRoot: stateRoot,
            run: eventRun,
            task: task.id,
            purpose: "task")
        defer { withExtendedLifetime(heldLocks) {} }
        if let eventRun, let eventRegistry {
            try await eventRegistry.record(
                kind: .taskStarted,
                task: task.id,
                in: eventRun)
        }
        do {
            try await perform(task, stage: task.id, options: options)
            try TaskOutputValidator(fileSystem: actionFileSystem()).validate(task)
            try stateStore.persist(
                TaskStateRecord(
                    task: task.id,
                    identity: plan.identity,
                    outputs: task.outputs.map { $0.path.string },
                    completedAt: ISO8601DateFormatter().string(from: Date())))
            if let eventRun, let eventRegistry {
                try await eventRegistry.recordTaskDuration(
                    elapsedNanoseconds(since: taskStart),
                    task: task.id,
                    in: eventRun)
                if recordsActiveArtifact, task.recordsActiveArtifact {
                    try await eventRegistry.recordActiveArtifact(
                        plan.identity,
                        name: task.component.rawValue,
                        in: eventRun)
                }
                try await eventRegistry.record(
                    kind: .taskSucceeded,
                    task: task.id,
                    in: eventRun)
            }
        } catch {
            if let eventRun, let eventRegistry {
                try? await eventRegistry.recordTaskDuration(
                    elapsedNanoseconds(since: taskStart),
                    task: task.id,
                    in: eventRun)
                try? await eventRegistry.record(
                    kind: .taskFailed,
                    task: task.id,
                    message: String(describing: error),
                    in: eventRun)
            }
            throw error
        }
    }

    private func perform(
        _ task: TaskDeclaration,
        stage: TaskID,
        options _: TaskExecutionOptions
    ) async throws {
        guard let action = task.action else { return }
        try await execute(action, stage: stage)
    }
}

private func rendered(_ command: CommandSpec) -> String {
    let executable =
        switch command.executable {
        case .named(let name): name
        case .operationalNamed(let name): name
        case .path(let path): path.string
        case .taskOutput(let path): path.string
        }
    return ([executable] + command.arguments).map { argument in
        if argument.isEmpty { return "''" }
        if argument.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=+".contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}

private func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}

public enum RuntimeFailure: Error, CustomStringConvertible, Sendable {
    case commandFailed(status: Int32)
    case invalidOutput(String)
    case outputLimitExceeded(Int)
    case swiftBuildFailed(attribution: String, reason: String)
    case unschedulableTaskPlan([String])

    public var description: String {
        switch self {
        case .commandFailed(let status): "child command failed with status \(status)"
        case .invalidOutput(let path): "task produced an invalid output at \(path)"
        case .outputLimitExceeded(let limit): "captured output exceeded \(limit) bytes"
        case .swiftBuildFailed(let attribution, let reason):
            "Swift package build failed for \(attribution): \(reason)"
        case .unschedulableTaskPlan(let tasks):
            "task plan has unsatisfied synthesized-build dependencies: "
                + tasks.joined(separator: ", ")
        }
    }
}

private func safeLockName(_ value: String) -> String {
    value.map {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
    }.reduce(into: "") { $0.append($1) }
}

private func acquireTaskLocks(
    _ locks: [TaskLock],
    stateRoot: FilePath,
    run: RunHandle?,
    task: TaskID? = nil,
    purpose: String
) throws -> [ColliderFileLock] {
    let locksRoot = stateRoot.removingLastComponent().appending("locks")
    return try locks.sorted(by: lockOrdering).map { lock in
        let path: FilePath
        let detail: String
        switch lock {
        case .checkout(let name):
            path = locksRoot.appending(safeLockName(name) + ".lock")
            detail = "checkout mutation \(name)"
        case .shared(let sharedPath):
            path = sharedPath
            detail = "shared mutation"
        }
        return try ColliderFileLock(
            path: path,
            purpose: "\(purpose) \(detail)",
            owner: LockOwner(
                run: run?.id.rawValue,
                task: task?.rawValue))
    }
}

private func lockOrdering(_ lhs: TaskLock, _ rhs: TaskLock) -> Bool {
    func key(_ lock: TaskLock) -> String {
        switch lock {
        case .checkout(let value): "checkout:\(value)"
        case .shared(let path): "shared:\(path.string)"
        }
    }
    return key(lhs) < key(rhs)
}
