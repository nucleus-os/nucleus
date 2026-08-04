import ColliderCore
import Foundation
import Logging
import SystemPackage

#if os(macOS)
import ContainerAPIClient
import ContainerCommands
import ContainerResource
import Darwin
#endif

public struct AppleContainerBackendHealth: Sendable {
    public let appRoot: URL
    public let installRoot: URL
    public let apiServerVersion: String
    public let apiServerCommit: String
    public let apiServerBuild: String
    public let apiServerAppName: String
}

#if os(macOS)
public func appleContainerBackendHealth() async throws
    -> AppleContainerBackendHealth
{
    let health = try await ClientHealthCheck.ping()
    return AppleContainerBackendHealth(
        appRoot: health.appRoot,
        installRoot: health.installRoot,
        apiServerVersion: health.apiServerVersion,
        apiServerCommit: health.apiServerCommit,
        apiServerBuild: health.apiServerBuild,
        apiServerAppName: health.apiServerAppName)
}

struct AppleContainerLifecycle: Sendable {
    private let client: ContainerClient

    init(client: ContainerClient = ContainerClient()) {
        self.client = client
    }

    func execute(
        _ execution: OCIExecution,
        name: String,
        imageReference: String,
        temporaryDirectory: FilePath?,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID
    ) async throws -> CommandResult {
        let cleanup = AppleContainerCleanup(client: client, name: name)
        return try await withTaskCancellationHandler {
            do {
                let result = try await executeCreatedContainer(
                    execution,
                    name: name,
                    imageReference: imageReference,
                    temporaryDirectory: temporaryDirectory,
                    output: output,
                    logging: logging,
                    stage: stage)
                try await cleanup.deleteAndVerify()
                return result
            } catch {
                do {
                    try await cleanup.deleteAndVerify()
                } catch let cleanupError {
                    throw OCIExecutorFailure.containerCleanupFailed(
                        name: name,
                        reason: String(describing: cleanupError))
                }
                throw error
            }
        } onCancel: {
            Task.detached {
                try? await cleanup.deleteAndVerify()
            }
        }
    }

    private func executeCreatedContainer(
        _ execution: OCIExecution,
        name: String,
        imageReference: String,
        temporaryDirectory: FilePath?,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID
    ) async throws -> CommandResult {
        let flags = appleContainerFlags(
            execution,
            name: name,
            temporaryDirectory: temporaryDirectory)
        try flags.management.validate()
        let systemConfiguration = try await Application.loadContainerSystemConfig()
        let (configuration, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: name,
            image: imageReference,
            arguments: execution.command,
            process: flags.process,
            management: flags.management,
            resource: flags.resource,
            registry: Flags.Registry(scheme: "auto"),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
            containerSystemConfig: systemConfiguration,
            progressUpdate: { _ in },
            log: Logger(label: "dev.nucleus.collider.apple-container") { _ in
                SwiftLogNoOpLogHandler()
            })

        try Task.checkCancellation()
        try await client.create(
            configuration: configuration,
            options: .default,
            kernel: kernel,
            initImage: initImage)

        let outputSession = try AppleContainerOutputSession(
            output: output,
            logging: logging,
            stage: stage)
        do {
            let process = try await client.bootstrap(
                id: name,
                stdio: outputSession.stdio)
            try await process.start()
            try outputSession.closeWriters()
            let status = try await process.wait()
            return try await outputSession.finish(status: status)
        } catch {
            try? outputSession.closeWriters()
            await outputSession.cancel()
            throw error
        }
    }
}

struct AppleContainerFlags {
    let process: Flags.Process
    let management: Flags.Management
    let resource: Flags.Resource
}

