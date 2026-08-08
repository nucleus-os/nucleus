import ColliderCore
import ColliderRuntime
import Foundation
import Logging
import SystemPackage

#if os(macOS)
import ContainerAPIClient
import ContainerBuild
import ContainerCommands
import ContainerResource
import ContainerizationOCI
#endif

#if os(macOS)
enum AppleContainerFailure: Error, CustomStringConvertible {
    case builderReleaseFailed(operation: String, cleanup: String)
    case cleanupFailed(name: String, reason: String)
    case invalidImageDigest
    case suspensionFailed(name: String, reason: String)
    case unsupportedTerminalOutput

    var description: String {
        switch self {
        case .builderReleaseFailed(let operation, let cleanup):
            "Apple container image preparation failed (\(operation)) and the "
                + "ephemeral builder could not be released (\(cleanup))"
        case .cleanupFailed(let name, let reason):
            "Apple container cleanup failed for \(name): \(reason)"
        case .invalidImageDigest:
            "Apple container image API did not return one OCI digest"
        case .suspensionFailed(let name, let reason):
            "Apple container suspension failed for \(name): \(reason)"
        case .unsupportedTerminalOutput:
            "Apple container lifecycle execution does not support terminal output"
        }
    }
}

public struct AppleContainerRuntimeBackend: OCIRuntimeBackend {
    public init() {}

    public func prepareImage(
        _ preparation: OCIImagePreparation
    ) async throws -> String {
        try validateRunner()
        let suspension = AppleContainerSuspension(
            client: ContainerClient(),
            name: Builder.builderContainerId)
        do {
            let imageID = try await AppleContainerImageBuilder().build(preparation)
            try await suspension.stopAndVerify()
            return imageID
        } catch {
            let preparationError = error
            do {
                try await suspension.stopAndVerify()
            } catch {
                throw AppleContainerFailure.builderReleaseFailed(
                    operation: String(describing: preparationError),
                    cleanup: String(describing: error))
            }
            throw preparationError
        }
    }

    public func execute(
        _ request: OCIRuntimeExecutionRequest
    ) async throws -> OCIRuntimeExecutionOutcome {
        try validateRunner()
        let name = appleContainerName(for: request.execution)
        return try await AppleContainerLifecycle(
            cancellation: request.cancellation,
            configuration: request.configuration
        ).execute(
            request.execution,
            name: name,
            imageReference: request.imageReference,
            temporaryDirectory: request.temporaryDirectory,
            output: request.output,
            logging: request.logging,
            stage: request.stage)
    }

    public func health() async throws -> OCIRuntimeHealth {
        try validateRunner()
        let health = try await ClientHealthCheck.ping()
        return OCIRuntimeHealth(
            appRoot: health.appRoot,
            installRoot: health.installRoot,
            apiServerVersion: health.apiServerVersion,
            apiServerCommit: health.apiServerCommit,
            apiServerBuild: health.apiServerBuild,
            apiServerAppName: health.apiServerAppName)
    }

    public func network(named name: String) async throws
        -> OCIRuntimeNetworkState
    {
        try validateRunner()
        let network = try await NetworkClient().get(id: name)
        return OCIRuntimeNetworkState(
            name: network.configuration.name,
            mode: network.configuration.mode.rawValue)
    }

    public func diskUsage() async throws -> OCIRuntimeDiskUsage {
        try validateRunner()
        let usage = try await ClientDiskUsage.get()
        func project(_ value: ResourceUsage) -> OCIRuntimeResourceUsage {
            OCIRuntimeResourceUsage(
                active: value.active,
                reclaimable: value.reclaimable,
                sizeInBytes: value.sizeInBytes,
                total: value.total)
        }
        return OCIRuntimeDiskUsage(
            containers: project(usage.containers),
            images: project(usage.images),
            volumes: project(usage.volumes))
    }

    public func pruneImages() async throws {
        try validateRunner()
        for image in try await ClientImage.list() {
            let reference = try ContainerizationOCI.Reference.parse(image.reference)
            guard reference.tag == nil else { continue }
            try await ClientImage.delete(
                reference: image.reference,
                garbageCollect: false)
        }
        _ = try await ClientImage.cleanUpOrphanedBlobs()
    }

