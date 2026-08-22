import Foundation
import SystemPackage

public enum ArtifactInput: Hashable, Sendable {
    case value(name: String, bytes: [UInt8])
    case string(name: String, value: String)
    case environment(name: String, value: String?)
    case swiftBuildContext(SwiftBuildContext)
    case file(FilePath)
    case tree(FilePath)
    /// Identifies the effective Git-owned tree independently of commit and
    /// checkout placement. Ignored files are not source inputs.
    case sourceCheckout(FilePath)
    /// Identifies several target directories in one Git-owned package closure.
    /// The paths are assessed together so one package graph does not launch a
    /// separate Git process for every target.
    case sourceCheckoutClosure([FilePath])
    case tool(CommandSpec.Executable)
}

public enum PathValidation: String, Hashable, Codable, Sendable {
    case exists
    /// A symbolic link whose target is meaningful to whoever reads it rather
    /// than to whoever staged it. A staged SDK read inside a container names
    /// the container's paths, which do not resolve on the host that wrote
    /// them, so resolving here would reject a correct link.
    case symlink
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
    public static let contentIdentityCandidate = Self(
        rawValue: #"^\.[0-9a-f]{24}\.(prepared|preparing)$"#)
    public static let artifactDigestDirectory = Self(rawValue: #"^sha256-[0-9a-f]{64}$"#)
    public static let artifactDigestCandidate = Self(
        rawValue: #"^\.sha256-[0-9a-f]{64}\.prepared$"#)
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

public enum OCIBaseImageSource: String, Hashable, Sendable {
    case registry
    case local
}

public struct OCIImagePreparation: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let context: FilePath
    public let containerFile: FilePath
    public let imageID: FilePath
    public let imageName: String
    public let baseImageSource: OCIBaseImageSource
    public let localBaseImageID: FilePath?
    public let rollbackGenerationCount: UInt32
    public let environment: [String: String]

    public init(
        executionPlatform: ExecutionPlatform,
        context: FilePath,
        containerFile: FilePath,
        imageID: FilePath,
        imageName: String,
        baseImageSource: OCIBaseImageSource = .registry,
        localBaseImageID: FilePath? = nil,
        rollbackGenerationCount: UInt32 = 1,
        environment: [String: String]
    ) {
        self.executionPlatform = executionPlatform
        self.context = context
        self.containerFile = containerFile
        self.imageID = imageID
        self.imageName = imageName
        self.baseImageSource = baseImageSource
        self.localBaseImageID = localBaseImageID
        self.rollbackGenerationCount = rollbackGenerationCount
        self.environment = environment
    }
}

public struct OCIMount: Hashable, Sendable {
    public enum Access: String, Hashable, Sendable {
        case readOnly
    }

    public enum Purpose: String, Hashable, Sendable {
        case input
        case boundedExport
    }

    public let source: FilePath
    public let target: String
    public let purpose: Purpose

    public init(source: FilePath, target: String, access: Access) {
        self.source = source
        self.target = target
        purpose = .input
    }

    public init(boundedExport source: FilePath, target: String) {
        self.source = source
        self.target = target
        purpose = .boundedExport
    }

    public var isReadOnly: Bool { purpose == .input }
}

/// Selects an operational entrypoint without deriving another OCI image from
/// an otherwise reusable dependency image. The executable remains a hashed
/// host input and is exposed to the container read-only.
public struct OCIMountedEntrypoint: Hashable, Sendable {
    public let image: ArtifactReference
    public let executable: FilePath
    public let containerDirectory: String

    public init(
        image: ArtifactReference,
        executable: FilePath,
        containerDirectory: String
    ) {
        let normalized = FilePath(containerDirectory).lexicallyNormalized().string
        precondition(
            executable.isAbsolute && executable.isLexicallyNormal,
            "OCI mounted entrypoint executable must be absolute and normalized")
        precondition(
            containerDirectory.hasPrefix("/")
                && containerDirectory != "/"
                && normalized == containerDirectory,
            "OCI mounted entrypoint directory must be absolute and normalized")
        precondition(
            executable.lastComponent != nil,
            "OCI mounted entrypoint executable must have a file name")
        self.image = image
        self.executable = executable
        self.containerDirectory = containerDirectory
    }

    public var input: ArtifactInput { .file(executable) }

    public var containerPath: String {
        FilePath(containerDirectory).appending(
            executable.lastComponent!.string
        ).string
    }

    public var mount: OCIMount {
        OCIMount(
            source: executable.removingLastComponent(),
            target: containerDirectory,
            access: .readOnly)
    }
}

public struct PersistentWorkspaceIdentity: Codable, Hashable, Sendable {
    public let key: String
    /// The target whose state this workspace holds, or nil when it holds none.
    ///
    /// Source a build reads and host tooling it produces belong to no single
    /// artifact target, and one checkout serving several products is the point
    /// of materializing it once.
    public let artifactTarget: ArtifactTarget?
    public let role: String

    public init(
        key: String,
        artifactTarget: ArtifactTarget?,
        role: String
    ) {
        self.key = key
        self.artifactTarget = artifactTarget
        self.role = role
    }

    package var schedulingKey: String {
        let fields = [
            key,
            artifactTarget?.operatingSystem.rawValue ?? "",
            artifactTarget?.architecture.rawValue ?? "",
            artifactTarget?.abi ?? "",
            artifactTarget?.androidAPILevel.map(String.init) ?? "",
            role,
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: ":")
    }
}

public enum PersistentWorkspaceFilesystem: String, Codable, Hashable, Sendable {
    case ext4
}

public struct PersistentWorkspaceJournal: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        case writeback
    }

    public let mode: Mode
    public let sizeBytes: UInt64

    public init(mode: Mode, sizeBytes: UInt64) {
        self.mode = mode
        self.sizeBytes = sizeBytes
    }

    public static let writeback64MiB = PersistentWorkspaceJournal(
        mode: .writeback,
        sizeBytes: 64 * 1_024 * 1_024)
}

public struct PersistentWorkspaceDeclaration: Codable, Hashable, Sendable {
    public let identity: PersistentWorkspaceIdentity
    public let capacityBytes: UInt64
    public let filesystem: PersistentWorkspaceFilesystem
    public let journal: PersistentWorkspaceJournal
    public let retentionPolicy: StorageRetentionPolicy

