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
    public var taskDurationsNanoseconds: [String: UInt64]
    public var activeArtifacts: [String: ArtifactDigest]
    public var plannedTasks: [String: ArtifactDigest]?
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
        taskDurationsNanoseconds = [:]
        activeArtifacts = [:]
        plannedTasks = nil
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
