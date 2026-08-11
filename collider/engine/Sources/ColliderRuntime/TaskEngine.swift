import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

public struct TaskExecutionOptions: Sendable {
    public var dryRun: Bool
    public var rebuildSelected: Bool
    public var verbose: Bool
    public var quiet: Bool
    public var machineReadable: Bool
    public var laneLimits: TaskLaneLimits

    public init(
        dryRun: Bool = false,
        rebuildSelected: Bool = false,
        verbose: Bool = false,
        quiet: Bool = false,
        machineReadable: Bool = false,
        laneLimits: TaskLaneLimits = TaskLaneLimits()
    ) {
        self.dryRun = dryRun
        self.rebuildSelected = rebuildSelected
        self.verbose = verbose
        self.quiet = quiet
        self.machineReadable = machineReadable
        self.laneLimits = laneLimits
    }
}

public struct TaskLaneLimits: Hashable, Sendable {
    public let lightweight: Int
    public let oci: Int

    public init(lightweight: Int = 4, oci: Int = 2) {
        precondition(lightweight > 0)
        precondition(oci > 0)
        self.lightweight = lightweight
        self.oci = oci
    }

    fileprivate func limit(for lane: TaskExecutionLane) -> Int {
        switch lane {
        case .lightweight: lightweight
        case .oci: oci
        case .hostExclusive: 1
        }
    }
}

public struct TaskExecutionReport: Codable, Sendable {
    public let plan: [TaskPlanEntry]
    public let executed: [TaskID]
    public let taskTimings: [TaskExecutionTiming]
    public let containerExecutionTimings: [TaskContainerExecutionTiming]
    public let planningDurationNanoseconds: UInt64
    public let selectedInputHashingDurationNanoseconds: UInt64
    public let swiftPMInvocationCount: Int
    public let executionDurationNanoseconds: UInt64
    public let criticalPathDurationNanoseconds: UInt64
    public let schedulingWaitDurationNanoseconds: UInt64

    public init(
        plan: [TaskPlanEntry],
        executed: [TaskID],
        taskTimings: [TaskExecutionTiming],
        containerExecutionTimings: [TaskContainerExecutionTiming],
        planningDurationNanoseconds: UInt64,
        selectedInputHashingDurationNanoseconds: UInt64,
        swiftPMInvocationCount: Int,
        executionDurationNanoseconds: UInt64,
        criticalPathDurationNanoseconds: UInt64,
        schedulingWaitDurationNanoseconds: UInt64
    ) {
        self.plan = plan
        self.executed = executed
        self.taskTimings = taskTimings
        self.containerExecutionTimings = containerExecutionTimings
        self.planningDurationNanoseconds = planningDurationNanoseconds
        self.selectedInputHashingDurationNanoseconds =
            selectedInputHashingDurationNanoseconds
        self.swiftPMInvocationCount = swiftPMInvocationCount
        self.executionDurationNanoseconds = executionDurationNanoseconds
        self.criticalPathDurationNanoseconds = criticalPathDurationNanoseconds
        self.schedulingWaitDurationNanoseconds = schedulingWaitDurationNanoseconds
    }
}

public struct TaskExecutionTiming: Codable, Sendable {
    public let task: TaskID
    public let durationNanoseconds: UInt64

    public init(task: TaskID, durationNanoseconds: UInt64) {
        self.task = task
        self.durationNanoseconds = durationNanoseconds
    }
}

public struct TaskContainerExecutionTiming: Codable, Sendable {
    public let task: TaskID
    public let executionIndex: Int
    public let timings: OCIExecutionTimings

