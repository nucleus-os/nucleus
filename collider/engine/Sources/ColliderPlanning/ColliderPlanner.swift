import ColliderCore

public struct ColliderPlanner {
    public init() {}

    public func plan(
        graph: TaskGraph,
        selected: [TaskID],
        rebuildSelected: Bool,
        lowerings: [any TaskPlanLowering],
        services: TaskPlanningServices
    ) throws -> ExecutionPlan {
        let ordered = try graph.orderedTasks(selecting: selected)
        let explicitlySelected = Set(selected)
        let identityBuilder = TaskIdentityBuilder()
        var identities: [TaskID: ArtifactDigest] = [:]
        var entries: [TaskPlanEntry] = []

        for task in ordered {
            let dependencyIdentities = try task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(task: task.id, dependency: $0)
                }
                return identity
            }
            let identity = try identityBuilder.identity(
                of: task,
                dependencies: dependencyIdentities,
                services: services)
            identities[task.id] = identity
            let assessment =
                rebuildSelected && explicitlySelected.contains(task.id)
                ? TaskAssessment(
                    isClean: false,
                    explanation: "rebuild requested for selected task")
                : assessment(of: task, identity: identity, services: services)
            entries.append(
                TaskPlanEntry(
                    task: task.id,
                    identity: identity,
                    isClean: assessment.isClean,
                    explanation: assessment.explanation,
                    coordinates: try executionCoordinates(for: task.action),
                    resources: try normalizedResources(
                        for: task.action,
                        capacity: services.resourceCapacity)))
        }

        let subsumed = subsumedTasks(in: ordered, entries: entries)
        entries = entries.map { entry in
            guard !entry.isClean, subsumed.contains(entry.task) else {
                return entry
            }
            return TaskPlanEntry(
                task: entry.task,
                identity: entry.identity,
                isClean: false,
                isSubsumed: true,
                explanation: "action is subsumed by a selected dirty task",
                coordinates: entry.coordinates,
                resources: entry.resources)
        }

        let assessed = zip(ordered, entries).map {
            AssessedTaskDeclaration(
                task: $0.0,
                isClean: $0.1.isClean,
                isSubsumed: $0.1.isSubsumed)
        }
        let lowered = try lowerings.flatMap { try $0.lower(assessed) }
        _ = try TaskGraph(ordered + lowered.map(\.task))
        let loweredOwners = Set(lowered.flatMap(\.logicalOwners))
        let missingLowering = assessed.compactMap { assessed -> TaskID? in
            guard !assessed.isClean, !assessed.isSubsumed,
                !assessed.task.swiftProducts.isEmpty || !assessed.task.swiftTests.isEmpty,
                !loweredOwners.contains(assessed.task.id)
            else { return nil }
            return assessed.task.id
        }.sorted { $0.rawValue < $1.rawValue }
        guard missingLowering.isEmpty else {
            throw ColliderPlanningFailure.unloweredLogicalRequirements(missingLowering)
        }

        let loweredEntries = try lowered.map { lowered in
            let identity = try identityBuilder.identity(
                of: lowered.task,
                dependencies: [],
                services: services)
            let assessment = assessment(
                of: lowered.task,
                identity: identity,
                services: services)
            return TaskPlanEntry(
                task: lowered.task.id,
                identity: identity,
                isClean: assessment.isClean,
                explanation: assessment.explanation,
                coordinates: try executionCoordinates(for: lowered.task.action),
                resources: try normalizedResources(
                    for: lowered.task.action,
                    capacity: services.resourceCapacity))
        }
        return ExecutionPlan(
            resourceCapacity: services.resourceCapacity,
            declaredTasks: ordered,
            declaredEntries: entries,
            loweredTasks: lowered,
            loweredEntries: loweredEntries)
    }

    private func subsumedTasks(
        in ordered: [TaskDeclaration],
        entries: [TaskPlanEntry]
    ) -> Set<TaskID> {
        let entriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.task, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var subsumed: Set<TaskID> = []
        for task in ordered where entriesByID[task.id]?.isClean == false {
            for dependency in task.subsumedDependencies
            where entriesByID[dependency]?.isClean == false
                && tasks[dependency].map({ canSubsume($0, with: task) }) == true
            {
                subsumed.insert(dependency)
            }
        }

        var changed = true
        while changed {
            changed = false
            for task in ordered where !subsumed.contains(task.id) {
                guard entriesByID[task.id]?.isClean == false else { continue }
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

    private func assessment(
        of task: TaskDeclaration,
        identity: ArtifactDigest,
        services: TaskPlanningServices
    ) -> TaskAssessment {
        if task.assessmentPolicy == .always {
            return TaskAssessment(
                isClean: false,
                explanation: "task is declared to run every time")
        }
        let record: TaskStateRecord
        switch services.taskState(task.id) {
        case .missing:
            return TaskAssessment(isClean: false, explanation: "no prior task state")
        case .corrupt:
            return TaskAssessment(
                isClean: false,
                explanation: "prior task state is corrupt")
        case .record(let value):
            record = value
        }
        guard record.identity == identity else {
            return TaskAssessment(
                isClean: false,
                explanation:
                    "input identity changed (recorded \(record.identity), planned \(identity))")
        }
        do {
            try services.validateOutputs(task)
            return TaskAssessment(
                isClean: true,
                explanation: "identity and outputs are valid")
        } catch {
            return TaskAssessment(
                isClean: false,
                explanation: "output validation failed: \(error)")
        }
    }

    private func executionCoordinates(
        for action: AnyColliderAction?
    ) throws -> TaskExecutionCoordinates? {
        guard let action,
            let execution = action.requirements.executionPlatform
        else { return nil }
        guard execution.environment == .oci,
            execution.operatingSystem == .linux
        else {
            throw ColliderPlanningFailure.unsupportedExecutionPlatform(execution)
        }
        let runner = RunnerPlatform.current
        guard runner.operatingSystem == .macOS, runner.architecture == .arm64 else {
            throw ColliderPlanningFailure.unsupportedRunner(runner)
        }
        return TaskExecutionCoordinates(
            runner: runner,
            execution: execution,
            backend: .appleContainer,
            artifact: action.requirements.artifactTarget)
    }

    private func normalizedResources(
        for action: AnyColliderAction?,
        capacity: TaskResourceCapacity
    ) throws -> PlannedTaskResources {
        let request = action?.requirements.resources ?? .lightweight
        let cpuCount = request.cpuCount ?? capacity.cpuCount
        let memoryBytes = request.memoryBytes ?? capacity.memoryBytes
        guard cpuCount > 0, memoryBytes > 0,
            cpuCount <= capacity.cpuCount,
            memoryBytes <= capacity.memoryBytes
        else {
            throw ColliderPlanningFailure.resourceRequestExceedsCapacity(
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                capacity: capacity)
        }
        return PlannedTaskResources(
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            exclusive: request.exclusive)
    }
}

public enum ColliderPlanningFailure: Error, CustomStringConvertible, Sendable {
    case unloweredLogicalRequirements([TaskID])
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedRunner(RunnerPlatform)
    case resourceRequestExceedsCapacity(
        cpuCount: UInt32,
        memoryBytes: UInt64,
        capacity: TaskResourceCapacity)

    public var description: String {
        switch self {
        case .unloweredLogicalRequirements(let tasks):
            "selected logical tasks have no installed lowering: "
                + tasks.map(\.rawValue).joined(separator: ", ")
        case .unsupportedExecutionPlatform(let platform):
            "unsupported execution platform: \(platform.environment.rawValue)/"
                + "\(platform.operatingSystem.rawValue)/\(platform.architecture.rawValue)"
        case .unsupportedRunner(let runner):
            "unsupported execution runner: \(runner.operatingSystem.rawValue)/"
                + runner.architecture.rawValue
        case .resourceRequestExceedsCapacity(let cpu, let memory, let capacity):
            "task resource request \(cpu) CPU/\(memory) bytes exceeds planning capacity "
                + "\(capacity.cpuCount) CPU/\(capacity.memoryBytes) bytes"
        }
    }
}
