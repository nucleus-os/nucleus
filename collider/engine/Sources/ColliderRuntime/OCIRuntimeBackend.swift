import ColliderCore
import Foundation
import SystemPackage

public struct OCIRuntimeHealth: Sendable {
    public let appRoot: URL
    public let installRoot: URL
    public let apiServerVersion: String
    public let apiServerCommit: String
    public let apiServerBuild: String
    public let apiServerAppName: String

    public init(
        appRoot: URL,
        installRoot: URL,
        apiServerVersion: String,
        apiServerCommit: String,
        apiServerBuild: String,
        apiServerAppName: String
    ) {
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.apiServerVersion = apiServerVersion
        self.apiServerCommit = apiServerCommit
        self.apiServerBuild = apiServerBuild
        self.apiServerAppName = apiServerAppName
    }
}

public struct OCIRuntimeNetworkState: Equatable, Sendable {
    public let name: String
    public let mode: String

    public init(name: String, mode: String) {
        self.name = name
        self.mode = mode
    }
}

public struct OCIRuntimeResourceUsage: Codable, Equatable, Sendable {
    public let active: Int
    public let reclaimable: UInt64
    public let sizeInBytes: UInt64
    public let total: Int

    public init(
        active: Int,
        reclaimable: UInt64,
        sizeInBytes: UInt64,
        total: Int
    ) {
        self.active = active
        self.reclaimable = reclaimable
        self.sizeInBytes = sizeInBytes
        self.total = total
    }
}

public struct OCIRuntimeDiskUsage: Codable, Equatable, Sendable {
    public let containers: OCIRuntimeResourceUsage
    public let images: OCIRuntimeResourceUsage
    public let volumes: OCIRuntimeResourceUsage

    public init(
        containers: OCIRuntimeResourceUsage,
        images: OCIRuntimeResourceUsage,
        volumes: OCIRuntimeResourceUsage
    ) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    public var reclaimableBytes: UInt64 {
        containers.reclaimable &+ images.reclaimable &+ volumes.reclaimable
    }
}

public struct OCIImageState: Codable, Equatable, Sendable {
    public let reference: String
    public let repository: String
    public let tag: String?
    public let digest: String
    public let creationDate: Date?
    public let active: Bool

    public init(
        reference: String,
        repository: String,
        tag: String?,
        digest: String,
        creationDate: Date?,
        active: Bool
    ) {
        self.reference = reference
        self.repository = repository
        self.tag = tag
        self.digest = digest
        self.creationDate = creationDate
        self.active = active
    }
}

/// The images a container runtime requires to function at all.
///
/// Not catalog storage. Nothing the task graph declares produces these, and no
/// component names them, but a runtime with no init image boots no container
/// and a runtime with no builder image builds no image. They are keyed by
/// repository so a store holding several versions can be told which one this
/// runtime is configured to use, and the reference parsing that separates the
/// two happens where the runtime's own parser lives.
public struct OCIInfrastructureImages: Codable, Equatable, Sendable {
    public let currentByRepository: [String: String]

    public init(currentByRepository: [String: String]) {
        self.currentByRepository = currentByRepository
    }
}

/// A container record the runtime holds.
///
/// A record outlives the process that ran it. Collider deletes its own on
/// completion, cancellation, and failure alike, so one that remains belongs to
/// an execution none of those paths reached, and it is not inert: it holds an
/// unpacked root filesystem and it names an image, which keeps that image from
/// ever being collected.
public struct OCIContainerState: Codable, Equatable, Sendable {
    public let name: String
    public let imageReference: String
    public let running: Bool
    /// Whether the runtime owns this container rather than the task graph.
    public let infrastructure: Bool

    public init(
        name: String,
        imageReference: String,
        running: Bool,
        infrastructure: Bool
    ) {
        self.name = name
        self.imageReference = imageReference
        self.running = running
        self.infrastructure = infrastructure
    }
}

public struct OCIPersistentWorkspaceState: Codable, Equatable, Sendable {
    public let name: String
    public let identity: PersistentWorkspaceIdentity
    public let capacityBytes: UInt64
    public let allocatedBytes: UInt64
    public let active: Bool

    public init(
        name: String,
        identity: PersistentWorkspaceIdentity,
        capacityBytes: UInt64,
        allocatedBytes: UInt64,
        active: Bool
    ) {
        self.name = name
        self.identity = identity
        self.capacityBytes = capacityBytes
        self.allocatedBytes = allocatedBytes
        self.active = active
    }
}