func appleContainerFlags(
    _ execution: OCIExecution,
    name: String,
    temporaryDirectory: FilePath?
) -> AppleContainerFlags {
    var mounts = execution.mounts.map { mount in
        var value =
            "type=bind,source=\(mount.source),target=\(mount.target)"
        if mount.access == .readOnly {
            value += ",readonly"
        }
        return value
    }
    var temporaryFilesystems = ["/home/nucleus-build"]
    if let temporaryDirectory {
        mounts.append(
            "type=bind,source=\(temporaryDirectory),target=/tmp")
    } else {
        temporaryFilesystems.append("/tmp")
    }

    let process = Flags.Process(
        cwd: execution.workingDirectory,
        env: execution.containerEnvironment.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" },
        envFile: [],
        gid: execution.userPolicy.groupID,
        interactive: false,
        tty: false,
        uid: execution.userPolicy.userID,
        ulimits: [
            "nproc=\(execution.resourceLimits.processCount):\(execution.resourceLimits.processCount)"
        ],
        user: nil)
    let management = Flags.Management(
        arch: "arm64",
        capAdd: [],
        capDrop: ["ALL"],
        cidfile: "",
        detach: false,
        dns: Flags.DNS(
            domain: nil,
            nameservers: [],
            options: [],
            searchDomains: []),
        dnsDisabled: execution.networkPolicy == .externalDisabled,
        entrypoint: nil,
        initImage: nil,
        kernel: nil,
        kernelArgs: [],
        labels: ["dev.nucleus.collider.managed=true"],
        mounts: mounts,
        name: name,
        networks: execution.networkPolicy == .externalDisabled
            ? [OCIBackendContract.appleOfflineNetwork] : [],
        os: "linux",
        platform: "linux/arm64",
        publishPorts: [],
        publishSockets: [],
        readOnly: true,
        remove: false,
        rosetta: execution.intelBinaryTranslationPolicy == .required,
        runtime: nil,
        ssh: false,
        shmSize: nil,
        tmpFs: temporaryFilesystems,
        useInit: false,
        virtualization: false,
        volumes: [])
    let resource = Flags.Resource(
        cpus: execution.resourceLimits.cpuCount.map(Int64.init),
        memory: execution.resourceLimits.memoryBytes.map(String.init))
    return AppleContainerFlags(
        process: process,
        management: management,
        resource: resource)
}

actor AppleContainerCleanup {
    private let name: String
    private let delete: @Sendable () async throws -> Void
    private let exists: @Sendable () async throws -> Bool
    private var completed = false
    private var cleanupTask: Task<Void, any Error>?

    init(client: ContainerClient, name: String) {
        self.name = name
        delete = {
            try await client.delete(id: name, force: true)
        }
        exists = {
            try await !client.list(
                filters: ContainerListFilters(ids: [name])
            ).isEmpty
        }
    }

    init(
        name: String,
        delete: @Sendable @escaping () async throws -> Void,
        exists: @Sendable @escaping () async throws -> Bool
    ) {
        self.name = name
        self.delete = delete
        self.exists = exists
    }

    func deleteAndVerify() async throws {
        guard !completed else { return }
        if let cleanupTask {
            try await cleanupTask.value
            return
        }
        let name = name
        let delete = delete
        let exists = exists
        let cleanupTask = Task {
            try await Self.performDeleteAndVerify(
                name: name,
                delete: delete,
                exists: exists)
        }
        self.cleanupTask = cleanupTask
        do {
            try await cleanupTask.value
            completed = true
        } catch {
            self.cleanupTask = nil
            throw error
        }
    }

    private static func performDeleteAndVerify(
        name: String,
        delete: @Sendable () async throws -> Void,
        exists: @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(30))
        var lastError: (any Error)?
        repeat {
            do {
                try await delete()
            } catch {
                lastError = error
            }
            do {
                if try await !exists() {
                    return
                }
            } catch {
                lastError = error
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        } while ContinuousClock().now < deadline
        throw OCIExecutorFailure.containerCleanupFailed(
            name: name,
            reason: lastError.map(String.init(describing:))
                ?? "container remained registered after forced deletion")
    }
}

actor AppleContainerSuspension {
    private let name: String
    private let stop: @Sendable () async throws -> Void
    private let status: @Sendable () async throws -> RuntimeStatus?

    init(client: ContainerClient, name: String) {
        self.name = name
        stop = {
            try await client.stop(id: name)
        }
        status = {
            try await client.list(
                filters: ContainerListFilters(ids: [name])
            ).first?.status
        }
    }

    init(
        name: String,
        stop: @Sendable @escaping () async throws -> Void,
        status: @Sendable @escaping () async throws -> RuntimeStatus?
    ) {
        self.name = name
        self.stop = stop
        self.status = status
    }

    func stopAndVerify() async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(30))
        var lastError: (any Error)?
        repeat {
            do {
                guard let current = try await status() else { return }
                switch current {
                case .stopped:
                    return
                case .running, .unknown:
                    try await stop()
                case .stopping:
                    break
                }
            } catch {
                lastError = error
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        } while ContinuousClock().now < deadline
        throw OCIExecutorFailure.containerSuspensionFailed(
            name: name,
            reason: lastError.map(String.init(describing:))
                ?? "container did not reach the stopped state")
    }
}

private final class AppleContainerOutputSession: @unchecked Sendable {
    let stdio: [FileHandle?]

    private let writers: [FileHandle]
    private let pipes: [AppleContainerPipe]
    private let outputTask: Task<[UInt8], any Error>
    private let errorTask: Task<[UInt8], any Error>?

