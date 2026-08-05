import Foundation
import SystemPackage

public enum ArtifactInput: Hashable, Sendable {
    case value(name: String, bytes: [UInt8])
    case string(name: String, value: String)
    case environment(name: String, value: String?)
    case swiftBuildContext(SwiftBuildContext)
    case file(FilePath)
    case tree(FilePath)
    /// Hashes a source tree when checked out and otherwise uses the repository
    /// gitlink identity so a fresh checkout can still plan its source-sync task.
    case optionalTree(FilePath, fallback: [UInt8])
    case tool(CommandSpec.Executable)
}

public enum PathValidation: String, Hashable, Codable, Sendable {
    case exists
    case symlinkTarget
    case regularFile
    case executableFile
    case nonEmptyDirectory
    case json
}

public struct OutputDeclaration: Hashable, Sendable {
    public typealias Validation = PathValidation
    public let path: FilePath
    public let validation: PathValidation

    public init(path: FilePath, validation: PathValidation) {
        self.path = path
        self.validation = validation
    }
}

/// A path whose validity is required for task cleanliness but which is shared
/// state rather than an output owned by that task.
public struct PathPostcondition: Hashable, Sendable {
    public let path: FilePath
    public let validation: PathValidation

    public init(path: FilePath, validation: PathValidation) {
        self.path = path
        self.validation = validation
    }
}

public struct DirectoryNamePattern: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let contentIdentity = Self(rawValue: #"^[0-9a-f]{24}$"#)
}

public struct DirectoryRetentionRule: Hashable, Sendable {

    public let root: FilePath
    public let current: FilePath?
    public let retain: UInt32
    public let naming: DirectoryNamePattern

    public init(
        root: FilePath,
        current: FilePath? = nil,
        retain: UInt32,
        naming: DirectoryNamePattern
    ) {
        self.root = root
        self.current = current
        self.retain = retain
        self.naming = naming
    }
}

public struct DirectoryRetentionPlan: Hashable, Sendable {
    public let safetyRoot: FilePath
    public let rules: [DirectoryRetentionRule]

    public init(
        safetyRoot: FilePath,
        rules: [DirectoryRetentionRule]
    ) {
        self.safetyRoot = safetyRoot
        self.rules = rules
    }
}

public struct OCIImagePreparation: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let context: FilePath
    public let containerFile: FilePath
    public let imageID: FilePath
    public let imageName: String
    public let environment: [String: String]

    public init(
        executionPlatform: ExecutionPlatform,
        context: FilePath,
        containerFile: FilePath,
        imageID: FilePath,
        imageName: String,
        environment: [String: String]
    ) {
        self.executionPlatform = executionPlatform
        self.context = context
        self.containerFile = containerFile
        self.imageID = imageID
        self.imageName = imageName
        self.environment = environment
    }
}

public struct OCIMount: Hashable, Sendable {
    public enum Access: String, Hashable, Sendable {
        case readOnly
        case readWrite
    }

    public let source: FilePath
    public let target: String
    public let access: Access

    public init(source: FilePath, target: String, access: Access) {
        self.source = source
        self.target = target
        self.access = access
    }
}

public enum OCINetworkPolicy: String, Hashable, Sendable {
    case externalDisabled = "external-disabled"
    case externalEnabled = "external-enabled"
}

public struct OCIUserPolicy: Hashable, Sendable {
    public let userID: UInt32
    public let groupID: UInt32

    public init(userID: UInt32, groupID: UInt32) {
        self.userID = userID
        self.groupID = groupID
    }

    public static let builder = OCIUserPolicy(userID: 1000, groupID: 1000)
}

public enum OCICapabilityPolicy: String, Hashable, Sendable {
    case dropAll
}

public enum OCIPrivilegePolicy: String, Hashable, Sendable {
    case prohibitAcquisition
}

public enum OCIProcessFilesystemPolicy: String, Hashable, Sendable {
    case standard
    case unmasked
}

/// Controls whether the ARM Linux guest may execute Intel Linux binaries.
/// This is independent of the OCI image architecture: Nucleus always boots an
/// ARM64 Linux image on Apple silicon and enables translation only for tasks
/// that execute x86_64 artifacts.
public enum OCIIntelBinaryTranslationPolicy: String, Hashable, Sendable {
    case disabled
    case required
}

