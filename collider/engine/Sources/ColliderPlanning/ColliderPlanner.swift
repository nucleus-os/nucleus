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
        var identities: [TaskID: ArtifactDigest] = [:]
        var entries: [TaskPlanEntry] = []

        for task in ordered {
            let dependencyIdentities = try task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(task: task.id, dependency: $0)
                }
                return identity
            }
            let identity = try services.identity(task, dependencyIdentities)
            identities[task.id] = identity
            let assessment =
                rebuildSelected && explicitlySelected.contains(task.id)
                ? TaskAssessment(
                    isClean: false,
                    explanation: "rebuild requested for selected task")
                : services.assessment(task, identity)
            entries.append(
                TaskPlanEntry(
                    task: task.id,
                    identity: identity,
                    isClean: assessment.isClean,
                    explanation: assessment.explanation,
                    coordinates: try services.coordinates(task.action)))
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
                coordinates: entry.coordinates)
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
            let identity = try services.identity(lowered.task, [])
            let assessment = services.assessment(lowered.task, identity)
            return TaskPlanEntry(
                task: lowered.task.id,
                identity: identity,
                isClean: assessment.isClean,
                explanation: assessment.explanation,
                coordinates: try services.coordinates(lowered.task.action))
        }
        return ExecutionPlan(
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
}

public enum ColliderPlanningFailure: Error, CustomStringConvertible, Sendable {
    case unloweredLogicalRequirements([TaskID])

    public var description: String {
        switch self {
        case .unloweredLogicalRequirements(let tasks):
            "selected logical tasks have no installed lowering: "
                + tasks.map(\.rawValue).joined(separator: ", ")
        }
    }
}
