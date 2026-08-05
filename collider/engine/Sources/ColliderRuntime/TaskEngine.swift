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
    public let restored: [TaskID]
    public let planningDurationNanoseconds: UInt64
    public let selectedInputHashingDurationNanoseconds: UInt64
    public let swiftPMInvocationCount: Int
    public let executionDurationNanoseconds: UInt64
    public let criticalPathDurationNanoseconds: UInt64
    public let resourceWaitDurationNanoseconds: UInt64

    public init(
        plan: [TaskPlanEntry],
        executed: [TaskID],
        restored: [TaskID] = [],
        planningDurationNanoseconds: UInt64,
        selectedInputHashingDurationNanoseconds: UInt64,
        swiftPMInvocationCount: Int,
        executionDurationNanoseconds: UInt64,
        criticalPathDurationNanoseconds: UInt64,
        resourceWaitDurationNanoseconds: UInt64
    ) {
        self.plan = plan
        self.executed = executed
        self.restored = restored
        self.planningDurationNanoseconds = planningDurationNanoseconds
        self.selectedInputHashingDurationNanoseconds =
            selectedInputHashingDurationNanoseconds
        self.swiftPMInvocationCount = swiftPMInvocationCount
        self.executionDurationNanoseconds = executionDurationNanoseconds
        self.criticalPathDurationNanoseconds = criticalPathDurationNanoseconds
        self.resourceWaitDurationNanoseconds = resourceWaitDurationNanoseconds
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
    let durationNanoseconds: UInt64
    let outcome: TaskExecutionOutcome
}

private enum TaskExecutionOutcome: Equatable, Sendable {
    case executed
    case restored
}

private func canSchedule(
    _ candidate: ScheduledTask,
    swiftBuildPlans: [TaskPlanEntry],
    declaredPlans: [TaskPlanEntry],
    running: [ScheduledTask: PlannedTaskResources],
    runningClaims: [ScheduledTask: [PlannedTaskClaim]],
    capacity: TaskResourceCapacity
) -> Bool {
    let resources: PlannedTaskResources
    let claims: [PlannedTaskClaim]
    switch candidate {
    case .swiftBuild(let index):
        resources = swiftBuildPlans[index].resources
        claims = swiftBuildPlans[index].claims
    case .declared(let index):
        resources = declaredPlans[index].resources
        claims = declaredPlans[index].claims
    }

    if running.isEmpty {
        return true
    }
    guard !resources.exclusive,
        !running.values.contains(where: \.exclusive),
        runningClaims.values.allSatisfy({ !claimsConflict($0, claims) })
    else { return false }

    let usedCPU = running.values.reduce(UInt32(0)) { $0 + $1.cpuCount }
    let usedMemory = running.values.reduce(UInt64(0)) { $0 + $1.memoryBytes }
    let usedIO = running.values.reduce(UInt32(0)) { $0 + $1.ioWeight }
    return usedCPU + resources.cpuCount <= capacity.cpuCount
        && usedMemory + resources.memoryBytes <= capacity.memoryBytes
        && usedIO + resources.ioWeight <= capacity.ioWeight
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
                if pathsOverlap(leftPath, rightPath) { return true }
            case (.named, .path), (.path, .named):
                break
            }
        }
    }
    return false
}

