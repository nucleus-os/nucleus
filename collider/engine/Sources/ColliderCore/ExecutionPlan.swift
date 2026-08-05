import SystemPackage

public struct TaskPlanEntry: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let isClean: Bool
    public let isSubsumed: Bool
    public let explanation: String
    public let coordinates: TaskExecutionCoordinates?
    public let resources: PlannedTaskResources

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        isClean: Bool,
        isSubsumed: Bool = false,
        explanation: String,
        coordinates: TaskExecutionCoordinates?,
        resources: PlannedTaskResources = .lightweight
    ) {
        self.task = task
        self.identity = identity
        self.isClean = isClean
        self.isSubsumed = isSubsumed
        self.explanation = explanation
        self.coordinates = coordinates
        self.resources = resources
    }
}

public struct TaskResourceCapacity: Codable, Hashable, Sendable {
    public let cpuCount: UInt32
    public let memoryBytes: UInt64

    public init(cpuCount: UInt32, memoryBytes: UInt64) {
        precondition(cpuCount > 0)
        precondition(memoryBytes > 0)
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
    }
}

public struct PlannedTaskResources: Codable, Hashable, Sendable {
    public let cpuCount: UInt32
    public let memoryBytes: UInt64
    public let exclusive: Bool

    public init(cpuCount: UInt32, memoryBytes: UInt64, exclusive: Bool) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.exclusive = exclusive
    }

    public static let lightweight = PlannedTaskResources(
        cpuCount: 1,
        memoryBytes: 512 * 1_024 * 1_024,
        exclusive: false)
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

    public init(isClean: Bool, explanation: String) {
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
    public let resourceCapacity: TaskResourceCapacity
    public let declaredTasks: [TaskDeclaration]
    public let declaredEntries: [TaskPlanEntry]
    public let loweredTasks: [LoweredExecutionTask]
    public let loweredEntries: [TaskPlanEntry]

    public init(
        resourceCapacity: TaskResourceCapacity,
        declaredTasks: [TaskDeclaration],
        declaredEntries: [TaskPlanEntry],
        loweredTasks: [LoweredExecutionTask],
        loweredEntries: [TaskPlanEntry]
    ) {
        precondition(declaredTasks.count == declaredEntries.count)
        precondition(loweredTasks.count == loweredEntries.count)
        self.resourceCapacity = resourceCapacity
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
    public let resourceCapacity: TaskResourceCapacity
    public let digestBytes: ([UInt8]) -> ArtifactDigest
    public let digestFile: (FilePath) throws -> ArtifactDigest
    public let digestTree: (FilePath) throws -> ArtifactDigest
    public let optionalTreeDigest: (FilePath) throws -> ArtifactDigest?
    public let semanticToolIdentity:
        (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot
    public let taskState: (TaskID) -> PlanningTaskState
    public let validateOutputs: (TaskDeclaration) throws -> Void

    public init(
        resourceCapacity: TaskResourceCapacity,
        digestBytes: @escaping ([UInt8]) -> ArtifactDigest,
        digestFile: @escaping (FilePath) throws -> ArtifactDigest,
        digestTree: @escaping (FilePath) throws -> ArtifactDigest,
        optionalTreeDigest: @escaping (FilePath) throws -> ArtifactDigest?,
        semanticToolIdentity:
            @escaping (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot,
        taskState: @escaping (TaskID) -> PlanningTaskState,
        validateOutputs: @escaping (TaskDeclaration) throws -> Void
    ) {
        self.resourceCapacity = resourceCapacity
        self.digestBytes = digestBytes
        self.digestFile = digestFile
        self.digestTree = digestTree
        self.optionalTreeDigest = optionalTreeDigest
        self.semanticToolIdentity = semanticToolIdentity
        self.taskState = taskState
        self.validateOutputs = validateOutputs
    }
}
