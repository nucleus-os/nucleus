import SystemPackage

public struct TaskPlanEntry: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let isClean: Bool
    public let isSubsumed: Bool
    public let explanation: String
    public let coordinates: TaskExecutionCoordinates?
    public let resources: PlannedTaskResources
    public let claims: [PlannedTaskClaim]
    public let artifactSnapshot: PlannedArtifactSnapshot?
    public let audit: PlannedTaskAudit
    public let logicalOwners: [TaskID]
    public let attribution: String?

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        isClean: Bool,
        isSubsumed: Bool = false,
        explanation: String,
        coordinates: TaskExecutionCoordinates?,
        resources: PlannedTaskResources = .lightweight,
        claims: [PlannedTaskClaim] = [],
        artifactSnapshot: PlannedArtifactSnapshot? = nil,
        audit: PlannedTaskAudit,
        logicalOwners: [TaskID] = [],
        attribution: String? = nil
    ) {
        self.task = task
        self.identity = identity
        self.isClean = isClean
        self.isSubsumed = isSubsumed
        self.explanation = explanation
        self.coordinates = coordinates
        self.resources = resources
        self.claims = claims
        self.artifactSnapshot = artifactSnapshot
        self.audit = audit
        self.logicalOwners = logicalOwners
        self.attribution = attribution
    }
}

public struct PlannedTaskAudit: Codable, Sendable {
    public let component: ComponentID
    public let actionKind: String?
    public let actionIdentity: ArtifactDigest?
    public let semanticDependencies: [String: ArtifactDigest]
    public let orderingDependencies: [String]
    public let artifactReferences: [PlannedArtifactReferenceAudit]
    public let resultReferences: [PlannedResultReferenceAudit]
    public let inputs: [PlannedInputAudit]
    public let semanticTools: [PlannedToolAudit]
    public let operationalTools: [PlannedToolAudit]
    public let swiftBuildContexts: [PlannedSwiftBuildContextAudit]
    public let outputs: [PlannedOutputAudit]
    public let postconditions: [PlannedOutputAudit]
    public let effects: [PlannedEffectAudit]
    public let networkAccess: String
    public let assessmentPolicy: String

    public init(
        component: ComponentID,
        actionKind: String?,
        actionIdentity: ArtifactDigest?,
        semanticDependencies: [String: ArtifactDigest],
        orderingDependencies: [String],
        artifactReferences: [PlannedArtifactReferenceAudit],
        resultReferences: [PlannedResultReferenceAudit],
        inputs: [PlannedInputAudit],
        semanticTools: [PlannedToolAudit],
        operationalTools: [PlannedToolAudit],
        swiftBuildContexts: [PlannedSwiftBuildContextAudit],
        outputs: [PlannedOutputAudit],
        postconditions: [PlannedOutputAudit],
        effects: [PlannedEffectAudit],
        networkAccess: String,
        assessmentPolicy: String
    ) {
        self.component = component
        self.actionKind = actionKind
        self.actionIdentity = actionIdentity
        self.semanticDependencies = semanticDependencies
        self.orderingDependencies = orderingDependencies
        self.artifactReferences = artifactReferences
        self.resultReferences = resultReferences
        self.inputs = inputs
        self.semanticTools = semanticTools
        self.operationalTools = operationalTools
        self.swiftBuildContexts = swiftBuildContexts
        self.outputs = outputs
        self.postconditions = postconditions
        self.effects = effects
        self.networkAccess = networkAccess
        self.assessmentPolicy = assessmentPolicy
    }
}

public struct PlannedArtifactReferenceAudit: Codable, Sendable {
    public let producer: TaskID
    public let slot: OutputSlotID
    public let kind: ArtifactValueKind
    public let path: String

    public init(
        producer: TaskID,
        slot: OutputSlotID,
        kind: ArtifactValueKind,
        path: String
    ) {
        self.producer = producer
        self.slot = slot
        self.kind = kind
        self.path = path
    }
}

public struct PlannedResultReferenceAudit: Codable, Sendable {
    public let producer: TaskID
    public let slot: OutputSlotID
    public let valueType: String

    public init(producer: TaskID, slot: OutputSlotID, valueType: String) {
        self.producer = producer
        self.slot = slot
        self.valueType = valueType
    }
}

public struct PlannedInputAudit: Codable, Sendable {
    public let kind: String
    public let name: String?
    public let path: String?
    public let digest: ArtifactDigest

    public init(
        kind: String,
        name: String? = nil,
        path: String? = nil,
        digest: ArtifactDigest
    ) {
        self.kind = kind
        self.name = name
        self.path = path
        self.digest = digest
    }
}

public struct PlannedToolAudit: Codable, Sendable {
    public let name: String
    public let executable: String
    public let path: String?
    public let digest: ArtifactDigest?
    public let producer: TaskID?
    public let slot: OutputSlotID?

