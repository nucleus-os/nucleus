import ColliderCore
import ColliderPlanning
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
    for action: AnyColliderAction?,
    budget: TaskSchedulerBudget
) -> ScheduledTaskResources {
    guard let action else { return .lightweight }
    return ScheduledTaskResources(
        cpuCount: action.requirements.resources.cpuCount ?? budget.cpuCount,
        memoryBytes: action.requirements.resources.memoryBytes ?? budget.memoryBytes,
        exclusive: action.requirements.resources.exclusive)
}

private func scheduledResources(
    for build: LoweredExecutionTask,
    budget: TaskSchedulerBudget
) -> ScheduledTaskResources {
    scheduledResources(for: build.task.action, budget: budget)
}

private func canSchedule(
    _ candidate: ScheduledTask,
    swiftBuilds: [LoweredExecutionTask],
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
        resources = scheduledResources(for: task.action, budget: budget)
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

extension ColliderRuntime {
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
        let previousOutputPresentation = taskOutputPresentation
        taskOutputPresentation =
            options.quiet || options.machineReadable ? .quiet : .stream
        defer { taskOutputPresentation = previousOutputPresentation }

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
        let planningServices = TaskPlanningServices(
            identity: { task, dependencies in
                try self.identity(
                    of: task,
                    dependencies: dependencies,
                    digestCache: digestCache)
            },
            assessment: { task, identity in
                let assessment = self.assess(
                    task,
                    identity: identity,
                    stateRoot: stateRoot)
                return TaskAssessment(
                    isClean: assessment.clean,
                    explanation: assessment.reason)
            },
            coordinates: executionCoordinates)
        let frozenPlan = try ColliderPlanner().plan(
            graph: graph,
            selected: selected,
            rebuildSelected: options.rebuildSelected,
            lowerings: lowerings,
            services: planningServices)
        let ordered = frozenPlan.declaredTasks
        let plan = frozenPlan.declaredEntries
        let swiftBuilds = frozenPlan.loweredTasks
        let swiftBuildPlans = frozenPlan.loweredEntries
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
                            let swiftBuildsReady = buildsByOwner[
                                task.id, default: []
                            ].isSubset(of: completed)
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
                            for: task.action,
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
                        ?? actionEnvironment(task.action))
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
        try encode(action: task.action, into: &encoder)
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }
    private func encode(
        action: AnyColliderAction?,
        into encoder: inout CanonicalDigestEncoder
    ) throws {
        guard let action else {
            encoder.append(tag: 235, string: "no-action")
            return
        }
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
        options _: TaskExecutionOptions
    ) async throws {
        guard let action = task.action else { return }
        try await execute(action, stage: stage)
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
        try validateActionOutput(task.action)
    }

    private func validateActionOutput(_ action: AnyColliderAction?) throws {
        guard let action else { return }
        try action.validateOutputs(
            using: actionFileSystem().scoped(to: action.requirements.effects))
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

/// Mutable only during one synchronous planning call. The closures handed to
/// `ColliderPlanning` do not escape or invoke concurrently.
final class PlanningArtifactDigestCache: @unchecked Sendable {
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
    case swiftBuildFailed(attribution: String, reason: String)
    case unschedulableTaskPlan([String])

    public var description: String {
        switch self {
        case .commandFailed(let status): "child command failed with status \(status)"
        case .invalidOutput(let path): "task produced an invalid output at \(path)"
        case .toolNotFound(let name): "declared task tool '\(name)' was not found"
        case .outputLimitExceeded(let limit): "captured output exceeded \(limit) bytes"
        case .swiftBuildFailed(let attribution, let reason):
            "Swift package build failed for \(attribution): \(reason)"
        case .unschedulableTaskPlan(let tasks):
            "task plan has unsatisfied synthesized-build dependencies: "
                + tasks.joined(separator: ", ")
        }
    }
}

private func actionEnvironment(_ action: AnyColliderAction?) -> [String: String] {
    action?.environment ?? [:]
}

private func executionCoordinates(
    _ action: AnyColliderAction?
) throws -> TaskExecutionCoordinates? {
    guard let action,
        let executionPlatform = action.requirements.executionPlatform
    else { return nil }
    let runner = RunnerPlatform.current
    let executor = try OCIExecutorResolver.resolve(
        runner: runner,
        executionPlatform: executionPlatform)
    return TaskExecutionCoordinates(
        runner: runner,
        execution: executionPlatform,
        backend: executor.backend,
        artifact: action.requirements.artifactTarget)
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