    public init(
        task: TaskID,
        executionIndex: Int,
        timings: OCIExecutionTimings
    ) {
        self.task = task
        self.executionIndex = executionIndex
        self.timings = timings
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

private struct ScheduledTaskResult: Sendable {
    let scheduledTask: ScheduledTask
    let task: TaskID
    let durationNanoseconds: UInt64
    let observations: TaskExecutionObservations
}

private func canSchedule(
    _ candidate: ScheduledTask,
    swiftBuildPlans: [TaskPlanEntry],
    declaredPlans: [TaskPlanEntry],
    running: [ScheduledTask: TaskExecutionLane],
    runningClaims: [ScheduledTask: [PlannedTaskClaim]],
    limits: TaskLaneLimits
) -> Bool {
    let lane: TaskExecutionLane
    let claims: [PlannedTaskClaim]
    switch candidate {
    case .swiftBuild(let index):
        lane = swiftBuildPlans[index].lane
        claims = swiftBuildPlans[index].claims
    case .declared(let index):
        lane = declaredPlans[index].lane
        claims = declaredPlans[index].claims
    }

    guard runningClaims.values.allSatisfy({ !claimsConflict($0, claims) })
    else { return false }
    if lane == .hostExclusive {
        return running.isEmpty
    }
    if running.values.contains(.hostExclusive) {
        return false
    }
    return running.values.count(where: { $0 == lane }) < limits.limit(for: lane)
}

private func claimsConflict(
    _ lhs: [PlannedTaskClaim],
    _ rhs: [PlannedTaskClaim]
) -> Bool {
    for left in lhs {
        for right in rhs where left.access == .exclusive || right.access == .exclusive {
            switch (left.subject, right.subject) {
            case (.named(let leftName), .named(let rightName)):
                if leftName == rightName { return true }
            case (.path(let leftPath), .path(let rightPath)):
                if FilePath(leftPath).overlaps(FilePath(rightPath)) { return true }
            case (.named, .path), (.path, .named):
                break
            }
        }
    }
    return false
}

extension ColliderRuntime {
    public func withTaskLocks<Result: Sendable>(
        _ locks: Set<TaskLock>,
        stateRoot: FilePath,
        purpose: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let heldLocks = try await acquireTaskLocks(
            Array(locks),
            stateRoot: stateRoot,
            run: nil,
            registry: nil,
            purpose: purpose,
            cancellation: cancellation)
        defer { withExtendedLifetime(heldLocks) {} }
        return try await operation()
    }

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
            workflowHeldLocks = try await acquireTaskLocks(
                workflowLocks,
                stateRoot: stateRoot,
                run: eventRun,
                registry: eventRegistry,
                purpose: "workflow",
                cancellation: cancellation)
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
                taskTimings: [],
                containerExecutionTimings: [],
                planningDurationNanoseconds: planningDurationNanoseconds,
                selectedInputHashingDurationNanoseconds:
                    selectedInputHashingDurationNanoseconds,
                swiftPMInvocationCount: swiftPMInvocationCount,
                executionDurationNanoseconds: 0,
                criticalPathDurationNanoseconds: 0,
                schedulingWaitDurationNanoseconds: 0)
        }
        let executionStart = ContinuousClock().now
        if let eventRun, let eventRegistry {
            for entry in swiftBuildPlans where entry.isClean {
                try await eventRegistry.record(
                    .task(
                        .skipped(
                            task: entry.task,
                            explanation: entry.explanation)),
                    in: eventRun)
            }
            for entry in plan where entry.isClean {
                try await eventRegistry.record(
                    .task(
                        .skipped(
                            task: entry.task,
                            explanation: entry.explanation)),
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
        var pendingTasks = ordered.indices.filter { !plan[$0].isClean }
        var executed: [TaskID] = []
        var taskTimings: [TaskExecutionTiming] = []
        var containerExecutionTimings: [TaskContainerExecutionTiming] = []
        var running: [ScheduledTask: TaskExecutionLane] = [:]
        var runningClaims: [ScheduledTask: [PlannedTaskClaim]] = [:]
        var readySince: [ScheduledTask: ContinuousClock.Instant] = [:]
        var schedulingWaitDuration: UInt64 = 0
        var criticalPathByTask: [TaskID: UInt64] = [:]

        try await withThrowingTaskGroup(of: ScheduledTaskResult.self) { group in
            while !pendingBuilds.isEmpty || !pendingTasks.isEmpty || !running.isEmpty {
                while true {
                    let readyBuilds = pendingBuilds.compactMap {
                        index -> ScheduledTask? in
                        buildPrerequisites[swiftBuilds[index].task.id, default: []]
                            .isSubset(of: completed)
                            ? .swiftBuild(index) : nil
                    }
                    let readyDeclared = pendingTasks.compactMap {
                        index -> ScheduledTask? in
                        let task = ordered[index]
                        let dependenciesReady = task.executionDependencies.allSatisfy {
                            completed.contains($0)
                        }
                        let swiftBuildsReady = buildsByOwner[
                            task.id, default: []
                        ].isSubset(of: completed)
                        return dependenciesReady && swiftBuildsReady
                            ? .declared(index) : nil
                    }
                    for ready in readyBuilds + readyDeclared where readySince[ready] == nil {
                        readySince[ready] = ContinuousClock().now
                    }
                    let candidate =
                        readyBuilds.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuildPlans: swiftBuildPlans,
                                declaredPlans: plan,
                                running: running,
                                runningClaims: runningClaims,
                                limits: options.laneLimits)
                        })
                        ?? readyDeclared.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuildPlans: swiftBuildPlans,
                                declaredPlans: plan,
                                running: running,
                                runningClaims: runningClaims,
                                limits: options.laneLimits)
                        })

