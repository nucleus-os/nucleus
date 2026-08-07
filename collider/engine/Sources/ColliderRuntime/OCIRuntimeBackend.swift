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

public struct OCIRuntimeExecutionRequest: Sendable {
    public let execution: OCIExecution
    public let imageReference: String
    public let temporaryDirectory: FilePath?
    public let output: CommandSpec.Output
    public let logging: CommandLogging?
    public let stage: TaskID?
    public let cancellation: RuntimeCancellation
    public let configuration: OCIRuntimeConfiguration

    public init(
        execution: OCIExecution,
        imageReference: String,
        temporaryDirectory: FilePath?,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?,
        cancellation: RuntimeCancellation,
        configuration: OCIRuntimeConfiguration
    ) {
        self.execution = execution
        self.imageReference = imageReference
        self.temporaryDirectory = temporaryDirectory
        self.output = output
        self.logging = logging
        self.stage = stage
        self.cancellation = cancellation
        self.configuration = configuration
    }
}

public protocol OCIRuntimeBackend: Sendable {
    func prepareImage(_ preparation: OCIImagePreparation) async throws -> String
    func execute(_ request: OCIRuntimeExecutionRequest) async throws -> CommandResult
    func health() async throws -> OCIRuntimeHealth
    func network(named name: String) async throws -> OCIRuntimeNetworkState
    func diskUsage() async throws -> OCIRuntimeDiskUsage
    func pruneImages() async throws
}

extension OCIRuntimeBackend {
    public func health() async throws -> OCIRuntimeHealth {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func network(named name: String) async throws -> OCIRuntimeNetworkState {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func diskUsage() async throws -> OCIRuntimeDiskUsage {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    public func pruneImages() async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }
}

struct UnsupportedOCIRuntimeBackend: OCIRuntimeBackend {
    func prepareImage(_ preparation: OCIImagePreparation) async throws -> String {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    func execute(_ request: OCIRuntimeExecutionRequest) async throws -> CommandResult {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }
}