public struct OCIRuntimeExecutionRequest: Sendable {
    public let execution: OCIExecution
    public let imageReference: String
    public let output: CommandSpec.Output
    public let logging: CommandLogging?
    public let stage: TaskID?
    public let cancellation: RuntimeCancellation
    public let configuration: OCIRuntimeConfiguration
    public let taskOutputPresentation: TaskOutputPresentation
    public let taskOutputObserver: TaskOutputObserver

    public init(
        execution: OCIExecution,
        imageReference: String,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?,
        cancellation: RuntimeCancellation,
        configuration: OCIRuntimeConfiguration,
        taskOutputPresentation: TaskOutputPresentation = .verbose,
        taskOutputObserver: TaskOutputObserver = TaskOutputObserver()
    ) {
        self.execution = execution
        self.imageReference = imageReference
        self.output = output
        self.logging = logging
        self.stage = stage
        self.cancellation = cancellation
        self.configuration = configuration
        self.taskOutputPresentation = taskOutputPresentation
        self.taskOutputObserver = taskOutputObserver
    }
}

public struct OCIRuntimeExecutionOutcome: Sendable {
    public let result: CommandResult
    public let timings: OCIExecutionTimings

    public init(result: CommandResult, timings: OCIExecutionTimings) {
        self.result = result
        self.timings = timings
    }
}

public protocol OCIRuntimeBackend: Sendable {
    func prepareImage(_ preparation: OCIImagePreparation) async throws -> String
    func execute(
        _ request: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome
    func health() async throws -> OCIRuntimeHealth
    func network(named name: String) async throws -> OCIRuntimeNetworkState
    func diskUsage(
        configuration: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage
    func images() async throws -> [OCIImageState]
    func deleteImages(references: [String]) async throws
    /// Collects stored image content no live image reaches.
    ///
    /// Separate from deletion because the two answer different questions.
    /// Deleting a reference removes a name; it frees nothing on its own, since
    /// the layers and unpacked filesystems behind it may still be reached from
    /// another name. Collection is what returns bytes, and what it returns is
    /// unrelated to whether this run deleted anything: content is orphaned by
    /// every image rebuild, which replaces the reference a snapshot belonged to
    /// and leaves the snapshot itself unreferenced.
    func collectOrphanedImageContent() async throws -> UInt64
    func infrastructureImages() async throws -> OCIInfrastructureImages
    func containers() async throws -> [OCIContainerState]
    func deleteContainer(named name: String) async throws
    func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState]
    func deletePersistentWorkspace(
        named name: String,
        configuration: OCIRuntimeConfiguration
    ) async throws
    /// Returns a workspace's freed blocks to the host.
    ///
    /// A workspace is a filesystem inside a sparse image, mounted without a
    /// discard option, so deleting files inside it releases nothing: the image
    /// holds every block it has ever written. Reclaiming requires the guest to
    /// issue discards, which requires a capability no build container may hold,
    /// so this is a maintenance operation the action vocabulary cannot express
    /// rather than an execution any task can request.
    func reclaimPersistentWorkspace(
        _ workspace: PersistentWorkspaceDeclaration,
        imageReference: String,
        configuration: OCIRuntimeConfiguration,
        cancellation: RuntimeCancellation
    ) async throws
}

extension OCIRuntimeBackend {
    public func health() async throws -> OCIRuntimeHealth {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func reclaimPersistentWorkspace(
        _ workspace: PersistentWorkspaceDeclaration,
        imageReference: String,
        configuration: OCIRuntimeConfiguration,
        cancellation: RuntimeCancellation
    ) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func network(named name: String) async throws -> OCIRuntimeNetworkState {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func diskUsage(
        configuration: OCIRuntimeConfiguration
    ) async throws -> OCIRuntimeDiskUsage {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func images() async throws -> [OCIImageState] {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func deleteImages(references _: [String]) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func collectOrphanedImageContent() async throws -> UInt64 {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func infrastructureImages() async throws -> OCIInfrastructureImages {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func containers() async throws -> [OCIContainerState] {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func deleteContainer(named _: String) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState] {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func deletePersistentWorkspace(
        named name: String,
        configuration: OCIRuntimeConfiguration
    ) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }
}

struct UnsupportedOCIRuntimeBackend: OCIRuntimeBackend {
    func prepareImage(_ preparation: OCIImagePreparation) async throws -> String {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    func execute(
        _ request: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }
}
