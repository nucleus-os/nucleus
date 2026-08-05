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
            let evidence = try identityBuilder.build(
                of: task,
                dependencies: dependencyIdentities,
                services: services)
            let identity = evidence.identity
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
                    resources: try normalizedResources(
                        for: task.action,
                        capacity: services.resourceCapacity),
                    claims: normalizedClaims(for: task),
                    portableSnapshot: assessment.portableSnapshot,
                    audit: evidence.audit))
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
                resources: entry.resources,
                claims: entry.claims,
                portableSnapshot: nil,
                audit: entry.audit,
                logicalOwners: entry.logicalOwners,
                attribution: entry.attribution)
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
            let dependencyIdentities = try lowered.task.dependencies.map {
                guard let identity = identities[$0] else {
                    throw TaskGraphFailure.missing(
                        task: lowered.task.id,
                        dependency: $0)
                }
                return (task: $0, identity: identity)
            }
            let evidence = try identityBuilder.build(
                of: lowered.task,
                dependencies: dependencyIdentities,
                services: services)
            let identity = evidence.identity
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
                resources: try normalizedResources(
                    for: lowered.task.action,
                    capacity: services.resourceCapacity),
                claims: normalizedClaims(for: lowered.task),
                portableSnapshot: assessment.portableSnapshot,
                audit: evidence.audit,
                logicalOwners: lowered.logicalOwners.sorted {
                    $0.rawValue < $1.rawValue
                },
                attribution: lowered.attribution)
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
            return reusableAssessment(
                of: task,
                identity: identity,
                explanation: "no prior task state",
                services: services)
        case .corrupt:
            return reusableAssessment(
                of: task,
                identity: identity,
                explanation: "prior task state is corrupt",
                services: services)
        case .record(let value):
            record = value
        }
        guard record.identity == identity else {
            return reusableAssessment(
                of: task,
                identity: identity,
                explanation:
                    "input identity changed (recorded \(record.identity), planned \(identity))",
                services: services)
        }
        do {
            try services.validateOutputs(task)
            return TaskAssessment(
                isClean: true,
                explanation: "identity and outputs are valid")
        } catch {
            return reusableAssessment(
                of: task,
                identity: identity,
                explanation: "output validation failed: \(error)",
                services: services)
        }
    }

    private func reusableAssessment(
        of task: TaskDeclaration,
        identity: ArtifactDigest,
        explanation: String,
        services: TaskPlanningServices
    ) -> TaskAssessment {
        guard task.assessmentPolicy == .portable else {
            return TaskAssessment(isClean: false, explanation: explanation)
        }
        switch services.portableSnapshotState(task.id, identity) {
        case .missing:
            return TaskAssessment(isClean: false, explanation: explanation)
        case .available:
            return TaskAssessment(
                isClean: false,
                explanation: "portable snapshot will restore invalid local output",
                portableSnapshot: .restore)
        case .corrupt:
            return TaskAssessment(
                isClean: false,
                explanation: "corrupt portable snapshot will be quarantined and rebuilt",
                portableSnapshot: .quarantine)
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

    private func normalizedResources(
        for action: AnyColliderAction?,
        capacity: TaskResourceCapacity
    ) throws -> PlannedTaskResources {
        let request = action?.requirements.resources ?? .lightweight
        let cpuCount = request.cpuCount ?? capacity.cpuCount
        let memoryBytes = request.memoryBytes ?? capacity.memoryBytes
        let ioWeight = request.ioWeight ?? capacity.ioWeight
        guard cpuCount > 0, memoryBytes > 0, ioWeight > 0,
            cpuCount <= capacity.cpuCount,
            memoryBytes <= capacity.memoryBytes,
            ioWeight <= capacity.ioWeight
        else {
            throw ColliderPlanningFailure.resourceRequestExceedsCapacity(
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                ioWeight: ioWeight,
                capacity: capacity)
        }
        return PlannedTaskResources(
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            ioWeight: ioWeight,
            exclusive: request.exclusive)
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
        for output in task.outputs {
            insert(
                PlannedTaskClaim(
                    subject: .path(output.path.lexicallyNormalized().string),
                    access: .exclusive))
        }
        for effect in task.action?.requirements.effects ?? []
        where effect.access != .read {
            switch effect.scope {
            case .checkout(let path), .output(let path), .publication(let path):
                insert(
                    PlannedTaskClaim(
                        subject: .path(path.lexicallyNormalized().string),
                        access: .exclusive))
            case .input, .scratch, .unrestricted:
                break
            }
        }
        return claims.values.sorted { $0.canonicalKey < $1.canonicalKey }
    }

    private func validateCompleteGraph(_ tasks: [TaskDeclaration]) throws {
        var owners: [(normalized: String, task: TaskID)] = []
        for task in tasks {
            for output in task.outputs {
                let normalized = output.path.lexicallyNormalized().string
                for owner in owners
                where task.id != owner.task
                    && (normalized == owner.normalized
                        || contains(normalized, in: owner.normalized)
                        || contains(owner.normalized, in: normalized))
                {
                    throw ColliderPlanningFailure.overlappingOutput(
                        first: owner.task,
                        second: task.id,
                        path: output.path)
                }
                owners.append((normalized, task.id))
            }
        }

        let outputs = tasks.flatMap { task in
            task.outputs.map {
                (
                    producer: task.id,
                    normalized: $0.path.lexicallyNormalized().string
                )
            }
        }
        for task in tasks {
            for input in task.inputs {
                guard let path = rawInputPath(input) else { continue }
                let normalized = path.lexicallyNormalized().string
                if let output = outputs.first(where: {
                    $0.producer != task.id
                        && (normalized == $0.normalized
                            || contains(normalized, in: $0.normalized))
                }) {
                    throw ColliderPlanningFailure.rawGeneratedOutputConsumption(
                        consumer: task.id,
                        producer: output.producer,
                        path: path)
                }
            }
        }

        var implementationsByKind: [ActionKind: String] = [:]
        for task in tasks {
            if task.assessmentPolicy == .portable {
                try validatePortableEligibility(task)
            }
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

    private func validatePortableEligibility(
        _ task: TaskDeclaration
    ) throws {
        guard let action = task.action else {
            throw ColliderPlanningFailure.ineligiblePortableTask(
                task: task.id,
                reason: "portable tasks require one executable action")
        }
        guard action.requirements.networkAccess != .unrestricted else {
            throw ColliderPlanningFailure.ineligiblePortableTask(
                task: task.id,
                reason: "unrestricted network access is not portable")
        }
        guard !task.outputSlots.isEmpty,
            task.outputSlots.count == task.outputs.count,
            task.outputSlots.allSatisfy({ slot in
                task.outputs.contains {
                    $0.path == slot.path && $0.validation == slot.validation
                }
            })
        else {
            throw ColliderPlanningFailure.ineligiblePortableTask(
                task: task.id,
                reason: "every output must be a typed output slot")
        }
        guard task.resultSlots.isEmpty,
            task.postconditions.isEmpty,
            task.swiftProducts.isEmpty,
            task.swiftTests.isEmpty
        else {
            throw ColliderPlanningFailure.ineligiblePortableTask(
                task: task.id,
                reason:
                    "results, shared postconditions, and SwiftPM scratch trees are not snapshots")
        }
        let paths = task.outputSlots.map { $0.path.lexicallyNormalized().string }
        for first in paths.indices {
            for second in paths.indices where first < second {
                guard paths[first] != paths[second],
                    !contains(paths[first], in: paths[second]),
                    !contains(paths[second], in: paths[first])
                else {
                    throw ColliderPlanningFailure.ineligiblePortableTask(
                        task: task.id,
                        reason: "portable output slots must not overlap")
                }
            }
        }
        for tool in action.requirements.tools {
            if tool.role == .operational {
                throw ColliderPlanningFailure.ineligiblePortableTask(
                    task: task.id,
                    reason: "operational tools require a separate portability audit")
            }
            switch tool.executable {
            case .artifact:
                break
            case .named, .operationalNamed, .path, .taskOutput:
                throw ColliderPlanningFailure.ineligiblePortableTask(
                    task: task.id,
                    reason: "ambient semantic tools are not portable")
            }
        }
        for effect in action.requirements.effects {
            switch effect.scope {
            case .unrestricted:
                throw ColliderPlanningFailure.ineligiblePortableTask(
                    task: task.id,
                    reason: "unrestricted effects are not portable")
            case .checkout where effect.access != .read:
                throw ColliderPlanningFailure.ineligiblePortableTask(
                    task: task.id,
                    reason: "mutable source checkouts are not portable")
            case .input, .checkout, .scratch, .output, .publication:
                break
            }
        }
    }

    private func rawInputPath(_ input: ArtifactInput) -> FilePath? {
        switch input {
        case .file(let path), .tree(let path), .optionalTree(let path, _):
            path
        case .tool(.taskOutput(let path)), .tool(.path(let path)):
            path
        case .tool(.artifact):
            nil
        case .value, .string, .environment, .swiftBuildContext, .tool(.named),
            .tool(.operationalNamed):
            nil
        }
    }

    private func contains(_ child: String, in parent: String) -> Bool {
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
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
    case resourceRequestExceedsCapacity(
        cpuCount: UInt32,
        memoryBytes: UInt64,
        ioWeight: UInt32,
        capacity: TaskResourceCapacity)
    case duplicateActionKind(kind: ActionKind, first: String, second: String)
    case actionNamespaceMismatch(
        task: TaskID, component: ComponentID, kind: ActionKind)
    case overlappingOutput(first: TaskID, second: TaskID, path: FilePath)
    case rawGeneratedOutputConsumption(
        consumer: TaskID, producer: TaskID, path: FilePath)
    case ineligiblePortableTask(task: TaskID, reason: String)

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
        case .resourceRequestExceedsCapacity(let cpu, let memory, let io, let capacity):
            "task resource request \(cpu) CPU/\(memory) bytes/\(io) I/O exceeds "
                + "planning capacity \(capacity.cpuCount) CPU/"
                + "\(capacity.memoryBytes) bytes/\(capacity.ioWeight) I/O"
        case .duplicateActionKind(let kind, let first, let second):
            "action kind '\(kind)' is declared by both '\(first)' and '\(second)'"
        case .actionNamespaceMismatch(let task, let component, let kind):
            "task '\(task)' owned by '\(component)' declares foreign action kind '\(kind)'"
        case .overlappingOutput(let first, let second, let path):
            "tasks '\(first)' and '\(second)' overlap output ownership at '\(path)'"
        case .rawGeneratedOutputConsumption(let consumer, let producer, let path):
            "task '\(consumer)' consumes generated output '\(path)' from '\(producer)' "
                + "through a raw path instead of its typed artifact reference"
        case .ineligiblePortableTask(let task, let reason):
            "task '\(task)' is not eligible for portable caching: \(reason)"
        }
    }
}
