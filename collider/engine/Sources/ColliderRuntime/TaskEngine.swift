import ColliderCore
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

public struct TaskPlanEntry: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let isClean: Bool
    public let isSubsumed: Bool
    public let explanation: String
    public let coordinates: TaskExecutionCoordinates?

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        isClean: Bool,
        isSubsumed: Bool = false,
        explanation: String,
        coordinates: TaskExecutionCoordinates?
    ) {
        self.task = task
        self.identity = identity
        self.isClean = isClean
        self.isSubsumed = isSubsumed
        self.explanation = explanation
        self.coordinates = coordinates
    }
}

public struct TaskExecutionCoordinates: Codable, Hashable, Sendable {
    public let runner: RunnerPlatform
    public let execution: ExecutionPlatform
    public let backend: ExecutionBackend
    public let artifact: ArtifactTarget?

    public init(
        runner: RunnerPlatform,
        execution: ExecutionPlatform,
        backend: ExecutionBackend,
        artifact: ArtifactTarget?
    ) {
        self.runner = runner
        self.execution = execution
        self.backend = backend
        self.artifact = artifact
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

private struct SynthesizedSwiftBuild: Sendable {
    let task: TaskDeclaration
    let attribution: String
    let context: SwiftBuildContext
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

private struct ScheduledTaskResources: Sendable {
    let cpuCount: UInt32
    let memoryBytes: UInt64
    let exclusive: Bool

    static let lightweight = ScheduledTaskResources(
        cpuCount: 1,
        memoryBytes: 512 * 1_024 * 1_024,
        exclusive: false)
}

private struct TaskSchedulerBudget: Sendable {
    let cpuCount: UInt32
    let memoryBytes: UInt64

    static var host: TaskSchedulerBudget {
        let processors = UInt32(ProcessInfo.processInfo.activeProcessorCount)
        let memory = ProcessInfo.processInfo.physicalMemory
        let reservedMemory: UInt64 = 16 * 1_024 * 1_024 * 1_024
        return TaskSchedulerBudget(
            cpuCount: processors > 2 ? processors - 2 : 1,
            memoryBytes: memory > reservedMemory ? memory - reservedMemory : memory)
    }
}

private func scheduledResources(
    for operation: TaskOperation,
    budget: TaskSchedulerBudget
) -> ScheduledTaskResources {
    switch operation {
    case .runOCI(let execution):
        return ScheduledTaskResources(
            cpuCount: execution.resourceLimits.cpuCount ?? budget.cpuCount,
            memoryBytes: execution.resourceLimits.memoryBytes ?? budget.memoryBytes,
            exclusive: false)
    case .sequence(let operations):
        return operations.map {
            scheduledResources(for: $0, budget: budget)
        }.reduce(.lightweight) { accumulated, next in
            ScheduledTaskResources(
                cpuCount: max(accumulated.cpuCount, next.cpuCount),
                memoryBytes: max(accumulated.memoryBytes, next.memoryBytes),
                exclusive: accumulated.exclusive || next.exclusive)
        }
    case .buildChromiumProduct:
        return ScheduledTaskResources(
            cpuCount: budget.cpuCount,
            memoryBytes: budget.memoryBytes,
            exclusive: true)
    case .aospProduct(let stage, _):
        switch stage {
        case .compile:
            return ScheduledTaskResources(
                cpuCount: budget.cpuCount,
                memoryBytes: budget.memoryBytes,
                exclusive: true)
        case .sign, .assembleImages, .validate:
            return .lightweight
        }
    case .action(let action):
        return ScheduledTaskResources(
            cpuCount: action.requirements.resources.cpuCount ?? budget.cpuCount,
            memoryBytes: action.requirements.resources.memoryBytes ?? budget.memoryBytes,
            exclusive: action.requirements.resources.exclusive)
    case .command,
        .prepareChromiumSource, .assembleBrowserArtifact,
        .validateBrowserArtifact, .assembleCEFArtifact, .validateCEFArtifact,
        .installBrowser:
        return .lightweight
    }
}

private func scheduledResources(
    for build: SynthesizedSwiftBuild,
    budget: TaskSchedulerBudget
) -> ScheduledTaskResources {
    if containsOCIExecution(build.task.operation) {
        return scheduledResources(for: build.task.operation, budget: budget)
    }
    return ScheduledTaskResources(
        cpuCount: budget.cpuCount,
        memoryBytes: budget.memoryBytes,
        exclusive: true)
}

private func containsOCIExecution(_ operation: TaskOperation) -> Bool {
    switch operation {
    case .runOCI:
        true
    case .sequence(let operations):
        operations.contains(where: containsOCIExecution)
    case .action(let action):
        action.requirements.executionPlatform?.environment == .oci
    case .command,
        .aospProduct,
        .prepareChromiumSource, .buildChromiumProduct, .assembleBrowserArtifact,
        .validateBrowserArtifact, .assembleCEFArtifact, .validateCEFArtifact,
        .installBrowser:
        false
    }
}

private func canSchedule(
    _ candidate: ScheduledTask,
    swiftBuilds: [SynthesizedSwiftBuild],
    declaredTasks: [TaskDeclaration],
    running: [ScheduledTask: ScheduledTaskResources],
    runningLocks: [ScheduledTask: Set<TaskLock>],
    budget: TaskSchedulerBudget
) -> Bool {
    let resources: ScheduledTaskResources
    let locks: Set<TaskLock>
    switch candidate {
    case .swiftBuild(let index):
        resources = scheduledResources(for: swiftBuilds[index], budget: budget)
        locks = Set(swiftBuilds[index].task.locks)
    case .declared(let index):
        let task = declaredTasks[index]
        resources = scheduledResources(for: task.operation, budget: budget)
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
    return usedCPU + resources.cpuCount <= budget.cpuCount
        && usedMemory + resources.memoryBytes <= budget.memoryBytes
}

func requiredSwiftBuildsAreCompleted(
    for task: TaskDeclaration,
    buildsByContext: [SwiftBuildContext: Set<TaskID>],
    completed: Set<TaskID>
) -> Bool {
    let contexts =
        task.swiftProducts.map(\.invocation.context)
        + task.swiftTests.map(\.invocation.context)
    return contexts.allSatisfy { context in
        guard let builds = buildsByContext[context], !builds.isEmpty else {
            return false
        }
        return builds.isSubset(of: completed)
    }
}

extension ColliderRuntime {
    public func execute(
        graph: TaskGraph,
        selected: [TaskID],
        stateRoot: FilePath,
        workflowLocks: [TaskLock] = [],
        run: RunHandle? = nil,
        registry: RunRegistry? = nil,
        options: TaskExecutionOptions = TaskExecutionOptions()
    ) async throws -> TaskExecutionReport {
        let previousOutputPresentation = taskOutputPresentation
        taskOutputPresentation =
            options.quiet || options.machineReadable ? .quiet : .stream
        defer { taskOutputPresentation = previousOutputPresentation }

        let ordered = try graph.orderedTasks(selecting: selected)
        let explicitlySelected = Set(selected)
        try FileManager.default.createDirectory(
            atPath: stateRoot.string, withIntermediateDirectories: true)
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
        let planningStart = ContinuousClock().now
        let digestCache = PlanningArtifactDigestCache(
            persistentFile: stateRoot.appending("artifact-digests.json"))
        var identities: [TaskID: ArtifactDigest] = [:]
        var plan: [TaskPlanEntry] = []
        for task in ordered {
            let dependencyIdentities = try task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(task: task.id, dependency: $0)
                }
                return identity
            }
            let identity = try identity(
                of: task,
                dependencies: dependencyIdentities,
                digestCache: digestCache)
            identities[task.id] = identity
            let assessment =
                options.rebuildSelected && explicitlySelected.contains(task.id)
                ? (clean: false, reason: "rebuild requested for selected task")
                : assess(task, identity: identity, stateRoot: stateRoot)
            plan.append(
                TaskPlanEntry(
                    task: task.id, identity: identity,
                    isClean: assessment.clean,
                    explanation: assessment.reason,
                    coordinates: try executionCoordinates(task.operation)))
        }
        let subsumedOperations = subsumedOperations(
            in: ordered,
            plan: plan)
        plan = plan.map { entry in
            guard !entry.isClean,
                subsumedOperations.contains(entry.task)
            else { return entry }
            return TaskPlanEntry(
                task: entry.task,
                identity: entry.identity,
                isClean: false,
                isSubsumed: true,
                explanation: "operation is subsumed by a selected dirty task",
                coordinates: entry.coordinates)
        }
        let swiftBuilds = try synthesizedSwiftBuilds(
            in: ordered,
            plan: plan)
        var swiftBuildPlans: [TaskPlanEntry] = []
        for build in swiftBuilds {
            let identity = try identity(
                of: build.task,
                dependencies: [],
                digestCache: digestCache)
            let assessment = assess(
                build.task,
                identity: identity,
                stateRoot: stateRoot)
            swiftBuildPlans.append(
                TaskPlanEntry(
                    task: build.task.id,
                    identity: identity,
                    isClean: assessment.clean,
                    explanation: assessment.reason,
                    coordinates: try executionCoordinates(
                        build.task.operation)))
        }
        let reportedPlan = swiftBuildPlans + plan
        let planningDuration = elapsedNanoseconds(since: planningStart)
        let selectedInputHashingDuration = digestCache.hashingDurationNanoseconds
        let swiftPMInvocationCount = swiftBuildPlans.count
        try? digestCache.persist()
        if let eventRun, let eventRegistry {
            try await eventRegistry.recordPlan(reportedPlan, in: eventRun)
            try await eventRegistry.recordPlanningDuration(
                planningDuration,
                in: eventRun)
            try await eventRegistry.recordPlanningMetrics(
                selectedInputHashingDurationNanoseconds: selectedInputHashingDuration,
                swiftPMInvocationCount: swiftPMInvocationCount,
                in: eventRun)
        }
        if options.dryRun {
            return TaskExecutionReport(
                plan: reportedPlan,
                executed: [],
                planningDurationNanoseconds: planningDuration,
                selectedInputHashingDurationNanoseconds: selectedInputHashingDuration,
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

        let tasksByID = Dictionary(
            uniqueKeysWithValues: ordered.map {
                ($0.id, $0)
            })
        let buildsByContext = swiftBuilds.reduce(
            into: [SwiftBuildContext: Set<TaskID>]()
        ) { result, build in
            result[build.context, default: []].insert(build.task.id)
        }
        let buildPrerequisites = Dictionary(
            uniqueKeysWithValues: swiftBuilds.map {
                (
                    $0.task.id,
                    swiftBuildPrerequisites(
                        for: $0.context,
                        in: ordered,
                        plan: plan,
                        tasksByID: tasksByID)
                )
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
        let schedulerBudget = TaskSchedulerBudget.host
        var running: [ScheduledTask: ScheduledTaskResources] = [:]
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
                                declaredTasks: ordered,
                                running: running,
                                runningLocks: runningLocks,
                                budget: schedulerBudget)
                        })
                        ?? pendingTasks.compactMap { index -> ScheduledTask? in
                            let task = ordered[index]
                            let dependenciesReady = task.executionDependencies.allSatisfy {
                                completed.contains($0)
                                    || task.subsumedDependencies.contains($0)
                            }
                            let swiftBuildsReady = requiredSwiftBuildsAreCompleted(
                                for: task,
                                buildsByContext: buildsByContext,
                                completed: completed)
                            return dependenciesReady && swiftBuildsReady
                                ? .declared(index) : nil
                        }.first(where: { candidate in
                            canSchedule(
                                candidate,
                                swiftBuilds: swiftBuilds,
                                declaredTasks: ordered,
                                running: running,
                                runningLocks: runningLocks,
                                budget: schedulerBudget)
                        })

                    guard let candidate else { break }
                    let task: TaskDeclaration
                    let resources: ScheduledTaskResources
                    let execution: ScheduledTaskExecution
                    switch candidate {
                    case .swiftBuild(let index):
                        pendingBuilds.removeAll { $0 == index }
                        task = swiftBuilds[index].task
                        resources = scheduledResources(
                            for: swiftBuilds[index],
                            budget: schedulerBudget)
                        execution = ScheduledTaskExecution(
                            scheduledTask: candidate,
                            task: task,
                            plan: swiftBuildPlans[index],
                            swiftBuildAttribution: swiftBuilds[index].attribution,
                            recordsActiveArtifact: false)
                    case .declared(let index):
                        pendingTasks.removeAll { $0 == index }
                        task = ordered[index]
                        resources = scheduledResources(
                            for: task.operation,
                            budget: schedulerBudget)
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
            try validate(task)
            try persist(
                TaskStateRecord(
                    task: task.id,
                    identity: plan[index].identity,
                    outputs: task.outputs.map { $0.path.string },
                    completedAt: ISO8601DateFormatter().string(from: Date())),
                stateRoot: stateRoot)
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
            planningDurationNanoseconds: planningDuration,
            selectedInputHashingDurationNanoseconds: selectedInputHashingDuration,
            swiftPMInvocationCount: swiftPMInvocationCount,
            executionDurationNanoseconds: executionDuration)
    }

    private func swiftBuildPrerequisites(
        for context: SwiftBuildContext,
        in ordered: [TaskDeclaration],
        plan: [TaskPlanEntry],
        tasksByID: [TaskID: TaskDeclaration]
    ) -> Set<TaskID> {
        var prerequisites: Set<TaskID> = []
        for (task, entry) in zip(ordered, plan)
        where !entry.isClean && !entry.isSubsumed
            && (task.swiftProducts.contains(where: {
                $0.invocation.context == context
            })
                || task.swiftTests.contains(where: {
                    $0.invocation.context == context
                }))
        {
            for dependency in task.executionDependencies {
                collectSwiftBuildPrerequisite(
                    dependency,
                    context: context,
                    tasksByID: tasksByID,
                    into: &prerequisites)
            }
        }
        return prerequisites
    }

    private func collectSwiftBuildPrerequisite(
        _ id: TaskID,
        context: SwiftBuildContext,
        tasksByID: [TaskID: TaskDeclaration],
        into prerequisites: inout Set<TaskID>
    ) {
        guard let task = tasksByID[id] else { return }
        if task.swiftProducts.contains(where: {
            $0.invocation.context == context
        })
            || task.swiftTests.contains(where: {
                $0.invocation.context == context
            })
        {
            for dependency in task.executionDependencies {
                collectSwiftBuildPrerequisite(
                    dependency,
                    context: context,
                    tasksByID: tasksByID,
                    into: &prerequisites)
            }
        } else {
            prerequisites.insert(id)
        }
    }

    private func executePlannedTask(
        _ task: TaskDeclaration,
        plan: TaskPlanEntry,
        stateRoot: FilePath,
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
            try validate(task)
            try persist(
                TaskStateRecord(
                    task: task.id,
                    identity: plan.identity,
                    outputs: task.outputs.map { $0.path.string },
                    completedAt: ISO8601DateFormatter().string(from: Date())),
                stateRoot: stateRoot)
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

    private func synthesizedSwiftBuilds(
        in ordered: [TaskDeclaration],
        plan: [TaskPlanEntry]
    ) throws -> [SynthesizedSwiftBuild] {
        var productEntries:
            [(
                task: TaskDeclaration,
                requirement: SwiftProductRequirement
            )] = []
        var testEntries:
            [(
                task: TaskDeclaration,
                requirement: SwiftTestRequirement
            )] = []
        for (task, entry) in zip(ordered, plan)
        where !entry.isClean && !entry.isSubsumed {
            for requirement in task.swiftProducts {
                productEntries.append((task: task, requirement: requirement))
            }
            for requirement in task.swiftTests {
                testEntries.append((task: task, requirement: requirement))
            }
        }
        let contexts = Set(
            productEntries.map(\.requirement.invocation.context)
                + testEntries.map(\.requirement.invocation.context)
        )
        return try contexts.sorted {
            $0.identityBytes.lexicographicallyPrecedes($1.identityBytes)
        }.flatMap { context -> [SynthesizedSwiftBuild] in
            let tests = testEntries.filter {
                $0.requirement.invocation.context == context
            }
            let products = productEntries.filter {
                $0.requirement.invocation.context == context
            }
            guard !tests.isEmpty else {
                let task = try synthesizedSwiftBuild(products.map(\.requirement))
                return [
                    SynthesizedSwiftBuild(
                        task: task,
                        attribution: swiftAttribution(
                            products.map {
                                ($0.task, $0.requirement.qualifiedProduct)
                            }),
                        context: context)
                ]
            }

            let groupedTests = Dictionary(grouping: tests) {
                $0.requirement.arguments
            }.sorted {
                $0.key.lexicographicallyPrecedes($1.key)
            }
            let coveredOutputs = Set(tests.flatMap(\.requirement.expectedBuildOutputs))
            let coveredProducts = products.filter { entry in
                entry.requirement.expectedOutputs.allSatisfy {
                    coveredOutputs.contains($0)
                }
            }
            let uncoveredProducts = products.filter { entry in
                !coveredProducts.contains(where: {
                    $0.task.id == entry.task.id
                        && $0.requirement == entry.requirement
                })
            }
            var builds: [SynthesizedSwiftBuild] = []
            if !uncoveredProducts.isEmpty {
                builds.append(
                    SynthesizedSwiftBuild(
                        task: try synthesizedSwiftBuild(
                            uncoveredProducts.map(\.requirement)),
                        attribution: swiftAttribution(
                            uncoveredProducts.map {
                                ($0.task, $0.requirement.qualifiedProduct)
                            }),
                        context: context))
            }
            for (index, grouping) in groupedTests.enumerated() {
                let group = grouping.value
                let groupProducts = index == 0 ? coveredProducts : []
                let testTask = try synthesizedSwiftTestBuild(
                    group.map(\.requirement),
                    products: groupProducts.map(\.requirement))
                builds.append(
                    SynthesizedSwiftBuild(
                        task: testTask,
                        attribution: swiftAttribution(
                            group.map {
                                ($0.task, $0.requirement.qualifiedProduct)
                            }
                                + groupProducts.map {
                                    ($0.task, $0.requirement.qualifiedProduct)
                                }),
                        context: context))
            }
            return builds
        }
    }

    private func swiftAttribution(
        _ entries: [(task: TaskDeclaration, product: String)]
    ) -> String {
        entries.map {
            "\($0.task.component.rawValue):\($0.product)"
        }.sorted().joined(separator: ", ")
    }

    private func synthesizedSwiftBuild(
        _ requirements: [SwiftProductRequirement]
    ) throws -> TaskDeclaration {
        let first = requirements[0]
        guard
            requirements.allSatisfy({
                $0.invocation == first.invocation
                    && $0.environment == first.environment
            })
        else {
            throw RuntimeFailure.incompatibleSwiftBuildContexts
        }

        let products = Array(Set(requirements.map(\.qualifiedProduct))).sorted()
        var inputs = [first.invocation.identityInput]
        inputs += first.invocation.context.toolsets.map(ArtifactInput.file)
        if case .host = first.invocation.context.execution {
            inputs.append(ArtifactInput.tool(.named("swift")))
        }
        for requirement in requirements.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        var identity = CanonicalDigestEncoder()
        identity.append(tag: 1, bytes: first.invocation.context.identityBytes)
        for product in products {
            identity.append(tag: 2, string: product)
        }
        let prebuildTargets = Array(
            Set(requirements.flatMap(\.prebuildTargets))
        ).sorted()
        for target in prebuildTargets {
            identity.append(tag: 3, string: target)
        }
        let digest = ArtifactHasher.digest(bytes: identity.bytes)
        let buildArguments: [String]
        if requirements.count == 1 {
            buildArguments = ["build", "--product", first.product]
        } else {
            buildArguments = ["build"]
        }
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift.package.build.\(digest)"),
            component: ComponentID(rawValue: "swift-package"))
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return builder.build(
            inputs: inputs,
            postconditions: [first.invocation.postcondition]
                + requirements.flatMap(\.expectedOutputs).reduce(into: []) {
                    if !$0.contains($1) { $0.append($1) }
                },
            locks: [first.invocation.lock],
            operation: .sequence(
                prebuildTargets.map { target in
                    first.invocation.operation(
                        arguments: ["build", "--target", target],
                        workingDirectory: first.invocation.context.packageRoot,
                        environment: first.environment)
                } + [
                    first.invocation.operation(
                        arguments: buildArguments,
                        workingDirectory: first.invocation.context.packageRoot,
                        environment: first.environment)
                ]))
    }

    private func synthesizedSwiftTestBuild(
        _ requirements: [SwiftTestRequirement],
        products productRequirements: [SwiftProductRequirement]
    ) throws -> TaskDeclaration {
        let first = requirements[0]
        guard
            requirements.allSatisfy({
                $0.invocation == first.invocation
                    && $0.arguments == first.arguments
            })
                && productRequirements.allSatisfy({
                    $0.invocation == first.invocation
                })
        else {
            throw RuntimeFailure.incompatibleSwiftBuildContexts
        }
        let environments =
            requirements.map(\.environment)
            + productRequirements.map(\.environment)
        let buildEnvironment = first.environment.filter { name, value in
            environments.allSatisfy { $0[name] == value }
        }
        let tests = Array(Set(requirements.map(\.qualifiedProduct))).sorted()
        let products = Array(
            Set(productRequirements.map(\.qualifiedProduct))
        ).sorted()
        var inputs = [first.invocation.identityInput]
        inputs += first.invocation.context.toolsets.map(ArtifactInput.file)
        if case .host = first.invocation.context.execution {
            inputs.append(ArtifactInput.tool(.named("swift")))
        }
        for requirement in requirements.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        for requirement in productRequirements.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !inputs.contains(input) {
                inputs.append(input)
            }
        }
        var identity = CanonicalDigestEncoder()
        identity.append(tag: 1, bytes: first.invocation.context.identityBytes)
        for test in tests {
            identity.append(tag: 2, string: test)
        }
        for product in products {
            identity.append(tag: 3, string: product)
        }
        let prebuildTargets = Array(
            Set(productRequirements.flatMap(\.prebuildTargets))
        ).sorted()
        for target in prebuildTargets {
            identity.append(tag: 4, string: target)
        }
        let digest = ArtifactHasher.digest(bytes: identity.bytes)
        let arguments = ["test"] + first.arguments
        let expectedOutputs =
            (requirements.flatMap(\.expectedBuildOutputs)
            + productRequirements.flatMap(\.expectedOutputs)).reduce(into: [PathPostcondition]()) {
                if !$0.contains($1) { $0.append($1) }
            }
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift.package.test.\(digest)"),
            component: ComponentID(rawValue: "swift-package"))
        if case .oci(let configuration) = first.invocation.context.execution {
            builder.consume(configuration.image)
        }
        return builder.build(
            inputs: inputs,
            postconditions: [
                first.invocation.postcondition
            ]
                + expectedOutputs,
            locks: [first.invocation.lock],
            operation: .sequence(
                prebuildTargets.map { target in
                    first.invocation.operation(
                        arguments: ["build", "--target", target],
                        workingDirectory: first.invocation.context.packageRoot,
                        environment: buildEnvironment)
                } + [
                    first.invocation.operation(
                        arguments: arguments,
                        workingDirectory: first.invocation.context.packageRoot,
                        environment: buildEnvironment)
                ]))
    }

    private func subsumedOperations(
        in ordered: [TaskDeclaration],
        plan: [TaskPlanEntry]
    ) -> Set<TaskID> {
        let entries = Dictionary(uniqueKeysWithValues: plan.map { ($0.task, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var subsumed: Set<TaskID> = []
        for task in ordered where entries[task.id]?.isClean == false {
            for dependency in task.subsumedDependencies
            where entries[dependency]?.isClean == false
                && tasks[dependency].map({ canSubsume($0, with: task) }) == true
            {
                subsumed.insert(dependency)
            }
        }

        // A shared dependency remains required when any operation that will
        // actually execute consumes it without declaring that consumption to
        // be a strict superset. Iterate because restoring one candidate can
        // restore further candidates that it consumes.
        var changed = true
        while changed {
            changed = false
            for task in ordered where !subsumed.contains(task.id) {
                guard entries[task.id]?.isClean == false else { continue }
                let declared = Set(task.subsumedDependencies)
                for dependency in task.dependencies
                where subsumed.contains(dependency)
                    && !declared.contains(dependency)
                {
                    subsumed.remove(dependency)
                    changed = true
                }
            }
        }

        return subsumed
    }

    private func canSubsume(
        _ dependency: TaskDeclaration,
        with task: TaskDeclaration
    ) -> Bool {
        guard !dependency.swiftProducts.isEmpty, !task.swiftTests.isEmpty else {
            return true
        }
        let coveredOutputs = Set(task.swiftTests.flatMap(\.expectedBuildOutputs))
        return dependency.swiftProducts
            .flatMap(\.expectedOutputs)
            .allSatisfy(coveredOutputs.contains)
    }

    private func identity(
        of task: TaskDeclaration,
        dependencies: [ArtifactDigest],
        digestCache: PlanningArtifactDigestCache
    ) throws -> ArtifactDigest {
        var encoder = CanonicalDigestEncoder()
        encoder.append(tag: 1, string: task.id.rawValue)
        encoder.append(tag: 2, string: task.component.rawValue)
        for dependency in dependencies {
            encoder.append(tag: 3, bytes: dependency.bytes)
        }
        for dependency in task.subsumedDependencies {
            encoder.append(tag: 220, string: dependency.rawValue)
        }
        var artifactReferenceBytes: [UInt8] = []
        for reference in task.artifactReferences.sorted(by: {
            ($0.producer.rawValue, $0.slot.rawValue, $0.path.string)
                < ($1.producer.rawValue, $1.slot.rawValue, $1.path.string)
        }) {
            var referenceEncoder = ActionIdentityEncoder()
            referenceEncoder.append(tag: 1, string: reference.producer.rawValue)
            referenceEncoder.append(tag: 2, string: reference.slot.rawValue)
            referenceEncoder.append(tag: 3, string: reference.path.string)
            referenceEncoder.append(tag: 4, string: reference.kind.rawValue)
            let bytes = try referenceEncoder.encodedBytes()
            artifactReferenceBytes += identityLengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 245, bytes: artifactReferenceBytes)
        var resultReferenceBytes: [UInt8] = []
        for reference in task.resultReferences.sorted(by: {
            ($0.producer.rawValue, $0.slot.rawValue)
                < ($1.producer.rawValue, $1.slot.rawValue)
        }) {
            var referenceEncoder = ActionIdentityEncoder()
            referenceEncoder.append(tag: 1, string: reference.producer.rawValue)
            referenceEncoder.append(tag: 2, string: reference.slot.rawValue)
            referenceEncoder.append(tag: 3, string: reference.valueType)
            let bytes = try referenceEncoder.encodedBytes()
            resultReferenceBytes += identityLengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 246, bytes: resultReferenceBytes)
        var outputSlotBytes: [UInt8] = []
        for slot in task.outputSlots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            var slotEncoder = ActionIdentityEncoder()
            slotEncoder.append(tag: 1, string: slot.id.rawValue)
            slotEncoder.append(tag: 2, string: slot.path.string)
            slotEncoder.append(tag: 3, string: slot.validation.rawValue)
            slotEncoder.append(tag: 4, string: slot.kind.rawValue)
            let bytes = try slotEncoder.encodedBytes()
            outputSlotBytes += identityLengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 247, bytes: outputSlotBytes)
        var resultSlotBytes: [UInt8] = []
        for slot in task.resultSlots.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            var slotEncoder = ActionIdentityEncoder()
            slotEncoder.append(tag: 1, string: slot.id.rawValue)
            slotEncoder.append(tag: 2, string: slot.valueType)
            let bytes = try slotEncoder.encodedBytes()
            resultSlotBytes += identityLengthPrefix(bytes.count) + bytes
        }
        encoder.append(tag: 248, bytes: resultSlotBytes)
        for requirement in task.swiftProducts.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            encoder.append(tag: 221, string: requirement.qualifiedProduct)
            encoder.append(
                tag: 222,
                bytes: requirement.invocation.context.identityBytes)
            for target in requirement.prebuildTargets {
                encoder.append(tag: 109, string: target)
            }
            for output in requirement.expectedOutputs {
                encoder.append(tag: 223, string: output.path.string)
                encoder.append(tag: 224, string: output.validation.rawValue)
            }
        }
        for requirement in task.swiftTests.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            encoder.append(tag: 225, string: requirement.qualifiedProduct)
            encoder.append(
                tag: 226,
                bytes: requirement.invocation.context.identityBytes)
            for argument in requirement.arguments {
                encoder.append(tag: 227, string: argument)
            }
            for output in requirement.expectedBuildOutputs {
                encoder.append(tag: 107, string: output.path.string)
                encoder.append(tag: 108, string: output.validation.rawValue)
            }
        }
        var identityInputs = task.inputs
        for requirement in task.swiftProducts.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !identityInputs.contains(input) {
                identityInputs.append(input)
            }
        }
        for requirement in task.swiftTests.sorted(by: {
            $0.qualifiedProduct < $1.qualifiedProduct
        }) {
            for input in requirement.inputs where !identityInputs.contains(input) {
                identityInputs.append(input)
            }
        }
        for input in identityInputs {
            switch input {
            case .value(let name, let bytes):
                encoder.append(tag: 10, string: name)
                encoder.append(tag: 11, bytes: bytes)
            case .environment(let name, let value):
                encoder.append(tag: 12, string: name)
                encoder.append(tag: 13, string: value ?? "<unset>")
            case .file(let path):
                encoder.append(tag: 14, string: path.string)
                encoder.append(
                    tag: 15,
                    bytes: try digestCache.digest(file: path).bytes)
            case .tree(let path):
                encoder.append(tag: 16, string: path.string)
                encoder.append(
                    tag: 17,
                    bytes: try digestCache.digest(tree: path).bytes)
            case .optionalTree(let path, let fallback):
                encoder.append(tag: 72, string: path.string)
                if FileManager.default.fileExists(atPath: path.string) {
                    encoder.append(
                        tag: 73,
                        bytes: try digestCache.digest(tree: path).bytes)
                } else {
                    encoder.append(tag: 74, bytes: fallback)
                }
            case .dependencyOutput(let path):
                encoder.append(tag: 71, string: path.string)
            case .tool(let executable):
                let tool = try resolvedToolIdentity(
                    executable,
                    environment: task.swiftProducts.first?.environment
                        ?? operationEnvironment(task.operation))
                encoder.append(tag: 18, string: tool.path.string)
                encoder.append(tag: 19, bytes: tool.digest.bytes)
            }
        }
        for output in task.outputs {
            encoder.append(tag: 40, string: output.path.string)
            encoder.append(tag: 41, string: output.validation.rawValue)
        }
        for postcondition in task.postconditions {
            encoder.append(tag: 218, string: postcondition.path.string)
            encoder.append(tag: 219, string: postcondition.validation.rawValue)
        }
        try encode(operation: task.operation, into: &encoder)
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }

    private func encode(
        operation: TaskOperation,
        into encoder: inout CanonicalDigestEncoder
    ) throws {
        switch operation {
        case .action(let action):
            encoder.append(tag: 235, string: action.kind.rawValue)
            encoder.append(tag: 236, bytes: action.identity)
            for tool in action.requirements.tools.filter({
                $0.role == .semantic
            }).sorted(by: { $0.name < $1.name }) {
                let identity = try resolvedToolIdentity(
                    tool.executable,
                    environment: action.environment)
                encoder.append(tag: 239, string: tool.name)
                encoder.append(tag: 240, string: identity.path.string)
                encoder.append(tag: 241, bytes: identity.digest.bytes)
            }
            let effects = action.requirements.effects.sorted {
                let left = $0.scope.root.string + "\u{0}" + $0.access.rawValue
                let right = $1.scope.root.string + "\u{0}" + $1.access.rawValue
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
            for effect in effects {
                encoder.append(tag: 242, string: effect.access.rawValue)
                let scope: String
                switch effect.scope {
                case .input: scope = "input"
                case .checkout: scope = "checkout"
                case .scratch: scope = "scratch"
                case .output: scope = "output"
                case .publication: scope = "publication"
                case .unrestricted: scope = "unrestricted"
                }
                encoder.append(tag: 243, string: scope)
                encoder.append(tag: 244, string: effect.scope.root.string)
            }
            for (name, value) in artifactEnvironment(action.environment) {
                encoder.append(tag: 237, string: name)
                encoder.append(tag: 238, string: value)
            }
        case .command(let command):
            switch command.executable {
            case .taskOutput(let path):
                encoder.append(tag: 20, string: path.string)
                encoder.append(tag: 47, string: "task-output")
            case .operationalNamed(let name):
                encoder.append(tag: 20, string: name)
                encoder.append(tag: 47, string: "operational")
            case .named, .path:
                let tool = try resolvedToolIdentity(
                    command.executable,
                    environment: command.environment)
                encoder.append(tag: 20, string: tool.path.string)
                encoder.append(tag: 42, bytes: tool.digest.bytes)
            }
            for argument in command.arguments { encoder.append(tag: 21, string: argument) }
            encoder.append(tag: 22, string: command.workingDirectory.string)
            for (name, value) in artifactEnvironment(command.environment) {
                encoder.append(tag: 23, string: name)
                encoder.append(tag: 24, string: value)
            }
            switch command.input {
            case .none:
                encoder.append(tag: 52, string: "none")
            case .terminal:
                encoder.append(tag: 52, string: "terminal")
            case .bytes(let bytes):
                encoder.append(tag: 52, string: "bytes")
                encoder.append(tag: 53, bytes: bytes)
            }
            encoder.append(tag: 25, integer: command.timeoutNanoseconds ?? 0)
        case .runOCI(let execution):
            let executor = try OCIExecutorResolver.resolve(
                executionPlatform: execution.executionPlatform)
            encoder.append(tag: 243, string: execution.imageID.string)
            encoder.append(tag: 244, string: execution.hostname)
            encoder.append(tag: 245, string: execution.workingDirectory)
            encoder.append(tag: 246, string: execution.hostWorkingDirectory.string)
            for mount in execution.mounts {
                encoder.append(tag: 247, string: mount.source.string)
                encoder.append(tag: 248, string: mount.target)
                encoder.append(tag: 249, string: mount.access.rawValue)
            }
            for (name, value) in execution.containerEnvironment.sorted(by: {
                $0.key < $1.key
            }) {
                encoder.append(tag: 250, string: name)
                encoder.append(tag: 251, string: value)
            }
            for argument in execution.command {
                encoder.append(tag: 252, string: argument)
            }
            encode(
                runner: .current,
                execution: execution.executionPlatform,
                backend: executor.backend,
                into: &encoder)
            encoder.append(
                tag: 65,
                string: execution.artifactTarget.operatingSystem.rawValue)
            encoder.append(
                tag: 66,
                string: execution.artifactTarget.architecture.rawValue)
            encoder.append(
                tag: 67,
                string: execution.artifactTarget.abi ?? "")
            encoder.append(
                tag: 68,
                integer: UInt64(execution.artifactTarget.androidAPILevel ?? 0))
            encoder.append(tag: 69, string: execution.networkPolicy.rawValue)
            encoder.append(
                tag: 70,
                integer: UInt64(execution.userPolicy.userID))
            encoder.append(
                tag: 82,
                integer: UInt64(execution.userPolicy.groupID))
            encoder.append(tag: 83, string: execution.capabilityPolicy.rawValue)
            encoder.append(tag: 84, string: execution.privilegePolicy.rawValue)
            encoder.append(
                tag: 120,
                string: execution.processFilesystemPolicy.rawValue)
            encoder.append(
                tag: 122,
                string: execution.intelBinaryTranslationPolicy.rawValue)
            encoder.append(
                tag: 85,
                integer: UInt64(execution.resourceLimits.cpuCount ?? 0))
            encoder.append(
                tag: 86,
                integer: execution.resourceLimits.memoryBytes ?? 0)
            encoder.append(
                tag: 87,
                integer: UInt64(execution.resourceLimits.processCount))
            encoder.append(
                tag: 88,
                string: execution.temporaryDirectory?.string ?? "")
            encoder.append(
                tag: 121,
                string: ociOutputIdentity(execution.output))
            let tool = try resolvedToolIdentity(
                executor.executable,
                environment: execution.environment)
            encoder.append(tag: 253, string: tool.path.string)
            encoder.append(tag: 254, bytes: tool.digest.bytes)
        case .aospProduct(let stage, let build):
            encoder.append(tag: 196, string: stage.rawValue)
            for path in [
                build.productSource,
                build.source,
                build.repoLauncher,
                build.sourceProvenance,
                build.buildRoot,
                build.ccacheDirectory,
                build.containerImageID,
                build.signingIdentity,
            ] {
                encoder.append(tag: 197, string: path.string)
            }
            for value in [
                build.product,
                build.release,
                build.variant,
                build.buildNumber,
            ] {
                encoder.append(tag: 198, string: value)
            }
            // Build concurrency affects scheduling, not product contents.
            for value in [
                build.buildTimestamp,
                UInt64(build.expectedPlatformSDK),
                UInt64(build.expectedVendorAPILevel),
            ] {
                encoder.append(tag: 199, integer: value)
            }
            for (name, value) in artifactEnvironment(build.environment) {
                encoder.append(tag: 202, string: name)
                encoder.append(tag: 203, string: value)
            }
            switch stage {
            case .compile, .sign, .assembleImages:
                let executionPlatform = ExecutionPlatform.linuxAMD64OCI
                let executor = try OCIExecutorResolver.resolve(
                    executionPlatform: executionPlatform)
                encode(
                    runner: .current,
                    execution: executionPlatform,
                    backend: executor.backend,
                    into: &encoder)
                let tool = try resolvedToolIdentity(
                    executor.executable,
                    environment: build.environment)
                encoder.append(tag: 200, string: tool.path.string)
                encoder.append(tag: 201, bytes: tool.digest.bytes)
            case .validate:
                break
            }
        case .prepareChromiumSource(let preparation):
            for path in [
                preparation.sourceRoot,
                preparation.sourceGenerations,
                preparation.current,
                preparation.depotTools,
                preparation.sourceLockFile,
            ] {
                encoder.append(tag: 151, string: path.string)
            }
            encoder.append(tag: 152, string: preparation.sourceID)
            encoder.append(
                tag: 153,
                bytes: Array(
                    try JSONEncoder().encode(
                        preparation.sourceLock)))
            for repository in preparation.sourceLock.repositories {
                encoder.append(tag: 154, string: repository.name)
                encoder.append(tag: 154, string: repository.commit)
                encoder.append(tag: 154, string: repository.tree)
            }
            for (name, value) in artifactEnvironment(
                preparation.environment)
            {
                encoder.append(tag: 155, string: name)
                encoder.append(tag: 156, string: value)
            }
        case .buildChromiumProduct(let build):
            encoder.append(tag: 157, string: build.product.rawValue)
            for path in [
                build.sourceRoot, build.output, build.depotTools,
                build.containerImageID,
            ] {
                encoder.append(tag: 158, string: path.string)
            }
            encoder.append(tag: 159, string: build.gnArguments ?? "")
            for target in build.targets {
                encoder.append(tag: 160, string: target)
            }
            encoder.append(tag: 161, integer: UInt64(build.jobs))
            for (name, value) in artifactEnvironment(build.environment) {
                encoder.append(tag: 162, string: name)
                encoder.append(tag: 163, string: value)
            }
        case .assembleBrowserArtifact(let assembly),
            .validateBrowserArtifact(let assembly):
            for path in [
                assembly.chromiumSource,
                assembly.buildOutput,
                assembly.distributionRoot,
                assembly.launcher,
                assembly.desktopTemplate,
            ] {
                encoder.append(tag: 164, string: path.string)
            }
            for (name, value) in artifactEnvironment(
                assembly.environment)
            {
                encoder.append(tag: 165, string: name)
                encoder.append(tag: 166, string: value)
            }
            if case .assembleBrowserArtifact = operation {
                encoder.append(tag: 167, string: "assemble")
            } else {
                encoder.append(tag: 167, string: "validate")
            }
        case .assembleCEFArtifact(let assembly),
            .validateCEFArtifact(let assembly):
            for path in [
                assembly.chromiumSource,
                assembly.buildOutput,
                assembly.depotTools,
                assembly.distributionRoot,
            ] {
                encoder.append(tag: 168, string: path.string)
            }
            for value in [
                assembly.cefCheckout,
                assembly.chromiumVersion,
            ] {
                encoder.append(tag: 169, string: value)
            }
            for (name, value) in artifactEnvironment(
                assembly.environment)
            {
                encoder.append(tag: 170, string: name)
                encoder.append(tag: 171, string: value)
            }
            if case .assembleCEFArtifact = operation {
                encoder.append(tag: 172, string: "assemble")
            } else {
                encoder.append(tag: 172, string: "validate")
            }
        case .installBrowser(let installation):
            encoder.append(
                tag: 173,
                string: installation.distributionRoot.string)
            encoder.append(tag: 174, string: installation.prefix.string)
            encoder.append(
                tag: 175,
                string: installation.systemSandboxDirectory.string)
            for path in installation.widevineCandidates {
                encoder.append(tag: 176, string: path.string)
            }
            for (name, value) in artifactEnvironment(
                installation.environment)
            {
                encoder.append(tag: 177, string: name)
                encoder.append(tag: 178, string: value)
            }
        case .sequence(let operations):
            encoder.append(tag: 46, integer: UInt64(operations.count))
            for operation in operations {
                try encode(operation: operation, into: &encoder)
            }
        }
    }

    private func encode(
        runner: RunnerPlatform,
        execution: ExecutionPlatform,
        backend: ExecutionBackend,
        into encoder: inout CanonicalDigestEncoder
    ) {
        encoder.append(tag: 4, string: runner.operatingSystem.rawValue)
        encoder.append(tag: 5, string: runner.architecture.rawValue)
        encoder.append(tag: 6, string: execution.environment.rawValue)
        encoder.append(tag: 7, string: execution.operatingSystem.rawValue)
        encoder.append(tag: 8, string: execution.architecture.rawValue)
        encoder.append(tag: 9, string: backend.rawValue)
    }

    private func resolvedToolIdentity(
        _ executable: CommandSpec.Executable,
        environment: [String: String]
    ) throws -> (path: FilePath, digest: ArtifactDigest) {
        let cacheKey =
            String(describing: executable) + "\u{0}"
            + (environment["PATH"] ?? "")
        if let cached = toolIdentityCache[cacheKey] {
            return (cached.0, cached.1)
        }
        let path: FilePath
        switch executable {
        case .path(let value):
            path = value
        case .taskOutput(let value):
            throw RuntimeFailure.invalidOutput(
                "task-produced executable cannot be declared as an external tool: \(value)")
        case .operationalNamed(let name):
            throw RuntimeFailure.invalidOutput(
                "operational executable cannot be declared as a semantic tool: \(name)")
        case .named(let name):
            guard let resolved = resolveExecutable(name, path: environment["PATH"]) else {
                throw RuntimeFailure.toolNotFound(name)
            }
            path = FilePath(
                URL(fileURLWithPath: resolved.string)
                    .resolvingSymlinksInPath().path)
        }
        let digest = try ArtifactHasher.digest(file: path)
        toolIdentityCache[cacheKey] = (path, digest)
        return (path, digest)
    }

    private func assess(
        _ task: TaskDeclaration,
        identity: ArtifactDigest,
        stateRoot: FilePath
    ) -> (clean: Bool, reason: String) {
        if task.assessmentPolicy == .always {
            return (false, "task is declared to run every time")
        }
        let path = statePath(task.id, root: stateRoot)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
            let record = try? JSONDecoder().decode(TaskStateRecord.self, from: data)
        else { return (false, "no prior task state") }
        guard record.identity == identity else {
            return (
                false,
                "input identity changed (recorded \(record.identity), planned \(identity))"
            )
        }
        do {
            try validate(task)
            return (true, "identity and outputs are valid")
        } catch {
            return (false, "output validation failed: \(error)")
        }
    }

    private func perform(
        _ task: TaskDeclaration,
        stage: TaskID,
        options: TaskExecutionOptions
    ) async throws {
        try await perform(
            task.operation,
            outputs: task.outputs,
            stage: stage,
            options: options)
    }

    private func perform(
        _ operation: TaskOperation,
        outputs: [OutputDeclaration],
        stage: TaskID,
        options: TaskExecutionOptions
    ) async throws {
        switch operation {
        case .action(let action):
            try await execute(action, stage: stage)
        case .command(let command):
            if options.verbose {
                let line = rendered(command) + "\n"
                if let logging {
                    try await logging.registry.appendLog(
                        Array(line.utf8),
                        stage: stage,
                        in: logging.run)
                }
                try FileDescriptor.standardError.writeAll(Array(line.utf8))
            }
            let result = try await execute(command, stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
        case .runOCI(let execution):
            try await runOCI(execution, stage: stage)
        case .aospProduct(let operationStage, let build):
            switch operationStage {
            case .compile:
                try await compileAOSPProduct(build, stage: stage)
            case .sign:
                try await signAOSPProduct(build, stage: stage)
            case .assembleImages:
                try await assembleAOSPProductImages(build, stage: stage)
            case .validate:
                try await validateAOSPProduct(build, stage: stage)
            }
        case .prepareChromiumSource(let preparation):
            try await prepareChromiumSource(preparation, stage: stage)
        case .buildChromiumProduct(let build):
            try await buildChromiumProduct(build, stage: stage)
        case .assembleBrowserArtifact(let assembly):
            try await assembleBrowserArtifact(assembly, stage: stage)
        case .validateBrowserArtifact(let assembly):
            try await validateBrowserArtifact(assembly, stage: stage)
        case .assembleCEFArtifact(let assembly):
            try await assembleCEFArtifact(assembly, stage: stage)
        case .validateCEFArtifact(let assembly):
            try await validateCEFArtifact(assembly, stage: stage)
        case .installBrowser(let installation):
            try await installBrowser(installation, stage: stage)
        case .sequence(let operations):
            for operation in operations {
                try await perform(
                    operation,
                    outputs: outputs,
                    stage: stage,
                    options: options)
            }
        }
    }

    private func validate(
        _ paths: [(path: FilePath, validation: PathValidation)]
    ) throws {
        for path in paths {
            switch path.validation {
            case .exists:
                _ = try path.path.stat(followTargetSymlink: false)
            case .symlinkTarget:
                let metadata = try path.path.stat(followTargetSymlink: false)
                guard metadata.type == .symbolicLink else {
                    throw RuntimeFailure.invalidOutput(path.path.string)
                }
                _ = try path.path.stat(followTargetSymlink: true)
            case .regularFile, .json:
                let metadata = try path.path.stat()
                guard metadata.type == .regular else {
                    throw RuntimeFailure.invalidOutput(path.path.string)
                }
                if path.validation == .json {
                    _ = try JSONSerialization.jsonObject(
                        with: Data(contentsOf: URL(fileURLWithPath: path.path.string)))
                }
            case .executableFile:
                let metadata = try path.path.stat()
                guard metadata.type == .regular,
                    metadata.permissions.contains(.ownerExecute)
                else { throw RuntimeFailure.invalidOutput(path.path.string) }
            case .nonEmptyDirectory:
                let metadata = try path.path.stat()
                guard metadata.type == .directory,
                    !(try FileManager.default.contentsOfDirectory(
                        atPath: path.path.string)).isEmpty
                else { throw RuntimeFailure.invalidOutput(path.path.string) }
            }
        }
    }

    private func validate(_ outputs: [OutputDeclaration]) throws {
        try validate(outputs.map { ($0.path, $0.validation) })
    }

    private func validate(_ postconditions: [PathPostcondition]) throws {
        try validate(postconditions.map { ($0.path, $0.validation) })
    }

    private func validate(_ task: TaskDeclaration) throws {
        try validate(task.outputs)
        try validate(task.postconditions)
        try validate(task.swiftProducts.flatMap(\.expectedOutputs))
        try validateActionOutputs(task.operation)
    }

    private func validateActionOutputs(_ operation: TaskOperation) throws {
        switch operation {
        case .action(let action):
            try action.validateOutputs(
                using: actionFileSystem().scoped(to: action.requirements.effects))
        case .sequence(let operations):
            for operation in operations {
                try validateActionOutputs(operation)
            }
        case .command, .runOCI,
            .aospProduct, .prepareChromiumSource,
            .buildChromiumProduct, .assembleBrowserArtifact,
            .validateBrowserArtifact, .assembleCEFArtifact, .validateCEFArtifact,
            .installBrowser:
            break
        }
    }

    private func persist(_ record: TaskStateRecord, stateRoot: FilePath) throws {
        let path = statePath(record.task, root: stateRoot)
        try DurableFile.writeJSON(record, to: path)
    }
}

private func artifactEnvironment(
    _ environment: [String: String]
) -> [(key: String, value: String)] {
    let volatile = Set([
        "NUCLEUS_RUN_DIR",
        "NUCLEUS_RUN_LOG",
        "TERM",
        // A task identity records the resolved path and content digest of every
        // tool it declares, so the search path used to find them adds nothing.
        // It does vary: the workspace Node.js activation puts a per-invocation
        // directory on PATH, which would leave every task permanently dirty.
        "PATH",
    ])
    return
        environment
        .filter { !volatile.contains($0.key) }
        .sorted { $0.key < $1.key }
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

final class PlanningArtifactDigestCache {
    private struct FileSignature: Codable, Equatable {
        let device: String
        let inode: String
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        init(_ metadata: Stat) {
            device = String(describing: metadata.deviceID.rawValue)
            inode = String(describing: metadata.inode.rawValue)
            size = metadata.size
            modificationSeconds = Int64(metadata.st_mtim.tv_sec)
            modificationNanoseconds = Int64(metadata.st_mtim.tv_nsec)
            statusChangeSeconds = Int64(metadata.st_ctim.tv_sec)
            statusChangeNanoseconds = Int64(metadata.st_ctim.tv_nsec)
        }
    }

    private struct FileEntry: Codable {
        let signature: FileSignature
        let digest: ArtifactDigest
    }

    private struct TreeKey: Hashable {
        let root: FilePath
        let excludedRelativePaths: [String]
    }

    private let persistentFile: FilePath?
    private var files: [String: FileEntry]
    private var trees: [TreeKey: ArtifactDigest] = [:]
    private var persistentStateChanged = false
    private var measurementDepth = 0
    private(set) var fileMissCount = 0
    private(set) var treeMissCount = 0
    private(set) var hashingDurationNanoseconds: UInt64 = 0

    init(persistentFile: FilePath? = nil) {
        self.persistentFile = persistentFile
        guard let persistentFile,
            let data = try? Data(
                contentsOf: URL(
                    fileURLWithPath: persistentFile.string)),
            let decoded = try? JSONDecoder().decode(
                [String: FileEntry].self,
                from: data)
        else {
            files = [:]
            return
        }
        files = decoded
    }

    func digest(
        file path: FilePath,
        metadata suppliedMetadata: Stat? = nil
    ) throws -> ArtifactDigest {
        try measured {
            try digestFile(path, metadata: suppliedMetadata)
        }
    }

    private func digestFile(
        _ path: FilePath,
        metadata suppliedMetadata: Stat?
    ) throws -> ArtifactDigest {
        let metadata =
            try suppliedMetadata
            ?? path.stat(followTargetSymlink: true)
        let signature = FileSignature(metadata)
        if let entry = files[path.string],
            entry.signature == signature
        {
            return entry.digest
        }
        let digest = try ArtifactHasher.digest(file: path)
        files[path.string] = FileEntry(
            signature: signature,
            digest: digest)
        persistentStateChanged = true
        fileMissCount += 1
        return digest
    }

    func digest(
        tree root: FilePath,
        excluding excludedRelativePaths: Set<String> = []
    ) throws -> ArtifactDigest {
        try measured {
            try digestTree(root, excluding: excludedRelativePaths)
        }
    }

    private func digestTree(
        _ root: FilePath,
        excluding excludedRelativePaths: Set<String>
    ) throws -> ArtifactDigest {
        let key = TreeKey(
            root: root,
            excludedRelativePaths: excludedRelativePaths.sorted())
        if let digest = trees[key] {
            return digest
        }
        let digest = try ArtifactHasher.digest(
            tree: root,
            excluding: excludedRelativePaths,
            digestFile: { try self.digest(file: $0, metadata: $1) })
        trees[key] = digest
        treeMissCount += 1
        return digest
    }

    private func measured<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let recordsDuration = measurementDepth == 0
        let start = recordsDuration ? ContinuousClock().now : nil
        measurementDepth += 1
        defer {
            measurementDepth -= 1
            if let start {
                hashingDurationNanoseconds &+= elapsedNanoseconds(since: start)
            }
        }
        return try operation()
    }

    func persist() throws {
        guard persistentStateChanged, let persistentFile else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(files)
        try data.write(
            to: URL(fileURLWithPath: persistentFile.string),
            options: .atomic)
        persistentStateChanged = false
    }
}

private func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}