    private func validateRunner() throws {
        guard RunnerPlatform.current.operatingSystem == .macOS,
            RunnerPlatform.current.architecture == .arm64
        else {
            throw OCIExecutorFailure.unsupportedRunner(.current)
        }
    }
}

func appleContainerName(for execution: OCIExecution) -> String {
    execution.hostname + "-" + UUID().uuidString.prefix(12).lowercased()
}

struct AppleContainerLifecycle: Sendable {
    private let client: ContainerClient
    private let cancellation: RuntimeCancellation
    private let configuration: OCIRuntimeConfiguration

    init(
        client: ContainerClient = ContainerClient(),
        cancellation: RuntimeCancellation,
        configuration: OCIRuntimeConfiguration
    ) {
        self.client = client
        self.cancellation = cancellation
        self.configuration = configuration
    }

    func execute(
        _ execution: OCIExecution,
        name: String,
        imageReference: String,
        temporaryDirectory: FilePath?,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?
    ) async throws -> OCIRuntimeExecutionOutcome {
        let lifecycleStart = ContinuousClock().now
        let interruptionCleanup = AppleContainerCleanup(client: client, name: name)
        let operation = Task {
            try await executeCreatedContainer(
                execution,
                name: name,
                imageReference: imageReference,
                temporaryDirectory: temporaryDirectory,
                output: output,
                logging: logging,
                stage: stage)
        }
        let cancellationRegistration = await cancellation.register {
            operation.cancel()
            Task.detached {
                try? await interruptionCleanup.deleteAndVerify()
            }
        }
        do {
            let created = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
                Task.detached {
                    try? await interruptionCleanup.deleteAndVerify()
                }
            }
            try Task.checkCancellation()
            if await cancellation.wasInterrupted() {
                throw CancellationError()
            }
            let cleanupStart = ContinuousClock().now
            try await AppleContainerCleanup(client: client, name: name).deleteAndVerify()
            let cleanupDuration = elapsedNanoseconds(since: cleanupStart)
            await cancellation.unregister(cancellationRegistration)
            return OCIRuntimeExecutionOutcome(
                result: created.result,
                timings: OCIExecutionTimings(
                    configurationDurationNanoseconds:
                        created.configurationDurationNanoseconds,
                    creationDurationNanoseconds:
                        created.creationDurationNanoseconds,
                    bootstrapDurationNanoseconds:
                        created.bootstrapDurationNanoseconds,
                    processDurationNanoseconds:
                        created.processDurationNanoseconds,
                    cleanupDurationNanoseconds: cleanupDuration,
                    totalDurationNanoseconds: elapsedNanoseconds(
                        since: lifecycleStart)))
        } catch {
            operation.cancel()
            _ = try? await operation.value
            do {
                try await AppleContainerCleanup(client: client, name: name)
                    .deleteAndVerify()
            } catch let cleanupError {
                await cancellation.unregister(cancellationRegistration)
                throw AppleContainerFailure.cleanupFailed(
                    name: name,
                    reason: String(describing: cleanupError))
            }
            await cancellation.unregister(cancellationRegistration)
            throw error
        }
    }

    private func executeCreatedContainer(
        _ execution: OCIExecution,
        name: String,
        imageReference: String,
        temporaryDirectory: FilePath?,
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?
    ) async throws -> CreatedContainerExecution {
        let configurationStart = ContinuousClock().now
        let flags = appleContainerFlags(
            execution,
            name: name,
            temporaryDirectory: temporaryDirectory,
            configuration: configuration)
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
            log: Logger(label: configuration.loggerLabel) { _ in
                SwiftLogNoOpLogHandler()
            })
        let configurationDuration = elapsedNanoseconds(since: configurationStart)

        try Task.checkCancellation()
        let creationStart = ContinuousClock().now
        try await client.create(
            configuration: configuration,
            options: .default,
            kernel: kernel,
            initImage: initImage)
        let creationDuration = elapsedNanoseconds(since: creationStart)

        let bootstrapStart = ContinuousClock().now
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
            let bootstrapDuration = elapsedNanoseconds(since: bootstrapStart)
            let processStart = ContinuousClock().now
            let status = try await process.wait()
            let result = try await outputSession.finish(status: status)
            return CreatedContainerExecution(
                result: result,
                configurationDurationNanoseconds: configurationDuration,
                creationDurationNanoseconds: creationDuration,
                bootstrapDurationNanoseconds: bootstrapDuration,
                processDurationNanoseconds: elapsedNanoseconds(
                    since: processStart))
        } catch {
            try? outputSession.closeWriters()
            await outputSession.cancel()
            throw error
        }
    }
}