public struct OCIResourceLimits: Hashable, Sendable {
    public let cpuCount: UInt32?
    public let memoryBytes: UInt64?
    public let processCount: UInt32

    public init(
        cpuCount: UInt32?,
        memoryBytes: UInt64?,
        processCount: UInt32
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }

    public static let build = OCIResourceLimits(
        cpuCount: 20,
        memoryBytes: 96 * 1_024 * 1_024 * 1_024,
        processCount: 32_768)

    public static let parallelBuild = OCIResourceLimits(
        cpuCount: 11,
        memoryBytes: 56 * 1_024 * 1_024 * 1_024,
        processCount: 16_384)
}

public struct OCIExecution: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let imageID: FilePath
    public let hostname: String
    public let workingDirectory: String
    public let hostWorkingDirectory: FilePath
    public let mounts: [OCIMount]
    public let temporaryDirectory: FilePath?
    public let networkPolicy: OCINetworkPolicy
    public let userPolicy: OCIUserPolicy
    public let capabilityPolicy: OCICapabilityPolicy
    public let privilegePolicy: OCIPrivilegePolicy
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy
    public let resourceLimits: OCIResourceLimits
    public let containerEnvironment: [String: String]
    public let command: [String]
    public let environment: [String: String]
    public let output: CommandSpec.Output

    public init(
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        imageID: FilePath,
        hostname: String,
        workingDirectory: String,
        hostWorkingDirectory: FilePath,
        mounts: [OCIMount],
        temporaryDirectory: FilePath? = nil,
        networkPolicy: OCINetworkPolicy,
        userPolicy: OCIUserPolicy,
        capabilityPolicy: OCICapabilityPolicy,
        privilegePolicy: OCIPrivilegePolicy,
        processFilesystemPolicy: OCIProcessFilesystemPolicy,
        intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy = .disabled,
        resourceLimits: OCIResourceLimits,
        containerEnvironment: [String: String],
        command: [String],
        environment: [String: String],
        output: CommandSpec.Output
    ) {
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.imageID = imageID
        self.hostname = hostname
        self.workingDirectory = workingDirectory
        self.hostWorkingDirectory = hostWorkingDirectory
        self.mounts = mounts
        self.temporaryDirectory = temporaryDirectory
        self.networkPolicy = networkPolicy
        self.userPolicy = userPolicy
        self.capabilityPolicy = capabilityPolicy
        self.privilegePolicy = privilegePolicy
        self.processFilesystemPolicy = processFilesystemPolicy
        self.intelBinaryTranslationPolicy = intelBinaryTranslationPolicy
        self.resourceLimits = resourceLimits
        self.containerEnvironment = containerEnvironment
        self.command = command
        self.environment = environment
        self.output = output
    }
}

public enum TaskLock: Hashable, Sendable {
    case checkout(String)
    case shared(FilePath)
}

public enum TaskAssessmentPolicy: String, Hashable, Codable, Sendable {
    case always
    case incremental
    case portable
}

public struct TaskDeclaration: Hashable, Sendable {
    public let id: TaskID
    public let component: ComponentID
    public let dependencies: [TaskID]
    public let orderingDependencies: [TaskOrderingReference]
    public let artifactReferences: [AnyArtifactReference]
    public let resultReferences: [AnyTaskResultReference]
    public let outputSlots: [AnyTaskOutputSlot]
    public let resultSlots: [AnyTaskResultSlot]
    /// Direct dependency actions that this task subsumes as a strict superset.
    /// Their identities still participate in this task's identity, but the
    /// runtime may omit their redundant execution when this task is dirty and
    /// selected.
    public let subsumedDependencies: [TaskID]
    public let swiftProducts: [SwiftProductRequirement]
    public let swiftTests: [SwiftTestRequirement]
    public let inputs: [ArtifactInput]
    public let outputs: [OutputDeclaration]
    public let postconditions: [PathPostcondition]
    public let locks: [TaskLock]
    public let assessmentPolicy: TaskAssessmentPolicy
    public let recordsActiveArtifact: Bool
    public let action: AnyColliderAction?

