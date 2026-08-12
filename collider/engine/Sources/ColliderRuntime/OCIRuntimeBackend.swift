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

    public init(
        execution: OCIExecution,
        imageReference: String,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?,
        cancellation: RuntimeCancellation,
        configuration: OCIRuntimeConfiguration
    ) {
        self.execution = execution
        self.imageReference = imageReference
        self.output = output
        self.logging = logging
        self.stage = stage
        self.cancellation = cancellation
        self.configuration = configuration
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
    func deleteImages(references: [String]) async throws -> UInt64
    func persistentWorkspaces(
        configuration: OCIRuntimeConfiguration
    ) async throws -> [OCIPersistentWorkspaceState]
    func deletePersistentWorkspace(
        named name: String,
        configuration: OCIRuntimeConfiguration
    ) async throws
}

extension OCIRuntimeBackend {
    public func health() async throws -> OCIRuntimeHealth {
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

    public func deleteImages(references _: [String]) async throws -> UInt64 {
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