private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.hasPrefix(rhs.hasSuffix("/") ? rhs : rhs + "/")
        || rhs.hasPrefix(lhs.hasSuffix("/") ? lhs : lhs + "/")
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
            workflowHeldLocks = try await acquireTaskLocks(
                workflowLocks,
                stateRoot: stateRoot,
                run: eventRun,
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
                restored: [],
                planningDurationNanoseconds: planningDurationNanoseconds,
                selectedInputHashingDurationNanoseconds:
                    selectedInputHashingDurationNanoseconds,
                swiftPMInvocationCount: swiftPMInvocationCount,
                executionDurationNanoseconds: 0,
                criticalPathDurationNanoseconds: 0,
                resourceWaitDurationNanoseconds: 0)
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
        var restored: [TaskID] = []
        let resourceCapacity = frozenPlan.resourceCapacity
        var running: [ScheduledTask: PlannedTaskResources] = [:]
        var runningClaims: [ScheduledTask: [PlannedTaskClaim]] = [:]
        var readySince: [ScheduledTask: ContinuousClock.Instant] = [:]
        var resourceWaitDuration: UInt64 = 0
        var criticalPathByTask: [TaskID: UInt64] = [:]

        try await withThrowingTaskGroup(of: ScheduledTaskResult.self) { group in
            while !pendingBuilds.isEmpty || !pendingTasks.isEmpty || !running.isEmpty {
                while running.count < options.maximumParallelism {
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
                                || task.subsumedDependencies.contains($0)
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
                                capacity: resourceCapacity)
                        })
                        ?? readyDeclared.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuildPlans: swiftBuildPlans,
                                declaredPlans: plan,
                                running: running,
                                runningClaims: runningClaims,
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
                    runningClaims[candidate] = execution.plan.claims
                    if let ready = readySince.removeValue(forKey: candidate) {
                        resourceWaitDuration &+= elapsedNanoseconds(since: ready)
                    }
                    executed.append(task.id)

                    group.addTask {
                        let taskStart = ContinuousClock().now
                        if let attribution = execution.swiftBuildAttribution {
                            do {
                                let outcome = try await self.executePlannedTask(
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
                                    durationNanoseconds: elapsedNanoseconds(
                                        since: taskStart),
                                    outcome: outcome)
                            } catch {
                                throw RuntimeFailure.swiftBuildFailed(
                                    attribution: attribution,
                                    reason: String(describing: error))
                            }
                        } else {
                            let outcome = try await self.executePlannedTask(
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
                                durationNanoseconds: elapsedNanoseconds(
                                    since: taskStart),
                                outcome: outcome)
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
                    completed.formUnion(task.subsumedDependencies)
                }
                if finished.outcome == .restored {
                    executed.removeAll { $0 == taskID }
                    restored.append(taskID)
                }
                let dependencyPath =
                    criticalDependencies.compactMap {
                        criticalPathByTask[$0]
                    }.max() ?? 0
                criticalPathByTask[taskID] = dependencyPath &+ finished.durationNanoseconds
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
        let criticalPathDuration = criticalPathByTask.values.max() ?? 0
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordExecutionDuration(
                executionDuration,
                in: eventRun)
            try await eventRegistry.recordExecutionMetrics(
                criticalPathDurationNanoseconds: criticalPathDuration,
                resourceWaitDurationNanoseconds: resourceWaitDuration,
                in: eventRun)
        }
        return TaskExecutionReport(
            plan: reportedPlan,
            executed: executed,
            restored: restored,
            planningDurationNanoseconds: planningDurationNanoseconds,
            selectedInputHashingDurationNanoseconds:
                selectedInputHashingDurationNanoseconds,
            swiftPMInvocationCount: swiftPMInvocationCount,
            executionDurationNanoseconds: executionDuration,
            criticalPathDurationNanoseconds: criticalPathDuration,
            resourceWaitDurationNanoseconds: resourceWaitDuration)
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
    ) async throws -> TaskExecutionOutcome {
        let taskStart = ContinuousClock().now
        let heldLocks = try await acquireTaskLocks(
            task.locks,
            stateRoot: stateRoot,
            run: eventRun,
            task: task.id,
            purpose: "task",
            cancellation: cancellation)
        defer { withExtendedLifetime(heldLocks) {} }
        if let eventRun, let eventRegistry {
            try await eventRegistry.record(
                kind: .taskStarted,
                task: task.id,
                in: eventRun)
        }
        let portableArtifacts = PortableArtifactStore(
            root: stateRoot.appending("portable-artifacts"))
        do {
            if plan.portableSnapshot == .quarantine {
                try portableArtifacts.quarantine(identity: plan.identity)
            } else if plan.portableSnapshot == .restore {
                do {
                    try portableArtifacts.restore(
                        task: task,
                        identity: plan.identity)
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
                        try await eventRegistry.record(
                            kind: .taskRestored,
                            task: task.id,
                            in: eventRun)
                    }
                    return .restored
                } catch let failure as PortableArtifactStoreFailure
                    where failure.isSnapshotCorruption
                {
                    try portableArtifacts.quarantine(identity: plan.identity)
                }
            }
            try await perform(task, stage: task.id, options: options)
            try TaskOutputValidator(fileSystem: actionFileSystem()).validate(task)
            if task.assessmentPolicy == .portable {
                try portableArtifacts.capture(
                    task: task,
                    identity: plan.identity)
            }
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
            return .executed
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
        while true {
            try Task.checkCancellation()
            if await cancellation.wasInterrupted() { throw CancellationError() }
            do {
                held.append(
                    try ColliderFileLock(
                        path: path,
                        purpose: "\(purpose) \(detail)",
                        waitForExistingOwner: false,
                        owner: LockOwner(
                            run: run?.id.rawValue,
                            task: task?.rawValue)))
                break
            } catch RuntimeLockFailure.alreadyOwned {
                try await ContinuousClock().sleep(for: .milliseconds(100))
            }
        }
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