    public init(
        identity: PersistentWorkspaceIdentity,
        capacityBytes: UInt64,
        filesystem: PersistentWorkspaceFilesystem,
        journal: PersistentWorkspaceJournal,
        retentionPolicy: StorageRetentionPolicy = .explicitClean
    ) {
        self.identity = identity
        self.capacityBytes = capacityBytes
        self.filesystem = filesystem
        self.journal = journal
        self.retentionPolicy = retentionPolicy
    }
}

public struct OCIPersistentWorkspaceMount: Hashable, Sendable {
    public enum Access: String, Hashable, Sendable {
        case readOnly
        case readWrite
    }

    public let workspace: PersistentWorkspaceDeclaration
    public let target: String
    public let access: Access

    public init(
        workspace: PersistentWorkspaceDeclaration,
        target: String,
        access: Access
    ) {
        self.workspace = workspace
        self.target = target
        self.access = access
    }
}

public struct OCIUserPolicy: Codable, Hashable, Sendable {
    public let userID: UInt32
    public let groupID: UInt32

    public init(userID: UInt32, groupID: UInt32) {
        self.userID = userID
        self.groupID = groupID
    }

    public static let builder = OCIUserPolicy(userID: 1000, groupID: 1000)
}

public enum OCICapabilityPolicy: String, Codable, Hashable, Sendable {
    case dropAll
}

public enum OCIPrivilegePolicy: String, Codable, Hashable, Sendable {
    case prohibitAcquisition
}

public enum OCIProcessFilesystemPolicy: String, Codable, Hashable, Sendable {
    case standard
    case unmasked
    case writableRoot = "writable-root"
}

/// Declares a non-native subprocess that an OCI action executes. Artifact target
/// architecture never implies an executable requirement.
public struct OCIExecutableRequirement: Codable, Hashable, Sendable {
    public let architecture: PlatformArchitecture
    public let executable: String

    public init(
        architecture: PlatformArchitecture,
        executable: String
    ) {
        precondition(!executable.isEmpty)
        self.architecture = architecture
        self.executable = executable
    }
}

public struct OCIResourceLimits: Codable, Hashable, Sendable {
    public let cpuCount: UInt32?
    public let memoryBytes: UInt64?
    public let processCount: UInt32
    public let openFileCount: UInt32

    public init(
        cpuCount: UInt32?,
        memoryBytes: UInt64?,
        processCount: UInt32,
        openFileCount: UInt32 = 65_536
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.processCount = processCount
        self.openFileCount = openFileCount
    }

    public static let build = OCIResourceLimits(
        cpuCount: 24,
        memoryBytes: 128 * 1_024 * 1_024 * 1_024,
        processCount: 32_768,
        openFileCount: 131_072)

    public static let parallelBuild = OCIResourceLimits(
        cpuCount: 12,
        memoryBytes: 56 * 1_024 * 1_024 * 1_024,
        processCount: 16_384,
        openFileCount: 65_536)
}

public struct OCIExecution: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let imageID: FilePath
    public let hostname: String
    public let workingDirectory: String
    public let hostWorkingDirectory: FilePath
    public let mounts: [OCIMount]
    public let persistentWorkspaceMounts: [OCIPersistentWorkspaceMount]
    public let userPolicy: OCIUserPolicy
    public let capabilityPolicy: OCICapabilityPolicy
    public let privilegePolicy: OCIPrivilegePolicy
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let executableRequirements: Set<OCIExecutableRequirement>
    public let resourceLimits: OCIResourceLimits
    public let containerEnvironment: [String: String]
    public let imageEntrypointOverride: String?
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
        persistentWorkspaceMounts: [OCIPersistentWorkspaceMount] = [],
        userPolicy: OCIUserPolicy,
        capabilityPolicy: OCICapabilityPolicy,
        privilegePolicy: OCIPrivilegePolicy,
        processFilesystemPolicy: OCIProcessFilesystemPolicy,
        executableRequirements: Set<OCIExecutableRequirement> = [],
        resourceLimits: OCIResourceLimits,
        containerEnvironment: [String: String],
        imageEntrypointOverride: String? = nil,
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
        self.persistentWorkspaceMounts = persistentWorkspaceMounts
        self.userPolicy = userPolicy
        self.capabilityPolicy = capabilityPolicy
        self.privilegePolicy = privilegePolicy
        self.processFilesystemPolicy = processFilesystemPolicy
        self.executableRequirements = executableRequirements
        self.resourceLimits = resourceLimits
        self.containerEnvironment = containerEnvironment
        self.imageEntrypointOverride = imageEntrypointOverride
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
}