    public init(
        id: TaskID,
        component: ComponentID,
        dependencies: [TaskID] = [],
        orderingDependencies: [TaskOrderingReference] = [],
        artifactReferences: [AnyArtifactReference] = [],
        resultReferences: [AnyTaskResultReference] = [],
        outputSlots: [AnyTaskOutputSlot] = [],
        resultSlots: [AnyTaskResultSlot] = [],
        subsumedDependencies: [TaskID] = [],
        swiftProducts: [SwiftProductRequirement] = [],
        swiftTests: [SwiftTestRequirement] = [],
        inputs: [ArtifactInput] = [],
        outputs: [OutputDeclaration] = [],
        postconditions: [PathPostcondition] = [],
        locks: [TaskLock] = [],
        assessmentPolicy: TaskAssessmentPolicy = .incremental,
        recordsActiveArtifact: Bool = false,
        action: AnyColliderAction? = nil
    ) {
        self.id = id
        self.component = component
        self.dependencies = Self.uniqued(
            dependencies
                + artifactReferences.map(\.producer)
                + resultReferences.map(\.producer))
        self.orderingDependencies = orderingDependencies
        self.artifactReferences = artifactReferences
        self.resultReferences = resultReferences
        self.outputSlots = outputSlots
        self.resultSlots = resultSlots
        self.subsumedDependencies = subsumedDependencies
        self.swiftProducts = swiftProducts
        self.swiftTests = swiftTests
        self.inputs = inputs
        self.outputs = outputs
        self.postconditions = postconditions
        self.locks = locks
        self.assessmentPolicy = assessmentPolicy
        self.recordsActiveArtifact = recordsActiveArtifact
        self.action = action
    }

    public var executionDependencies: [TaskID] {
        Self.uniqued(dependencies + orderingDependencies.map(\.producer))
    }

    private static func uniqued(_ values: [TaskID]) -> [TaskID] {
        var seen: Set<TaskID> = []
        return values.filter { seen.insert($0).inserted }
    }

    public func addingDependencies(
        _ additionalDependencies: [TaskID]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies
                + additionalDependencies.filter {
                    !dependencies.contains($0)
                },
            orderingDependencies: orderingDependencies,
            artifactReferences: artifactReferences,
            resultReferences: resultReferences,
            outputSlots: outputSlots,
            resultSlots: resultSlots,
            subsumedDependencies: subsumedDependencies,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks,
            assessmentPolicy: assessmentPolicy,
            recordsActiveArtifact: recordsActiveArtifact,
            action: action)
    }

    public func addingLocks(_ additionalLocks: [TaskLock]) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies,
            orderingDependencies: orderingDependencies,
            artifactReferences: artifactReferences,
            resultReferences: resultReferences,
            outputSlots: outputSlots,
            resultSlots: resultSlots,
            subsumedDependencies: subsumedDependencies,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks + additionalLocks.filter { !locks.contains($0) },
            assessmentPolicy: assessmentPolicy,
            recordsActiveArtifact: recordsActiveArtifact,
            action: action)
    }
}

public enum TaskGraphFailure: Error, CustomStringConvertible, Sendable {
    case duplicate(TaskID)
    case missing(task: TaskID, dependency: TaskID)
    case invalidSubsumption(task: TaskID, dependency: TaskID)
    case unknownArtifactReference(
        task: TaskID, producer: TaskID, slot: OutputSlotID)
    case artifactReferenceMismatch(
        task: TaskID,
        producer: TaskID,
        slot: OutputSlotID,
        expected: ArtifactValueKind,
        actual: ArtifactValueKind)
    case unknownResultReference(
        task: TaskID, producer: TaskID, slot: OutputSlotID)
    case resultReferenceMismatch(
        task: TaskID,
        producer: TaskID,
        slot: OutputSlotID,
        expected: String,
        actual: String)
    case cycle([TaskID])

