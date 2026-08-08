import Foundation

public struct RunID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum RunStatus: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case interrupted
}

public enum TaskRunOutcome: String, Codable, Sendable {
    case localClean
    case executed
}

public struct OCIExecutionTimings: Codable, Hashable, Sendable {
    public let configurationDurationNanoseconds: UInt64
    public let creationDurationNanoseconds: UInt64
    public let bootstrapDurationNanoseconds: UInt64
    public let processDurationNanoseconds: UInt64
    public let cleanupDurationNanoseconds: UInt64
    public let totalDurationNanoseconds: UInt64

    public init(
        configurationDurationNanoseconds: UInt64,
        creationDurationNanoseconds: UInt64,
        bootstrapDurationNanoseconds: UInt64,
        processDurationNanoseconds: UInt64,
        cleanupDurationNanoseconds: UInt64,
        totalDurationNanoseconds: UInt64
    ) {
        self.configurationDurationNanoseconds = configurationDurationNanoseconds
        self.creationDurationNanoseconds = creationDurationNanoseconds
        self.bootstrapDurationNanoseconds = bootstrapDurationNanoseconds
        self.processDurationNanoseconds = processDurationNanoseconds
        self.cleanupDurationNanoseconds = cleanupDurationNanoseconds
        self.totalDurationNanoseconds = totalDurationNanoseconds
    }

    public static let zero = Self(
        configurationDurationNanoseconds: 0,
        creationDurationNanoseconds: 0,
        bootstrapDurationNanoseconds: 0,
        processDurationNanoseconds: 0,
        cleanupDurationNanoseconds: 0,
        totalDurationNanoseconds: 0)
}

public struct OCIExecutionObservation: Codable, Hashable, Sendable {
    public let imageDigest: ArtifactDigest
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let userPolicy: OCIUserPolicy
    public let capabilityPolicy: OCICapabilityPolicy
    public let privilegePolicy: OCIPrivilegePolicy
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy
    public let resourceLimits: OCIResourceLimits
    public let status: Int32
    public let timings: OCIExecutionTimings?