private func identityLengthPrefix(_ count: Int) -> [UInt8] {
    let value = UInt64(count)
    return (0..<8).reversed().map { shift in
        UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
    }
}

public enum RuntimeFailure: Error, CustomStringConvertible, Sendable {
    case commandFailed(status: Int32)
    case invalidOutput(String)
    case toolNotFound(String)
    case outputLimitExceeded(Int)
    case incompatibleSwiftBuildContexts
    case swiftBuildFailed(attribution: String, reason: String)
    case unschedulableTaskPlan([String])

    public var description: String {
        switch self {
        case .commandFailed(let status): "child command failed with status \(status)"
        case .invalidOutput(let path): "task produced an invalid output at \(path)"
        case .toolNotFound(let name): "declared task tool '\(name)' was not found"
        case .outputLimitExceeded(let limit): "captured output exceeded \(limit) bytes"
        case .incompatibleSwiftBuildContexts:
            "selected tasks require incompatible Swift build contexts"
        case .swiftBuildFailed(let attribution, let reason):
            "Swift package build failed for \(attribution): \(reason)"
        case .unschedulableTaskPlan(let tasks):
            "task plan has unsatisfied synthesized-build dependencies: "
                + tasks.joined(separator: ", ")
        }
    }
}

private func operationEnvironment(_ operation: TaskOperation) -> [String: String] {
    switch operation {
    case .action(let action):
        action.environment
    case .command(let command):
        command.environment
    case .runOCI(let execution):
        execution.environment
    case .aospProduct(_, let build):
        build.environment
    case .prepareChromiumSource(let preparation):
        preparation.environment
    case .buildChromiumProduct(let build):
        build.environment
    case .assembleBrowserArtifact(let assembly),
        .validateBrowserArtifact(let assembly):
        assembly.environment
    case .assembleCEFArtifact(let assembly),
        .validateCEFArtifact(let assembly):
        assembly.environment
    case .installBrowser(let installation):
        installation.environment
    case .sequence(let operations):
        operations.lazy.map(operationEnvironment).first(where: { !$0.isEmpty }) ?? [:]
    }
}