private struct CreatedContainerExecution: Sendable {
    let result: CommandResult
    let configurationDurationNanoseconds: UInt64
    let creationDurationNanoseconds: UInt64
    let bootstrapDurationNanoseconds: UInt64
    let processDurationNanoseconds: UInt64
}

struct AppleContainerFlags {
    let process: Flags.Process
    let management: Flags.Management
    let resource: Flags.Resource
}

func appleContainerFlags(
    _ execution: OCIExecution,
    name: String,
    temporaryDirectory: FilePath?,
    configuration: OCIRuntimeConfiguration = .engineDefault
) -> AppleContainerFlags {
    var mounts = execution.mounts.map { mount in
        var value =
            "type=bind,source=\(mount.source),target=\(mount.target)"
        if mount.access == .readOnly {
            value += ",readonly"
        }
        return value
    }
    var temporaryFilesystems = [configuration.guestHome]
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
            "nproc=\(execution.resourceLimits.processCount):\(execution.resourceLimits.processCount)",
            "nofile=\(execution.resourceLimits.openFileCount):\(execution.resourceLimits.openFileCount)",
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
        dnsDisabled: true,
        entrypoint: nil,
        initImage: nil,
        kernel: nil,
        kernelArgs: [],
        labels: configuration.managedLabels,
        maskedPaths: [],
        mounts: mounts,
        name: name,
        networks: [configuration.isolatedNetwork],
        os: "linux",
        platform: "linux/arm64",
        publishPorts: [],
        publishSockets: [],
        readOnly: true,
        readonlyPaths: [],
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
        throw AppleContainerFailure.cleanupFailed(
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
        throw AppleContainerFailure.suspensionFailed(
            name: name,
            reason: lastError.map(String.init(describing:))
                ?? "container did not reach the stopped state")
    }
}

private final class AppleContainerOutputSession: @unchecked Sendable {
    let stdio: [FileHandle?]

    private let pipes: [AppleContainerPipe]
    private let outputTask: Task<[UInt8], any Error>
    private let errorTask: Task<[UInt8], any Error>?

    init(
        output: CommandSpec.Output,
        logging: CommandLogging?,
        stage: TaskID?
    ) throws {
        guard output != .terminal else {
            throw AppleContainerFailure.unsupportedTerminalOutput
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
            let pipe = try AppleContainerPipe()
            stdio = [nil, pipe.writer, pipe.writer]
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

        let stdout = try AppleContainerPipe()
        let stderr = try AppleContainerPipe()
        stdio = [nil, stdout.writer, stderr.writer]
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
        for pipe in pipes {
            try pipe.closeWriter()
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

    private let reader: FileDescriptor
    private let writerDescriptor: FileDescriptor
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var finished = false
    private var writerClosed = false
    private var readSource: (any DispatchSourceRead)!

    init() throws {
        let pipe = try FileDescriptor.pipe(options: [.closeOnExec])
        reader = pipe.readEnd
        writerDescriptor = pipe.writeEnd
        writer = FileHandle(
            fileDescriptor: pipe.writeEnd.rawValue,
            closeOnDealloc: false)
        let pair = AsyncStream<Data>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: reader.rawValue,
            queue: DispatchQueue.global(qos: .utility))
        readSource.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        continuation.onTermination = { [weak self] _ in
            self?.finish()
        }
        readSource.setCancelHandler { [reader] in
            try? reader.close()
        }
        readSource.resume()
    }

    func closeWriter() throws {
        lock.lock()
        guard !writerClosed else {
            lock.unlock()
            return
        }
        writerClosed = true
        lock.unlock()
        try writerDescriptor.close()
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
        let count: Int
        do {
            count = try bytes.withUnsafeMutableBytes {
                try unsafe reader.read(into: $0, retryOnInterrupt: false)
            }
        } catch let error as Errno
            where error == .interrupted || error == .wouldBlock
        {
            return
        } catch {
            finish()
            return
        }
        if count > 0 {
            continuation.yield(Data(bytes.prefix(count)))
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
#endif
