import ColliderCore
import SystemPackage

public struct ColliderPlanner {
    public init() {}

    public func selectedTasks(
        in catalog: ComponentCatalog,
        requests: [ComponentEntrypointRequest]
    ) throws -> [TaskID] {
        try ComponentCatalogIndex(catalog).roots(for: requests)
    }

    public func plan(
        catalog: ComponentCatalog,
        requests: [ComponentEntrypointRequest],
        rebuildSelected: Bool,
        lowerings: [any TaskPlanLowering],
        services: TaskPlanningServices
    ) throws -> ExecutionPlan {
        let index = try ComponentCatalogIndex(catalog)
        return try plan(
            graph: TaskGraph(index.tasks),
            selected: index.roots(for: requests),
            rebuildSelected: rebuildSelected,
            lowerings: lowerings,
            services: services)
    }

    public func plan(
        graph: TaskGraph,
        selected: [TaskID],
        rebuildSelected: Bool,
        lowerings: [any TaskPlanLowering],
        services: TaskPlanningServices
    ) throws -> ExecutionPlan {
        try validateCompleteGraph(graph.declarations)
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
                return (task: $0, identity: identity)
            }
            let identity = try identityBuilder.build(
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
                    coordinates: try executionCoordinates(
                        for: task.action,
                        runner: services.runnerPlatform),
                    lane: task.action?.requirements.lane ?? .lightweight,
                    claims: normalizedClaims(for: task)))
        }

        let assessed = zip(ordered, entries).map {
            AssessedTaskDeclaration(
                task: $0.0,
                isClean: $0.1.isClean)
        }
        let lowered = try lowerings.flatMap { try $0.lower(assessed) }
        _ = try TaskGraph(ordered + lowered.map(\.task))
        let loweredOwners = Set(lowered.flatMap(\.logicalOwners))
        let missingLowering = assessed.compactMap { assessed -> TaskID? in
            guard !assessed.isClean,
                !assessed.task.swiftProducts.isEmpty || !assessed.task.swiftTests.isEmpty,
                !loweredOwners.contains(assessed.task.id)
            else { return nil }
            return assessed.task.id
        }.sorted { $0.rawValue < $1.rawValue }
        guard missingLowering.isEmpty else {
            throw ColliderPlanningFailure.unloweredLogicalRequirements(missingLowering)
        }

        let loweredEntries = try lowered.map { lowered in
            let dependencyIdentities = try lowered.task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(
                        task: lowered.task.id,
                        dependency: $0)
                }
                return (task: $0, identity: identity)
            }
            let identity = try identityBuilder.build(
                of: lowered.task,
                dependencies: dependencyIdentities,
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
                coordinates: try executionCoordinates(
                    for: lowered.task.action,
                    runner: services.runnerPlatform),
                lane: lowered.task.action?.requirements.lane ?? .lightweight,
                claims: normalizedClaims(for: lowered.task),
                logicalOwners: lowered.logicalOwners.sorted {
                    $0.rawValue < $1.rawValue
                },
                attribution: lowered.attribution)
        }
        return ExecutionPlan(
            declaredTasks: ordered,
            declaredEntries: entries,
            loweredTasks: lowered,
            loweredEntries: loweredEntries)
    }

    private func assessment(
        of task: TaskDeclaration,
        identity: ArtifactDigest,
        services: TaskPlanningServices
    ) -> TaskAssessment {
        if ownsHostSwiftRequirement(task) {
            return TaskAssessment(
                isClean: false,
                explanation: "SwiftPM owns host build incrementality")
        }
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
            return TaskAssessment(isClean: false, explanation: "prior task state is corrupt")
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

    private func ownsHostSwiftRequirement(_ task: TaskDeclaration) -> Bool {
        task.swiftProducts.contains {
            if case .host = $0.invocation.context.execution { return true }
            return false
        }
            || task.swiftTests.contains {
                if case .host = $0.invocation.context.execution { return true }
                return false
            }
    }

    private func executionCoordinates(
        for action: AnyColliderAction?,
        runner: RunnerPlatform
    ) throws -> TaskExecutionCoordinates? {
        guard let action else { return nil }
        let execution = action.requirements.executionPlatform
        let backend: ExecutionBackend
        switch execution.environment {
        case .native:
            guard execution.operatingSystem == runner.operatingSystem,
                execution.architecture == runner.architecture
            else {
                throw ColliderPlanningFailure.unsupportedNativeExecution(
                    execution: execution,
                    runner: runner)
            }
            if let artifact = action.requirements.artifactTarget,
                artifact.operatingSystem != runner.operatingSystem
                    || artifact.architecture != runner.architecture
            {
                throw ColliderPlanningFailure.unsupportedNativeArtifact(
                    artifact: artifact,
                    runner: runner)
            }
            backend = .native
        case .oci:
            guard execution.operatingSystem == .linux else {
                throw ColliderPlanningFailure.unsupportedExecutionPlatform(execution)
            }
            guard runner.operatingSystem == .macOS, runner.architecture == .arm64 else {
                throw ColliderPlanningFailure.unsupportedRunner(runner)
            }
            backend = .appleContainer
        }
        return TaskExecutionCoordinates(
            runner: runner,
            execution: execution,
            backend: backend,
            artifact: action.requirements.artifactTarget)
    }

    private func normalizedClaims(
        for task: TaskDeclaration
    ) -> [PlannedTaskClaim] {
        var claims: [String: PlannedTaskClaim] = [:]
        func insert(_ claim: PlannedTaskClaim) {
            let key = claim.canonicalKey
            if claims[key]?.access == .exclusive { return }
            claims[key] = claim
        }
        for lock in task.locks {
            let name =
                switch lock {
                case .checkout(let value): "checkout:\(value)"
                case .shared(let path):
                    "shared:\(path.lexicallyNormalized().string)"
                }
            insert(
                PlannedTaskClaim(
                    subject: .named(name),
                    access: .exclusive))
        }
        for effect in task.action?.requirements.effects ?? [] {
            insert(
                PlannedTaskClaim(
                    subject: .path(
                        effect.scope.root.lexicallyNormalized().string),
                    access: effect.access == .read ? .shared : .exclusive))
        }
        for effect in task.action?.requirements.persistentWorkspaceEffects ?? [] {
            insert(
                PlannedTaskClaim(
                    subject: .named(
                        "persistent-workspace:\(effect.workspace.identity.schedulingKey)"),
                    access: .exclusive))
        }
        return claims.values.sorted { $0.canonicalKey < $1.canonicalKey }
    }

    private func validateCompleteGraph(_ tasks: [TaskDeclaration]) throws {
        var outputs = GraphOutputPathIndex()
        var outputOrdinal = 0
        for task in tasks {
            for output in task.outputs {
                if let owner = outputs.insert(
                    output.path,
                    owner: task.id,
                    ordinal: outputOrdinal)
                {
                    throw ColliderPlanningFailure.overlappingOutput(
                        first: owner,
                        second: task.id,
                        path: output.path)
                }
                outputOrdinal += 1
            }
        }

        for task in tasks {
            for input in task.inputs {
                guard let path = rawInputPath(input) else { continue }
                if let producer = outputs.firstProducer(
                    containing: path,
                    excluding: task.id)
                {
                    throw ColliderPlanningFailure.rawGeneratedOutputConsumption(
                        consumer: task.id,
                        producer: producer,
                        path: path)
                }
            }
        }

        var implementationsByKind: [ActionKind: String] = [:]
        for task in tasks {
            guard let action = task.action else { continue }
            guard action.kind.rawValue.hasPrefix(task.component.rawValue + ".") else {
                throw ColliderPlanningFailure.actionNamespaceMismatch(
                    task: task.id,
                    component: task.component,
                    kind: action.kind)
            }
            if let existing = implementationsByKind[action.kind],
                existing != action.implementationType
            {
                throw ColliderPlanningFailure.duplicateActionKind(
                    kind: action.kind,
                    first: existing,
                    second: action.implementationType)
            }
            implementationsByKind[action.kind] = action.implementationType
        }
    }

    private func rawInputPath(_ input: ArtifactInput) -> FilePath? {
        switch input {
        case .file(let path), .tree(let path), .sourceCheckout(let path):
            path
        case .sourceCheckoutClosure:
            nil
        case .tool(.taskOutput(let path)), .tool(.path(let path)):
            path
        case .tool(.artifact):
            nil
        case .value, .string, .environment, .swiftBuildContext, .tool(.named),
            .tool(.operationalNamed):
            nil
        }
    }

}