                    guard let candidate else { break }
                    let task: TaskDeclaration
                    let lane: TaskExecutionLane
                    let execution: ScheduledTaskExecution
                    switch candidate {
                    case .swiftBuild(let index):
                        pendingBuilds.removeAll { $0 == index }
                        task = swiftBuilds[index].task
                        lane = swiftBuildPlans[index].lane
                        execution = ScheduledTaskExecution(
                            scheduledTask: candidate,
                            task: task,
                            plan: swiftBuildPlans[index],
                            swiftBuildAttribution: swiftBuilds[index].attribution,
                            recordsActiveArtifact: false)
                    case .declared(let index):
                        pendingTasks.removeAll { $0 == index }
                        task = ordered[index]
                        lane = plan[index].lane
                        execution = ScheduledTaskExecution(
                            scheduledTask: candidate,
                            task: task,
                            plan: plan[index],
                            swiftBuildAttribution: nil,
                            recordsActiveArtifact: true)
                    }
                    running[candidate] = lane
                    runningClaims[candidate] = execution.plan.claims
                    if let ready = readySince.removeValue(forKey: candidate) {
                        schedulingWaitDuration &+= elapsedNanoseconds(since: ready)
                    }
                    executed.append(task.id)

                    group.addTask {
                        let taskStart = ContinuousClock().now
                        if let attribution = execution.swiftBuildAttribution {
                            do {
                                let observations = try await self.executePlannedTask(
                                    execution.task,
                                    plan: execution.plan,
                                    stateRoot: stateRoot,
                                    stateStore: taskStateStore,
                                    eventRun: eventRun,
                                    eventRegistry: eventRegistry,
                                    options: options,
                                    recordsActiveArtifact: false)
                                return ScheduledTaskResult(
                                    scheduledTask: execution.scheduledTask,
                                    task: execution.task.id,
                                    durationNanoseconds: elapsedNanoseconds(
                                        since: taskStart),
                                    observations: observations)
                            } catch {
                                if let failure = error as? ExecutionFailure {
                                    throw failure
                                }
                                throw RuntimeFailure.swiftBuildFailed(
                                    attribution: attribution,
                                    reason: String(describing: error))
                            }
                        } else {
                            let observations = try await self.executePlannedTask(
                                execution.task,
                                plan: execution.plan,
                                stateRoot: stateRoot,
                                stateStore: taskStateStore,
                                eventRun: eventRun,
                                eventRegistry: eventRegistry,
                                options: options,
                                recordsActiveArtifact: execution.recordsActiveArtifact)
                            return ScheduledTaskResult(
                                scheduledTask: execution.scheduledTask,
                                task: execution.task.id,
                                durationNanoseconds: elapsedNanoseconds(
                                    since: taskStart),
                                observations: observations)
                        }
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
                let finishedTask = finished.scheduledTask
                running.removeValue(forKey: finishedTask)
                runningClaims.removeValue(forKey: finishedTask)
                let taskID: TaskID
                let criticalDependencies: Set<TaskID>
                switch finishedTask {
                case .swiftBuild(let index):
                    taskID = swiftBuilds[index].task.id
                    criticalDependencies = buildPrerequisites[taskID, default: []]
                    completed.insert(taskID)
                case .declared(let index):
                    let task = ordered[index]
                    taskID = task.id
                    criticalDependencies = Set(task.executionDependencies).union(
                        buildsByOwner[task.id, default: []])
                    completed.insert(task.id)
                }
                let dependencyPath =
                    criticalDependencies.compactMap {
                        criticalPathByTask[$0]
                    }.max() ?? 0
                criticalPathByTask[taskID] = dependencyPath &+ finished.durationNanoseconds
                taskTimings.append(
                    TaskExecutionTiming(
                        task: taskID,
                        durationNanoseconds: finished.durationNanoseconds))
                for (index, observation) in finished.observations.containerExecutions.enumerated() {
                    guard let timings = observation.timings else { continue }
                    containerExecutionTimings.append(
                        TaskContainerExecutionTiming(
                            task: finished.task,
                            executionIndex: index,
                            timings: timings))
                }
            }
        }

        let executionDuration = elapsedNanoseconds(since: executionStart)
        let criticalPathDuration = criticalPathByTask.values.max() ?? 0
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordExecutionDuration(
                executionDuration,
                in: eventRun)
            try await eventRegistry.recordExecutionMetrics(
                criticalPathDurationNanoseconds: criticalPathDuration,
                schedulingWaitDurationNanoseconds: schedulingWaitDuration,
                in: eventRun)
        }
        return TaskExecutionReport(
            plan: reportedPlan,
            executed: executed,
            taskTimings: taskTimings,
            containerExecutionTimings: containerExecutionTimings,
            planningDurationNanoseconds: planningDurationNanoseconds,
            selectedInputHashingDurationNanoseconds:
                selectedInputHashingDurationNanoseconds,
            swiftPMInvocationCount: swiftPMInvocationCount,
            executionDurationNanoseconds: executionDuration,
            criticalPathDurationNanoseconds: criticalPathDuration,
            schedulingWaitDurationNanoseconds: schedulingWaitDuration)
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
    ) async throws -> TaskExecutionObservations {
        let taskStart = ContinuousClock().now
        let heldLocks = try await acquireTaskLocks(
            task.locks + persistentWorkspaceLocks(for: task, stateRoot: stateRoot),
            stateRoot: stateRoot,
            run: eventRun,
            registry: eventRegistry,
            task: task.id,
            purpose: "task",
            cancellation: cancellation)
        defer { withExtendedLifetime(heldLocks) {} }
        if let eventRun, let eventRegistry {
            try await eventRegistry.record(
                .task(.started(task.id)),
                in: eventRun)
        }
        do {
            let observations = try await perform(
                task,
                stage: task.id,
                options: options)
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
                try await eventRegistry.recordTaskOutcome(
                    .executed,
                    task: task.id,
                    in: eventRun)
                try await eventRegistry.recordTaskObservations(
                    observations,
                    task: task.id,
                    in: eventRun)
                if recordsActiveArtifact, task.recordsActiveArtifact {
                    try await eventRegistry.recordActiveArtifact(
                        plan.identity,
                        name: task.component.rawValue,
                        in: eventRun)
                }
                try await eventRegistry.record(
                    .task(.succeeded(task.id)),
                    in: eventRun)
            }
            return observations
        } catch {
            let logPath: String?
            if let eventRegistry, let eventRun {
                logPath = await eventRegistry.stageLogPath(
                    for: task.id,
                    in: eventRun
                ).string
            } else {
                logPath = nil
            }
            let failure =
                if let structured = error as? ExecutionFailure {
                    structured.addingContext(task: task.id, logPath: logPath)
                } else {
                    ExecutionFailure(
                        task: task.id,
                        logPath: logPath,
                        reason: String(describing: error))
                }
            if let eventRun, let eventRegistry {
                try? await eventRegistry.recordTaskDuration(
                    elapsedNanoseconds(since: taskStart),
                    task: task.id,
                    in: eventRun)
                if error is CancellationError {
                    try? await eventRegistry.record(
                        .task(.cancelled(task.id)),
                        in: eventRun)
                } else {
                    try? await eventRegistry.record(
                        .task(.failed(task: task.id, failure: failure)),
                        in: eventRun)
                }
            }
            if error is CancellationError { throw error }
            throw failure
        }
    }

    private func perform(
        _ task: TaskDeclaration,
        stage: TaskID,
        options _: TaskExecutionOptions
    ) async throws -> TaskExecutionObservations {
        guard let action = task.action else { return TaskExecutionObservations() }
        return try await execute(action, stage: stage)
    }
}

