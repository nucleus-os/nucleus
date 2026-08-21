import SystemPackage

public struct TaskDurationWorkload: Codable, Hashable, Sendable {
    public let task: TaskID
    public let lane: TaskExecutionLane
    public let coordinates: TaskExecutionCoordinates?
    public let mode: String?

    public init(
        task: TaskID,
        lane: TaskExecutionLane,
        coordinates: TaskExecutionCoordinates?,
        mode: String?
    ) {
        self.task = task
        self.lane = lane
        self.coordinates = coordinates
        self.mode = mode
    }
}

public struct TaskDurationEstimate: Codable, Hashable, Sendable {
    public let workload: TaskDurationWorkload
    public let durationNanoseconds: UInt64

    public init(
        workload: TaskDurationWorkload,
        durationNanoseconds: UInt64
    ) {
        precondition(durationNanoseconds > 0)
        self.workload = workload
        self.durationNanoseconds = durationNanoseconds
    }
}

public struct TaskPlanEntry: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let isClean: Bool
    public let explanation: String
    public let coordinates: TaskExecutionCoordinates?
    public let lane: TaskExecutionLane
    public let claims: [PlannedTaskClaim]
    public let logicalOwners: [TaskID]
    public let attribution: String?
    public let durationWorkload: TaskDurationWorkload?
    public let durationEstimate: TaskDurationEstimate?

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        isClean: Bool,
        explanation: String,
        coordinates: TaskExecutionCoordinates?,
        lane: TaskExecutionLane = .lightweight,
        claims: [PlannedTaskClaim] = [],
        logicalOwners: [TaskID] = [],
        attribution: String? = nil,
        durationWorkload: TaskDurationWorkload? = nil,
        durationEstimate: TaskDurationEstimate? = nil
    ) {
        self.task = task
        self.identity = identity
        self.isClean = isClean
        self.explanation = explanation
        self.coordinates = coordinates
        self.lane = lane
        self.claims = claims
        self.logicalOwners = logicalOwners
        self.attribution = attribution
        self.durationWorkload = durationWorkload
        self.durationEstimate = durationEstimate
    }
}

public enum TaskExecutionLane: String, Codable, Hashable, Sendable {
    case lightweight
    case oci
    case hostExclusive
}

public enum PlannedTaskClaimAccess: String, Codable, Hashable, Sendable {
    case shared
    case exclusive
}

public enum PlannedTaskClaimSubject: Codable, Hashable, Sendable {
    case named(String)
    case path(String)
}

public struct PlannedTaskClaim: Codable, Hashable, Sendable {
    public let subject: PlannedTaskClaimSubject
    public let access: PlannedTaskClaimAccess

    public init(
        subject: PlannedTaskClaimSubject,
        access: PlannedTaskClaimAccess
    ) {
        self.subject = subject
        self.access = access
    }

    public var canonicalKey: String {
        switch subject {
        case .named(let value): "named:\(value)"
        case .path(let value): "path:\(value)"
        }
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

public struct TaskAssessment: Sendable {
    public let isClean: Bool
    public let explanation: String

    public init(
        isClean: Bool,
        explanation: String
    ) {
        self.isClean = isClean
        self.explanation = explanation
    }
}

public enum PlanningTaskState: Sendable {
    case missing
    case corrupt
    case record(TaskStateRecord)
}

public struct ExecutionPlan: Sendable {
    public let declaredTasks: [TaskDeclaration]
    public let declaredEntries: [TaskPlanEntry]
    public let loweredTasks: [LoweredExecutionTask]
    public let loweredEntries: [TaskPlanEntry]

    public init(
        declaredTasks: [TaskDeclaration],
        declaredEntries: [TaskPlanEntry],
        loweredTasks: [LoweredExecutionTask],
        loweredEntries: [TaskPlanEntry]
    ) {
        precondition(declaredTasks.count == declaredEntries.count)
        precondition(loweredTasks.count == loweredEntries.count)
        self.declaredTasks = declaredTasks
        self.declaredEntries = declaredEntries
        self.loweredTasks = loweredTasks
        self.loweredEntries = loweredEntries
    }

    public var reportedEntries: [TaskPlanEntry] {
        loweredEntries + declaredEntries
    }
}

public struct ToolIdentitySnapshot: Sendable {
    public let path: FilePath
    public let digest: ArtifactDigest

    public init(path: FilePath, digest: ArtifactDigest) {
        self.path = path
        self.digest = digest
    }
}

public struct TaskPlanningServices {
    public let runnerPlatform: RunnerPlatform
    public let identityPathMap: IdentityPathMap
    public let digestBytes: ([UInt8]) -> ArtifactDigest
    public let digestFile: (FilePath) throws -> ArtifactDigest
    public let digestTree: (FilePath) throws -> ArtifactDigest
    public let digestSourceCheckout: (FilePath) throws -> ArtifactDigest
    public let digestSourceCheckoutClosure: ([FilePath]) throws -> ArtifactDigest
    public let semanticToolIdentity:
        (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot
    public let taskState: (TaskID) -> PlanningTaskState
    public let durationEstimate: (TaskDurationWorkload) -> UInt64?
    public let validateOutputs: (TaskDeclaration) throws -> Void
    /// Receives each task's encoded identity components as planning computes
    /// them. Identity is a digest, so two plans that disagree otherwise report
    /// only that they disagree; this is how an inspection reads back what went
    /// into one. It observes and must not influence what is encoded.
    public let observeIdentity: ((TaskID, [UInt8]) -> Void)?

    public init(
        runnerPlatform: RunnerPlatform = .current,
        identityPathMap: IdentityPathMap = .empty,
        digestBytes: @escaping ([UInt8]) -> ArtifactDigest,
        digestFile: @escaping (FilePath) throws -> ArtifactDigest,
        digestTree: @escaping (FilePath) throws -> ArtifactDigest,
        digestSourceCheckout: @escaping (FilePath) throws -> ArtifactDigest,
        digestSourceCheckoutClosure:
            (([FilePath]) throws -> ArtifactDigest)? = nil,
        semanticToolIdentity:
            @escaping (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot,
        taskState: @escaping (TaskID) -> PlanningTaskState,
        durationEstimate: @escaping (TaskDurationWorkload) -> UInt64? = { _ in nil },
        validateOutputs: @escaping (TaskDeclaration) throws -> Void,
        observeIdentity: ((TaskID, [UInt8]) -> Void)? = nil
    ) {
        self.runnerPlatform = runnerPlatform
        self.identityPathMap = identityPathMap
        self.observeIdentity = observeIdentity
        self.digestBytes = digestBytes
        self.digestFile = digestFile
        self.digestTree = digestTree
        self.digestSourceCheckout = digestSourceCheckout
        self.digestSourceCheckoutClosure =
            digestSourceCheckoutClosure ?? { paths in
                var encoder = IdentityEncoder()
                try encoder.appendSequence(paths.sorted { $0.string < $1.string }) {
                    entry, path in
                    entry.append(path: path)
                    entry.append(bytes: try digestSourceCheckout(path).bytes)
                }
                return digestBytes(encoder.bytes)
            }
        self.semanticToolIdentity = semanticToolIdentity
        self.taskState = taskState
        self.durationEstimate = durationEstimate
        self.validateOutputs = validateOutputs
    }
}