    public init(
        imageDigest: ArtifactDigest,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        userPolicy: OCIUserPolicy,
        capabilityPolicy: OCICapabilityPolicy,
        privilegePolicy: OCIPrivilegePolicy,
        processFilesystemPolicy: OCIProcessFilesystemPolicy,
        intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy,
        resourceLimits: OCIResourceLimits,
        status: Int32,
        timings: OCIExecutionTimings? = nil
    ) {
        self.imageDigest = imageDigest
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.userPolicy = userPolicy
        self.capabilityPolicy = capabilityPolicy
        self.privilegePolicy = privilegePolicy
        self.processFilesystemPolicy = processFilesystemPolicy
        self.intelBinaryTranslationPolicy = intelBinaryTranslationPolicy
        self.resourceLimits = resourceLimits
        self.status = status
        self.timings = timings
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
    public var observations: TaskExecutionObservations?

    public init(
        plan: TaskPlanEntry,
        outcome: TaskRunOutcome? = nil,
        durationNanoseconds: UInt64? = nil,
        observations: TaskExecutionObservations? = nil
    ) {
        self.plan = plan
        self.outcome = outcome
        self.durationNanoseconds = durationNanoseconds
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
    public var schedulingWaitDurationNanoseconds: UInt64?
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
        schedulingWaitDurationNanoseconds = nil
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

public struct RunEvent: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let timestamp: String
    public let runID: RunID
    public let payload: Payload

    public init(
        sequence: UInt64,
        timestamp: String,
        runID: RunID,
        payload: Payload
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.runID = runID
        self.payload = payload
    }

    public enum Payload: Codable, Hashable, Sendable {
        case runStarted(resumed: Bool)
        case task(TaskEvent)
        case operation(OperationEvent)
        case download(DownloadEvent)
        case wait(WaitEvent)
        case artifact(ArtifactEvent)
        case interruption(InterruptionEvent)
        case terminal(TerminalRunEvent)
    }
}

public enum TaskEvent: Codable, Hashable, Sendable {
    case started(TaskID)
    case skipped(task: TaskID, explanation: String)
    case succeeded(TaskID)
    case cancelled(TaskID)
    case failed(task: TaskID, failure: ExecutionFailure)

    public var task: TaskID {
        switch self {
        case .started(let task), .succeeded(let task), .cancelled(let task): task
        case .skipped(let task, _), .failed(let task, _): task
        }
    }
}

public enum OperationEvent: Codable, Hashable, Sendable {
    case started(OperationContext)
    case finished(OperationResult)
    case failed(ExecutionFailure)
}

public struct OperationContext: Codable, Hashable, Sendable {
    public let task: TaskID?
    public let operation: String
    public let command: [String]
    public let invocation: String
    public let workingDirectory: String
    public let logPath: String?

    public init(
        task: TaskID?,
        operation: String,
        command: [String],
        invocation: String,
        workingDirectory: String,
        logPath: String?
    ) {
        self.task = task
        self.operation = operation
        self.command = command
        self.invocation = invocation
        self.workingDirectory = workingDirectory
        self.logPath = logPath
    }
}

public struct OperationResult: Codable, Hashable, Sendable {
    public let context: OperationContext
    public let status: Int32
    public let signal: Int32?
    public let timedOut: Bool

    public init(
        context: OperationContext,
        status: Int32,
        signal: Int32?,
        timedOut: Bool
    ) {
        self.context = context
        self.status = status
        self.signal = signal
        self.timedOut = timedOut
    }
}

public struct DownloadEvent: Codable, Hashable, Sendable {
    public let digest: ArtifactDigest
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(
        digest: ArtifactDigest,
        receivedBytes: Int64,
        expectedBytes: Int64?
    ) {
        self.digest = digest
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

public enum WaitEvent: Codable, Hashable, Sendable {
    case started(task: TaskID?, resource: String)
    case finished(task: TaskID?, resource: String)
}

public struct ArtifactEvent: Codable, Hashable, Sendable {
    public let name: String
    public let digest: ArtifactDigest

    public init(name: String, digest: ArtifactDigest) {
        self.name = name
        self.digest = digest
    }
}

public struct InterruptionEvent: Codable, Hashable, Sendable {
    public let signal: Int32?
    public let reason: String

    public init(signal: Int32? = nil, reason: String) {
        self.signal = signal
        self.reason = reason
    }
}

public struct TerminalRunEvent: Codable, Hashable, Sendable {
    public let status: RunStatus
    public let failedTask: TaskID?

    public init(status: RunStatus, failedTask: TaskID? = nil) {
        self.status = status
        self.failedTask = failedTask
    }
}

public struct ExecutionFailure: Error, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let task: TaskID?
    public let operation: String?
    public let command: [String]?
    public let status: Int32?
    public let signal: Int32?
    public let invocation: String?
    public let workingDirectory: String?
    public let logPath: String?
    public let reason: String

    public init(
        task: TaskID? = nil,
        operation: String? = nil,
        command: [String]? = nil,
        status: Int32? = nil,
        signal: Int32? = nil,
        invocation: String? = nil,
        workingDirectory: String? = nil,
        logPath: String? = nil,
        reason: String
    ) {
        self.task = task
        self.operation = operation.map(CredentialScrubber.text)
        self.command = command.map(CredentialScrubber.command)
        self.status = status
        self.signal = signal
        self.invocation = invocation.map(CredentialScrubber.text)
        self.workingDirectory = workingDirectory.map(CredentialScrubber.text)
        self.logPath = logPath.map(CredentialScrubber.text)
        self.reason = CredentialScrubber.text(reason)
    }

    public var description: String {
        var result = reason
        if let task { result += "\n  task: \(task.rawValue)" }
        if let operation { result += "\n  operation: \(operation)" }
        if let invocation { result += "\n  command: \(invocation)" }
        if let status { result += "\n  status: \(status)" }
        if let signal { result += "\n  signal: \(signal)" }
        if let workingDirectory { result += "\n  directory: \(workingDirectory)" }
        if let logPath { result += "\n  log: \(logPath)" }
        return result
    }

    public func addingContext(
        task: TaskID? = nil,
        logPath: String? = nil
    ) -> ExecutionFailure {
        ExecutionFailure(
            task: self.task ?? task,
            operation: operation,
            command: command,
            status: status,
            signal: signal,
            invocation: invocation,
            workingDirectory: workingDirectory,
            logPath: self.logPath ?? logPath,
            reason: reason)
    }
}

public enum ReducedTaskState: Codable, Hashable, Sendable {
    case running
    case skipped(explanation: String)
    case succeeded
    case cancelled
    case failed(ExecutionFailure)
}

public struct ReducedRunState: Codable, Hashable, Sendable {
    public fileprivate(set) var runID: RunID?
    public fileprivate(set) var status: RunStatus?
    public fileprivate(set) var resumeCount: Int
    public fileprivate(set) var tasks: [TaskID: ReducedTaskState]
    public fileprivate(set) var failedTask: TaskID?

    public init() {
        runID = nil
        status = nil
        resumeCount = 0
        tasks = [:]
        failedTask = nil
    }
}

public enum RunEventReductionFailure: Error, Hashable, Sendable,
    CustomStringConvertible
{
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case mixedRuns(expected: RunID, actual: RunID)

    public var description: String {
        switch self {
        case .unexpectedSequence(let expected, let actual):
            "expected run event sequence \(expected), found \(actual)"
        case .mixedRuns(let expected, let actual):
            "expected run '\(expected)', found event for '\(actual)'"
        }
    }
}

public struct RunEventReducer: Sendable {
    public private(set) var state = ReducedRunState()
    private var nextSequence: UInt64 = 0

    public init() {}

    public mutating func consume(_ event: RunEvent) throws {
        guard event.sequence == nextSequence else {
            throw RunEventReductionFailure.unexpectedSequence(
                expected: nextSequence,
                actual: event.sequence)
        }
        if let runID = state.runID, runID != event.runID {
            throw RunEventReductionFailure.mixedRuns(
                expected: runID,
                actual: event.runID)
        }
        state.runID = event.runID
        nextSequence += 1
        switch event.payload {
        case .runStarted(let resumed):
            state.status = .running
            state.failedTask = nil
            if resumed { state.resumeCount += 1 }
        case .task(let taskEvent):
            switch taskEvent {
            case .started(let task): state.tasks[task] = .running
            case .skipped(let task, let explanation):
                state.tasks[task] = .skipped(explanation: explanation)
            case .succeeded(let task): state.tasks[task] = .succeeded
            case .cancelled(let task): state.tasks[task] = .cancelled
            case .failed(let task, let failure):
                state.tasks[task] = .failed(failure)
                state.failedTask = task
            }
        case .interruption:
            state.status = .interrupted
        case .terminal(let terminal):
            state.status = terminal.status
            state.failedTask = terminal.failedTask ?? state.failedTask
        case .operation, .download, .wait, .artifact:
            break
        }
    }

    public static func reduce(_ events: some Sequence<RunEvent>) throws -> ReducedRunState {
        var reducer = RunEventReducer()
        for event in events { try reducer.consume(event) }
        return reducer.state
    }
}