private func rendered(_ command: CommandSpec) -> String {
    let executable =
        switch command.executable {
        case .named(let name): name
        case .operationalNamed(let name): name
        case .path(let path): path.string
        case .artifact(let reference): reference.path.string
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

public enum RuntimeFailure: Error, CustomStringConvertible, Sendable {
    case invalidEnvironmentKey(String)
    case invalidEnvironmentValue(key: String)
    case invalidOutput(String)
    case outputLimitExceeded(Int)
    case swiftBuildFailed(attribution: String, reason: String)
    case unschedulableTaskPlan([String])

    public var description: String {
        switch self {
        case .invalidEnvironmentKey(let key): "invalid environment key: \(key)"
        case .invalidEnvironmentValue(let key):
            "environment value for \(key) contains a null byte"
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

private func persistentWorkspaceLocks(
    for task: TaskDeclaration,
    stateRoot: FilePath
) -> [TaskLock] {
    return (task.action?.requirements.persistentWorkspaceEffects ?? []).map { effect in
        .persistentWorkspace(effect.workspace.identity, stateRoot: stateRoot)
    }
}

extension TaskLock {
    public static func persistentWorkspace(
        _ identity: PersistentWorkspaceIdentity,
        stateRoot: FilePath
    ) -> TaskLock {
        let digest = ArtifactHasher.digest(
            bytes: Array(identity.schedulingKey.utf8))
        return .shared(
            stateRoot.removingLastComponent().appending("locks").appending(
                "persistent-workspace-\(digest.hexadecimal.prefix(24)).lock"))
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
    registry: RunRegistry?,
    task: TaskID? = nil,
    purpose: String,
    cancellation: RuntimeCancellation
) async throws -> [ColliderFileLock] {
    let locksRoot = stateRoot.removingLastComponent().appending("locks")
    var held: [ColliderFileLock] = []
    for lock in locks.sorted(by: lockOrdering) {
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
        held.append(
            try await acquireColliderFileLock(
                path: path,
                purpose: "\(purpose) \(detail)",
                resource: detail,
                run: run,
                registry: registry,
                task: task,
                cancellation: cancellation))
    }
    return held
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