    public var description: String {
        switch self {
        case .duplicate(let id): "duplicate task identifier '\(id)'"
        case .missing(let task, let dependency):
            "task '\(task)' has missing dependency '\(dependency)'"
        case .invalidSubsumption(let task, let dependency):
            "task '\(task)' cannot subsume non-dependency '\(dependency)'"
        case .unknownArtifactReference(let task, let producer, let slot):
            "task '\(task)' references unknown artifact slot '\(producer).\(slot)'"
        case .artifactReferenceMismatch(
            let task, let producer, let slot, let expected, let actual):
            "task '\(task)' expects '\(expected.rawValue)' from "
                + "'\(producer).\(slot)', which produces '\(actual.rawValue)'"
        case .unknownResultReference(let task, let producer, let slot):
            "task '\(task)' references unknown result slot '\(producer).\(slot)'"
        case .resultReferenceMismatch(
            let task, let producer, let slot, let expected, let actual):
            "task '\(task)' expects result '\(expected)' from "
                + "'\(producer).\(slot)', which produces '\(actual)'"
        case .cycle(let path):
            "task dependency cycle: " + path.map(\.rawValue).joined(separator: " -> ")
        }
    }
}

public struct TaskGraph: Sendable {
    private let tasks: [TaskID: TaskDeclaration]

    package var declarations: [TaskDeclaration] {
        tasks.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public init(_ declarations: [TaskDeclaration]) throws {
        var tasks: [TaskID: TaskDeclaration] = [:]
        for declaration in declarations {
            guard tasks.updateValue(declaration, forKey: declaration.id) == nil else {
                throw TaskGraphFailure.duplicate(declaration.id)
            }
        }
        for declaration in declarations {
            for dependency in declaration.executionDependencies
            where tasks[dependency] == nil {
                throw TaskGraphFailure.missing(task: declaration.id, dependency: dependency)
            }
            for dependency in declaration.subsumedDependencies
            where !declaration.dependencies.contains(dependency) {
                throw TaskGraphFailure.invalidSubsumption(
                    task: declaration.id,
                    dependency: dependency)
            }
            for reference in declaration.artifactReferences {
                guard
                    let producer = tasks[reference.producer],
                    let slot = producer.outputSlots.first(where: {
                        $0.id == reference.slot && $0.path == reference.path
                    })
                else {
                    throw TaskGraphFailure.unknownArtifactReference(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot)
                }
                guard slot.kind == reference.kind else {
                    throw TaskGraphFailure.artifactReferenceMismatch(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot,
                        expected: reference.kind,
                        actual: slot.kind)
                }
            }
            for reference in declaration.resultReferences {
                guard
                    let producer = tasks[reference.producer],
                    let slot = producer.resultSlots.first(where: {
                        $0.id == reference.slot
                    })
                else {
                    throw TaskGraphFailure.unknownResultReference(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot)
                }
                guard slot.valueType == reference.valueType else {
                    throw TaskGraphFailure.resultReferenceMismatch(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot,
                        expected: reference.valueType,
                        actual: slot.valueType)
                }
            }
        }
        self.tasks = tasks
        _ = try orderedTasks(selecting: Array(tasks.keys))
    }

    public func orderedTasks(selecting selected: [TaskID]) throws -> [TaskDeclaration] {
        var permanent: Set<TaskID> = []
        var temporary: [TaskID] = []
        var result: [TaskDeclaration] = []

        func visit(_ id: TaskID) throws {
            if permanent.contains(id) { return }
            if let index = temporary.firstIndex(of: id) {
                throw TaskGraphFailure.cycle(Array(temporary[index...]) + [id])
            }
            guard let task = tasks[id] else {
                throw TaskGraphFailure.missing(task: id, dependency: id)
            }
            temporary.append(id)
            for dependency in task.executionDependencies { try visit(dependency) }
            temporary.removeLast()
            permanent.insert(id)
            result.append(task)
        }

        for id in selected { try visit(id) }
        return result
    }
}

public struct CanonicalDigestEncoder: Sendable {
    public private(set) var bytes: [UInt8] = []
    private let identityPathMap: IdentityPathMap

    public init(identityPathMap: IdentityPathMap = .empty) {
        self.identityPathMap = identityPathMap
    }

    public mutating func append(tag: UInt8, string: String) {
        append(
            tag: tag,
            bytes: Array(identityPathMap.canonicalize(string).utf8))
    }

    public mutating func append(tag: UInt8, bytes value: [UInt8]) {
        bytes.append(tag)
        bytes += withBigEndianBytes(UInt64(value.count))
        bytes += value
    }

    public mutating func append(tag: UInt8, integer: UInt64) {
        append(tag: tag, bytes: withBigEndianBytes(integer))
    }
}

private func withBigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { unsafe Array($0) }
}