private func executionCoordinates(
    _ operation: TaskOperation
) throws -> TaskExecutionCoordinates? {
    let runner = RunnerPlatform.current
    switch operation {
    case .action(let action):
        guard let executionPlatform = action.requirements.executionPlatform else {
            return nil
        }
        let executor = try OCIExecutorResolver.resolve(
            runner: runner,
            executionPlatform: executionPlatform)
        return TaskExecutionCoordinates(
            runner: runner,
            execution: executionPlatform,
            backend: executor.backend,
            artifact: action.requirements.artifactTarget)
    case .runOCI(let execution):
        let executor = try OCIExecutorResolver.resolve(
            runner: runner,
            executionPlatform: execution.executionPlatform)
        return TaskExecutionCoordinates(
            runner: runner,
            execution: execution.executionPlatform,
            backend: executor.backend,
            artifact: execution.artifactTarget)
    case .aospProduct(let stage, let build):
        switch stage {
        case .compile, .sign, .assembleImages:
            let platform = ExecutionPlatform.linuxAMD64OCI
            let executor = try OCIExecutorResolver.resolve(
                runner: runner,
                executionPlatform: platform)
            return TaskExecutionCoordinates(
                runner: runner,
                execution: platform,
                backend: executor.backend,
                artifact: .androidX86_64(apiLevel: build.expectedPlatformSDK))
        case .validate:
            return nil
        }
    case .sequence(let operations):
        let coordinates = try operations.compactMap {
            try executionCoordinates($0)
        }
        guard let first = coordinates.first else { return nil }
        guard coordinates.dropFirst().allSatisfy({ $0 == first }) else {
            throw RuntimeFailure.invalidOutput(
                "one task sequence cannot cross execution coordinates")
        }
        return first
    case .command,
        .prepareChromiumSource, .buildChromiumProduct,
        .assembleBrowserArtifact, .validateBrowserArtifact,
        .assembleCEFArtifact, .validateCEFArtifact, .installBrowser:
        return nil
    }
}

private func ociOutputIdentity(_ output: CommandSpec.Output) -> String {
    switch output {
    case .inherited:
        "inherited"
    case .logged:
        "logged"
    case .terminal:
        "terminal"
    case .file(let path):
        "file:\(path)"
    case .captured(let limit):
        "captured:\(limit)"
    case .combined(let limit):
        "combined:\(limit)"
    }
}

private func resolveExecutable(_ name: String, path: String?) -> FilePath? {
    guard let path else { return nil }
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let candidate = FilePath(String(directory)).appending(name)
        if FileManager.default.isExecutableFile(atPath: candidate.string) {
            return candidate
        }
    }
    return nil
}

private func statePath(_ task: TaskID, root: FilePath) -> FilePath {
    root.appending(
        task.rawValue.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        }.reduce(into: "") { $0.append($1) } + ".json")
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