    public init(
        name: String,
        executable: String,
        path: String? = nil,
        digest: ArtifactDigest? = nil,
        producer: TaskID? = nil,
        slot: OutputSlotID? = nil
    ) {
        self.name = name
        self.executable = executable
        self.path = path
        self.digest = digest
        self.producer = producer
        self.slot = slot
    }
}

public struct PlannedSwiftBuildContextAudit: Codable, Sendable {
    public let role: String
    public let product: String
    public let identity: ArtifactDigest

    public init(role: String, product: String, identity: ArtifactDigest) {
        self.role = role
        self.product = product
        self.identity = identity
    }
}

public struct PlannedOutputAudit: Codable, Sendable {
    public let slot: OutputSlotID?
    public let kind: ArtifactValueKind?
    public let path: String
    public let validation: PathValidation

    public init(
        slot: OutputSlotID? = nil,
        kind: ArtifactValueKind? = nil,
        path: String,
        validation: PathValidation
    ) {
        self.slot = slot
        self.kind = kind
        self.path = path
        self.validation = validation
    }
}

public struct PlannedEffectAudit: Codable, Sendable {
    public let access: String
    public let scope: String
    public let root: String

    public init(access: String, scope: String, root: String) {
        self.access = access
        self.scope = scope
        self.root = root
    }
}

public enum ArtifactSnapshotState: Sendable {
    case missing
    case available
    case corrupt
}

public enum PlannedArtifactSnapshot: String, Codable, Hashable, Sendable {
    case restore
    case quarantine
}

public struct TaskResourceCapacity: Codable, Hashable, Sendable {
    public let cpuCount: UInt32
    public let memoryBytes: UInt64
    public let ioWeight: UInt32

    public init(
        cpuCount: UInt32,
        memoryBytes: UInt64,
        ioWeight: UInt32 = 4
    ) {
        precondition(cpuCount > 0)
        precondition(memoryBytes > 0)
        precondition(ioWeight > 0)
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.ioWeight = ioWeight
    }
}

public struct PlannedTaskResources: Codable, Hashable, Sendable {
    public let cpuCount: UInt32
    public let memoryBytes: UInt64
    public let ioWeight: UInt32
    public let exclusive: Bool

    public init(
        cpuCount: UInt32,
        memoryBytes: UInt64,
        ioWeight: UInt32 = 1,
        exclusive: Bool
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.ioWeight = ioWeight
        self.exclusive = exclusive
    }

    public static let lightweight = PlannedTaskResources(
        cpuCount: 1,
        memoryBytes: 512 * 1_024 * 1_024,
        ioWeight: 1,
        exclusive: false)
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
    public let artifactSnapshot: PlannedArtifactSnapshot?

    public init(
        isClean: Bool,
        explanation: String,
        artifactSnapshot: PlannedArtifactSnapshot? = nil
    ) {
        self.isClean = isClean
        self.explanation = explanation
        self.artifactSnapshot = artifactSnapshot
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
    public let runnerPlatform: RunnerPlatform
    public let identityPathMap: IdentityPathMap
    public let digestBytes: ([UInt8]) -> ArtifactDigest
    public let digestFile: (FilePath) throws -> ArtifactDigest
    public let digestTree: (FilePath) throws -> ArtifactDigest
    public let optionalTreeDigest: (FilePath) throws -> ArtifactDigest?
    public let semanticToolIdentity:
        (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot
    public let taskState: (TaskID) -> PlanningTaskState
    public let validateOutputs: (TaskDeclaration) throws -> Void
    public let artifactSnapshotState: (TaskID, ArtifactDigest) -> ArtifactSnapshotState

    public init(
        resourceCapacity: TaskResourceCapacity,
        runnerPlatform: RunnerPlatform = .current,
        identityPathMap: IdentityPathMap = .empty,
        digestBytes: @escaping ([UInt8]) -> ArtifactDigest,
        digestFile: @escaping (FilePath) throws -> ArtifactDigest,
        digestTree: @escaping (FilePath) throws -> ArtifactDigest,
        optionalTreeDigest: @escaping (FilePath) throws -> ArtifactDigest?,
        semanticToolIdentity:
            @escaping (CommandSpec.Executable, [String: String]) throws -> ToolIdentitySnapshot,
        taskState: @escaping (TaskID) -> PlanningTaskState,
        validateOutputs: @escaping (TaskDeclaration) throws -> Void,
        artifactSnapshotState:
            @escaping (TaskID, ArtifactDigest) -> ArtifactSnapshotState = {
                _, _ in .missing
            }
    ) {
        self.resourceCapacity = resourceCapacity
        self.runnerPlatform = runnerPlatform
        self.identityPathMap = identityPathMap
        self.digestBytes = digestBytes
        self.digestFile = digestFile
        self.digestTree = digestTree
        self.optionalTreeDigest = optionalTreeDigest
        self.semanticToolIdentity = semanticToolIdentity
        self.taskState = taskState
        self.validateOutputs = validateOutputs
        self.artifactSnapshotState = artifactSnapshotState
    }
}
