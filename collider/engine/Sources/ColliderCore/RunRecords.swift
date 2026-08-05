import Foundation

public struct RunID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum RunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case interrupted
}

public enum TaskRunOutcome: String, Codable, Sendable {
    case localClean
    case subsumed
    case restored
    case executed
}

public struct OCIExecutionObservation: Codable, Hashable, Sendable {
    public let imageDigest: ArtifactDigest
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let networkPolicy: OCINetworkPolicy
    public let userPolicy: OCIUserPolicy
    public let capabilityPolicy: OCICapabilityPolicy
    public let privilegePolicy: OCIPrivilegePolicy
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy
    public let resourceLimits: OCIResourceLimits
    public let status: Int32

    public init(
        imageDigest: ArtifactDigest,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        networkPolicy: OCINetworkPolicy,
        userPolicy: OCIUserPolicy,
        capabilityPolicy: OCICapabilityPolicy,
        privilegePolicy: OCIPrivilegePolicy,
        processFilesystemPolicy: OCIProcessFilesystemPolicy,
        intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy,
        resourceLimits: OCIResourceLimits,
        status: Int32
    ) {
        self.imageDigest = imageDigest
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.networkPolicy = networkPolicy
        self.userPolicy = userPolicy
        self.capabilityPolicy = capabilityPolicy
        self.privilegePolicy = privilegePolicy
        self.processFilesystemPolicy = processFilesystemPolicy
        self.intelBinaryTranslationPolicy = intelBinaryTranslationPolicy
        self.resourceLimits = resourceLimits
        self.status = status
    }
}

public struct TaskExecutionObservations: Codable, Hashable, Sendable {
    public var containerExecutions: [OCIExecutionObservation]

    public init(containerExecutions: [OCIExecutionObservation] = []) {
        self.containerExecutions = containerExecutions
    }

    public var isEmpty: Bool {
        containerExecutions.isEmpty
    }
}

public struct RunTaskRecord: Codable, Sendable {
    public let plan: TaskPlanEntry
    public var outcome: TaskRunOutcome?
    public var durationNanoseconds: UInt64?
    public var artifactSnapshotDigests: [String: ArtifactDigest]?
    public var observations: TaskExecutionObservations?

    public init(
        plan: TaskPlanEntry,
        outcome: TaskRunOutcome? = nil,
        durationNanoseconds: UInt64? = nil,
        artifactSnapshotDigests: [String: ArtifactDigest]? = nil,
        observations: TaskExecutionObservations? = nil
    ) {
        self.plan = plan
        self.outcome = outcome
        self.durationNanoseconds = durationNanoseconds
        self.artifactSnapshotDigests = artifactSnapshotDigests
        self.observations = observations
    }
}

public struct RunManifest: Codable, Sendable {
    public let runID: RunID
    public let command: [String]
    public let startedAt: String
    public var finishedAt: String?
    public var status: RunStatus
    public var failedTask: TaskID?
    public var planningDurationNanoseconds: UInt64?
    public var selectedInputHashingDurationNanoseconds: UInt64?
    public var swiftPMInvocationCount: Int?
    public var executionDurationNanoseconds: UInt64?
    public var criticalPathDurationNanoseconds: UInt64?
    public var resourceWaitDurationNanoseconds: UInt64?
    public var activeArtifacts: [String: ArtifactDigest]
    public var tasks: [String: RunTaskRecord]?
    public var resumedAt: [String]?
    public var resumeCount: Int?

    public init(runID: RunID, command: [String], startedAt: String) {
        self.runID = runID
        self.command = command
        self.startedAt = startedAt
        finishedAt = nil
        status = .running
        failedTask = nil
        planningDurationNanoseconds = nil
        selectedInputHashingDurationNanoseconds = nil
        swiftPMInvocationCount = nil
        executionDurationNanoseconds = nil
        criticalPathDurationNanoseconds = nil
        resourceWaitDurationNanoseconds = nil
        activeArtifacts = [:]
        tasks = nil
        resumedAt = nil
        resumeCount = nil
    }
}

public struct TaskStateRecord: Codable, Sendable {
    public let task: TaskID
    public let identity: ArtifactDigest
    public let outputs: [String]
    public let completedAt: String

    public init(
        task: TaskID,
        identity: ArtifactDigest,
        outputs: [String],
        completedAt: String
    ) {
        self.task = task
        self.identity = identity
        self.outputs = outputs
        self.completedAt = completedAt
    }
}

public struct ColliderEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case runStarted
        case taskStarted
        case taskSkipped
        case taskRestored
        case taskSucceeded
        case taskFailed
        case runFinished
        case downloadProgress
    }

    public let sequence: UInt64
    public let timestamp: String
    public let kind: Kind
    public let runID: RunID
    public let task: TaskID?
    public let message: String?

    public init(
        sequence: UInt64,
        timestamp: String,
        kind: Kind,
        runID: RunID,
        task: TaskID? = nil,
        message: String? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.runID = runID
        self.task = task
        self.message = message
    }
}