public struct TaskDeclaration: Hashable, Sendable {
    public let id: TaskID
    public let component: ComponentID
    public let dependencies: [TaskID]
    public let orderingDependencies: [TaskOrderingReference]
    public let artifactReferences: [ArtifactReference]
    public let outputSlots: [TaskOutputSlot]
    public let swiftProducts: [SwiftProductRequirement]
    public let swiftTests: [SwiftTestRequirement]
    public let inputs: [ArtifactInput]
    public let outputs: [OutputDeclaration]
    public let postconditions: [PathPostcondition]
    public let locks: [TaskLock]
    public let assessmentPolicy: TaskAssessmentPolicy
    public let recordsActiveArtifact: Bool
    public let durationEstimationMode: String?
    public let action: AnyColliderAction?

    public init(
        id: TaskID,
        component: ComponentID,
        dependencies: [TaskID] = [],
        orderingDependencies: [TaskOrderingReference] = [],
        artifactReferences: [ArtifactReference] = [],
        outputSlots: [TaskOutputSlot] = [],
        swiftProducts: [SwiftProductRequirement] = [],
        swiftTests: [SwiftTestRequirement] = [],
        inputs: [ArtifactInput] = [],
        outputs: [OutputDeclaration] = [],
        postconditions: [PathPostcondition] = [],
        locks: [TaskLock] = [],
        assessmentPolicy: TaskAssessmentPolicy = .incremental,
        recordsActiveArtifact: Bool = false,
        durationEstimationMode: String? = nil,
        action: AnyColliderAction? = nil
    ) {
        let swiftArtifactReferences =
            swiftProducts.flatMap(\.invocation.artifactReferences)
            + swiftTests.flatMap(\.invocation.artifactReferences)
        let allArtifactReferences = Self.uniqued(
            artifactReferences + swiftArtifactReferences)
        self.id = id
        self.component = component
        self.dependencies = Self.uniqued(
            dependencies + allArtifactReferences.map(\.producer))
        self.orderingDependencies = orderingDependencies
        self.artifactReferences = allArtifactReferences
        self.outputSlots = outputSlots
        self.swiftProducts = swiftProducts
        self.swiftTests = swiftTests
        self.inputs = inputs
        self.outputs = outputs
        self.postconditions = postconditions
        self.locks = locks
        self.assessmentPolicy = assessmentPolicy
        self.recordsActiveArtifact = recordsActiveArtifact
        self.durationEstimationMode = durationEstimationMode
        self.action = action
    }

    public var executionDependencies: [TaskID] {
        Self.uniqued(dependencies + orderingDependencies.map(\.producer))
    }

    private static func uniqued<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
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
            outputSlots: outputSlots,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks,
            assessmentPolicy: assessmentPolicy,
            recordsActiveArtifact: recordsActiveArtifact,
            durationEstimationMode: durationEstimationMode,
            action: action)
    }

    public func addingLocks(_ additionalLocks: [TaskLock]) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies,
            orderingDependencies: orderingDependencies,
            artifactReferences: artifactReferences,
            outputSlots: outputSlots,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks + additionalLocks.filter { !locks.contains($0) },
            assessmentPolicy: assessmentPolicy,
            recordsActiveArtifact: recordsActiveArtifact,
            durationEstimationMode: durationEstimationMode,
            action: action)
    }
}

public enum TaskGraphFailure: Error, CustomStringConvertible, Sendable {
    case duplicate(TaskID)
    case missing(task: TaskID, dependency: TaskID)
    case unknownArtifactReference(
        task: TaskID, producer: TaskID, slot: OutputSlotID)
    case cycle([TaskID])

    public var description: String {
        switch self {
        case .duplicate(let id): "duplicate task identifier '\(id)'"
        case .missing(let task, let dependency):
            "task '\(task)' has missing dependency '\(dependency)'"
        case .unknownArtifactReference(let task, let producer, let slot):
            "task '\(task)' references unknown artifact slot '\(producer).\(slot)'"
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
            for reference in declaration.artifactReferences {
                guard
                    let producer = tasks[reference.producer],
                    producer.outputSlots.contains(where: {
                        $0.id == reference.slot && $0.path == reference.path
                    })
                else {
                    throw TaskGraphFailure.unknownArtifactReference(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot)
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