public enum ColliderPlanningFailure: Error, CustomStringConvertible, Sendable {
    case unloweredLogicalRequirements([TaskID])
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedRunner(RunnerPlatform)
    case unsupportedNativeExecution(
        execution: ExecutionPlatform,
        runner: RunnerPlatform)
    case unsupportedNativeArtifact(
        artifact: ArtifactTarget,
        runner: RunnerPlatform)
    case duplicateActionKind(kind: ActionKind, first: String, second: String)
    case actionNamespaceMismatch(
        task: TaskID, component: ComponentID, kind: ActionKind)
    case overlappingOutput(first: TaskID, second: TaskID, path: FilePath)
    case rawGeneratedOutputConsumption(
        consumer: TaskID, producer: TaskID, path: FilePath)

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
        case .unsupportedNativeExecution(let execution, let runner):
            "native execution requires \(execution.operatingSystem.rawValue)/"
                + "\(execution.architecture.rawValue), but the runner is "
                + "\(runner.operatingSystem.rawValue)/\(runner.architecture.rawValue)"
        case .unsupportedNativeArtifact(let artifact, let runner):
            "native execution on \(runner.operatingSystem.rawValue)/"
                + "\(runner.architecture.rawValue) cannot produce "
                + "\(artifact.operatingSystem.rawValue)/\(artifact.architecture.rawValue)"
        case .duplicateActionKind(let kind, let first, let second):
            "action kind '\(kind)' is declared by both '\(first)' and '\(second)'"
        case .actionNamespaceMismatch(let task, let component, let kind):
            "task '\(task)' owned by '\(component)' declares foreign action kind '\(kind)'"
        case .overlappingOutput(let first, let second, let path):
            "tasks '\(first)' and '\(second)' overlap output ownership at '\(path)'"
        case .rawGeneratedOutputConsumption(let consumer, let producer, let path):
            "task '\(consumer)' consumes generated output '\(path)' from '\(producer)' "
                + "through a raw path instead of its typed artifact reference"
        }
    }
}