    init(
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID
    ) throws {
        guard output != .terminal else {
            throw OCIExecutorFailure.unsupportedTerminalOutput
        }
        let file: FilePath? =
            switch output {
            case .file(let path): path
            default: nil
            }
        let sink = try CommandOutputSink(
            logging: file == nil ? logging : nil,
            stage: stage,
            file: file)

        if case .combined(let limit) = output {
            let pipe = AppleContainerPipe()
            stdio = [nil, pipe.writer, pipe.writer]
            writers = [pipe.writer]
            pipes = [pipe]
            outputTask = Task {
                try await collectAppleContainerOutput(
                    pipe.stream,
                    limit: limit,
                    mirror: nil,
                    sink: sink)
            }
            errorTask = nil
            return
        }

        let stdout = AppleContainerPipe()
        let stderr = AppleContainerPipe()
        stdio = [nil, stdout.writer, stderr.writer]
        writers = [stdout.writer, stderr.writer]
        pipes = [stdout, stderr]
        let captureLimit: Int? =
            switch output {
            case .captured(let limit): limit
            default: nil
            }
        outputTask = Task {
            try await collectAppleContainerOutput(
                stdout.stream,
                limit: captureLimit,
                mirror: output == .inherited ? .standardOutput : nil,
                sink: sink)
        }
        errorTask = Task {
            try await collectAppleContainerOutput(
                stderr.stream,
                limit: nil,
                mirror: output == .inherited || output.isCaptured
                    ? .standardError : nil,
                sink: sink)
        }
    }

    func closeWriters() throws {
        for writer in writers {
            try writer.close()
        }
    }

    func finish(status: Int32) async throws -> CommandResult {
        if await !outputDrainedWithinLimit() {
            for pipe in pipes {
                pipe.finish()
            }
        }
        let bytes = try await outputTask.value
        if let errorTask {
            _ = try await errorTask.value
        }
        return CommandResult(
            status: status,
            standardOutput: String(decoding: bytes, as: UTF8.self))
    }

    func cancel() async {
        for pipe in pipes {
            pipe.finish()
        }
        _ = try? await outputTask.value
        if let errorTask {
            _ = try? await errorTask.value
        }
    }

    private func outputDrainedWithinLimit() async -> Bool {
        await withCheckedContinuation { continuation in
            let race = AppleContainerDrainRace()
            Task { [outputTask, errorTask] in
                _ = try? await outputTask.value
                if let errorTask {
                    _ = try? await errorTask.value
                }
                race.resolve(true, continuation: continuation)
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                race.resolve(false, continuation: continuation)
            }
        }
    }
}

extension CommandSpec.Output {
    fileprivate var isCaptured: Bool {
        if case .captured = self { return true }
        return false
    }
}

private final class AppleContainerDrainRace: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(
        _ value: Bool,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

private final class AppleContainerPipe: @unchecked Sendable {
    let writer: FileHandle
    let stream: AsyncStream<Data>

    private let reader: FileHandle
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var finished = false
    private var readSource: (any DispatchSourceRead)!

    init() {
        let pipe = Pipe()
        reader = pipe.fileHandleForReading
        writer = pipe.fileHandleForWriting
        let pair = AsyncStream<Data>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: reader.fileDescriptor,
            queue: DispatchQueue.global(qos: .utility))
        readSource.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        continuation.onTermination = { [weak self] _ in
            self?.finish()
        }
        readSource.resume()
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        readSource.cancel()
        continuation.finish()
    }

    private func readAvailableBytes() {
        let byteCount = max(1, min(Int(readSource.data), 64 * 1_024))
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let count = bytes.withUnsafeMutableBytes { buffer in
            unsafe Darwin.read(
                reader.fileDescriptor,
                buffer.baseAddress,
                buffer.count)
        }
        if count > 0 {
            continuation.yield(Data(bytes.prefix(count)))
            return
        }
        if count == -1, errno == EAGAIN || errno == EINTR {
            return
        }
        finish()
    }
}

private func collectAppleContainerOutput(
    _ chunks: AsyncStream<Data>,
    limit: Int?,
    mirror: FileDescriptor?,
    sink: CommandOutputSink
) async throws -> [UInt8] {
    var captured: [UInt8] = []
    for await chunk in chunks {
        try Task.checkCancellation()
        let bytes = [UInt8](chunk)
        if let limit {
            guard captured.count <= limit,
                bytes.count <= limit - captured.count
            else {
                throw RuntimeFailure.outputLimitExceeded(limit)
            }
            captured += bytes
        }
        try await sink.write(bytes, mirror: mirror)
    }
    try await sink.finish()
    return captured
}
#else
public func appleContainerBackendHealth() async throws
    -> AppleContainerBackendHealth
{
    throw OCIExecutorFailure.unsupportedRunner(.current)
}
#endif
