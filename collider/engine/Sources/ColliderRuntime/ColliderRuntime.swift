import ColliderCore
import ColliderDownloads
import ColliderPersistence
import ColliderPlatformC
import Foundation
import Subprocess
import Synchronization
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct CommandLogging: Sendable {
    public let registry: RunRegistry
    public let run: RunHandle

    public init(registry: RunRegistry, run: RunHandle) {
        self.registry = registry
        self.run = run
    }
}

public struct OCIRuntimeConfiguration: Hashable, Sendable {
    public let isolatedNetwork: String
    public let guestHome: String
    public let managedLabels: [String]
    public let loggerLabel: String

    public init(
        isolatedNetwork: String,
        guestHome: String,
        managedLabels: [String],
        loggerLabel: String
    ) {
        precondition(!isolatedNetwork.isEmpty)
        precondition(guestHome.hasPrefix("/"))
        precondition(!managedLabels.isEmpty)
        precondition(!loggerLabel.isEmpty)
        self.isolatedNetwork = isolatedNetwork
        self.guestHome = guestHome
        self.managedLabels = managedLabels
        self.loggerLabel = loggerLabel
    }

    public static let engineDefault = OCIRuntimeConfiguration(
        isolatedNetwork: "collider-internal",
        guestHome: "/home/collider",
        managedLabels: ["dev.collider.managed=true"],
        loggerLabel: "dev.collider.apple-container")
}

public actor ColliderRuntime {
    let logging: CommandLogging?
    let downloads: ColliderDownloads
    var taskOutputPresentation: TaskOutputPresentation?
    public let cancellation: RuntimeCancellation
    let ociConfiguration: OCIRuntimeConfiguration
    let ociBackend: any OCIRuntimeBackend

    public init(
        logging: CommandLogging? = nil,
        cancellation: RuntimeCancellation = RuntimeCancellation()
    ) {
        self.init(
            logging: logging,
            cancellation: cancellation,
            downloadCacheRoot: defaultColliderDownloadCacheRoot(),
            ociConfiguration: .engineDefault,
            ociBackend: nil)
    }

    public init(
        logging: CommandLogging? = nil,
        cancellation: RuntimeCancellation = RuntimeCancellation(),
        downloadCacheRoot: FilePath,
        ociConfiguration: OCIRuntimeConfiguration,
        ociBackend: (any OCIRuntimeBackend)? = nil
    ) {
        self.logging = logging
        downloads = ColliderDownloads(cacheRoot: downloadCacheRoot) { progress in
            guard let logging else { return }
            let expected = progress.expectedBytes.map(String.init) ?? "unknown"
            Task {
                try? await logging.registry.record(
                    kind: .downloadProgress,
                    message:
                        "\(progress.digest) \(progress.receivedBytes)/\(expected)",
                    in: logging.run)
            }
        }
        self.cancellation = cancellation
        self.ociConfiguration = ociConfiguration
        self.ociBackend = ociBackend ?? UnsupportedOCIRuntimeBackend()
    }

    public func ociRuntimeHealth() async throws -> OCIRuntimeHealth {
        try await ociBackend.health()
    }

    public func ociRuntimeNetwork(
        named name: String
    ) async throws -> OCIRuntimeNetworkState {
        try await ociBackend.network(named: name)
    }

    public func ociRuntimeDiskUsage() async throws -> OCIRuntimeDiskUsage {
        try await ociBackend.diskUsage()
    }

    public func pruneOCIImages() async throws {
        try await ociBackend.pruneImages()
    }

    public func execute(_ command: CommandSpec) async throws -> CommandResult {
        try await execute(command, stage: nil, onStarted: nil)
    }

    public func execute<Action: ColliderAction>(
        _ action: Action
    ) async throws {
        _ = try await execute(try AnyColliderAction(action), stage: nil)
    }

    func execute(
        _ action: AnyColliderAction,
        stage: TaskID?
    ) async throws -> TaskExecutionObservations {
        let recordedObservations = Mutex(TaskExecutionObservations())
        let context = ActionContext(
            files: actionFileSystem().scoped(to: action.requirements.effects),
            cancellation: ActionCancellation {
                try Task.checkCancellation()
            },
            logger: ActionLogger { message in
                guard let logging = self.logging, let stage else { return }
                try await logging.registry.appendLog(
                    Array((message + "\n").utf8),
                    stage: stage,
                    in: logging.run)
            },
            commands: ActionCommandExecutor { command in
                try await self.execute(command, stage: stage)
            },
            downloads: ActionDownloader { specification, path in
                try await self.downloads.download(specification, to: path)
            },
            containers: ActionContainerExecutor(
                prepareImage: { preparation in
                    try await self.prepareOCIImage(preparation, stage: stage)
                },
                run: { execution in
                    let outcome = try await self.executeOCI(execution, stage: stage)
                    let result = outcome.result
                    let imageIdentifier = try String(
                        contentsOfFile: execution.imageID.string,
                        encoding: .utf8)
                    guard
                        let labelledDigest = validOCIImageDigest(
                            in: imageIdentifier),
                        let imageDigest = ArtifactDigest(
                            sha256Hex: String(
                                labelledDigest.dropFirst("sha256:".count)))
                    else {
                        throw RuntimeFailure.invalidOutput(
                            "builder image ID is missing or invalid")
                    }
                    recordedObservations.withLock {
                        $0.containerExecutions.append(
                            OCIExecutionObservation(
                                imageDigest: imageDigest,
                                executionPlatform: execution.executionPlatform,
                                artifactTarget: execution.artifactTarget,
                                userPolicy: execution.userPolicy,
                                capabilityPolicy: execution.capabilityPolicy,
                                privilegePolicy: execution.privilegePolicy,
                                processFilesystemPolicy:
                                    execution.processFilesystemPolicy,
                                intelBinaryTranslationPolicy:
                                    execution.intelBinaryTranslationPolicy,
                                resourceLimits: execution.resourceLimits,
                                status: result.status,
                                timings: outcome.timings))
                    }
                    return result
                })
        )
        try await action.execute(in: context)
        return recordedObservations.withLock { $0 }
    }

    public func download(
        _ specification: DownloadSpec,
        to candidate: FilePath
    ) async throws {
        try await downloads.download(specification, to: candidate)
    }

    public func shutdown() async {
        await downloads.shutdown()
    }

    public func execute(
        _ command: CommandSpec,
        stage: TaskID?,
        onStarted: (@Sendable (Int32) async -> Void)? = nil
    ) async throws -> CommandResult {
        let process = CommandProcessCancellation()
        let operation = Task {
            try await self.executeRegistered(
                command,
                stage: stage,
                onStarted: onStarted,
                process: process)
        }
        let shutdown = Mutex<Task<Void, Never>?>(nil)
        let beginShutdown: @Sendable () -> Void = {
            shutdown.withLock { task in
                guard task == nil else { return }
                task = Task {
                    process.requestTermination()
                    await waitForProcessCompletion(
                        process.completion,
                        gracePeriod: .seconds(2))
                    operation.cancel()
                    _ = try? await operation.value
                }
            }
        }
        let registration = await cancellation.register(beginShutdown)
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                beginShutdown()
            }
            try Task.checkCancellation()
            await cancellation.unregister(registration)
            return result
        } catch {
            beginShutdown()
            if let task = shutdown.withLock({ $0 }) {
                await task.value
            }
            await cancellation.unregister(registration)
            throw error
        }
    }

    public nonisolated func actionFileSystem() -> ActionFileSystem {
        let inspect:
            @Sendable (
                FilePath, Bool
            ) throws -> ActionFileSystem.Metadata? = { path, followTargetSymlink in
                let value: Stat
                do {
                    value = try path.stat(
                        followTargetSymlink: followTargetSymlink)
                } catch let error as Errno {
                    guard error == Errno.noSuchFileOrDirectory else {
                        throw error
                    }
                    return nil
                }
                let type: ActionFileSystem.FileType =
                    switch value.type {
                    case .regular: .regular
                    case .directory: .directory
                    case .symbolicLink: .symbolicLink
                    default: .other
                    }
                let permissions = UInt16(truncatingIfNeeded: value.permissions.rawValue)
                return ActionFileSystem.Metadata(
                    type: type,
                    ownerExecutable: permissions & 0o100 != 0,
                    size: UInt64(max(0, value.size)),
                    permissions: permissions)
            }
        return ActionFileSystem(
            metadata: { path in
                try inspect(path, true)
            },
            metadataNoFollow: { path in
                try inspect(path, false)
            },
            contentsEqual: { first, second in
                let firstResolved = URL(fileURLWithPath: first.string)
                    .resolvingSymlinksInPath().path
                let secondResolved = URL(fileURLWithPath: second.string)
                    .resolvingSymlinksInPath().path
                return FileManager.default.contentsEqual(
                    atPath: firstResolved,
                    andPath: secondResolved)
            },
            createDirectory: { path in
                try FileManager.default.createDirectory(
                    atPath: path.string,
                    withIntermediateDirectories: true)
            },
            copy: { source, destination in
                let resolved = URL(fileURLWithPath: source.string)
                    .resolvingSymlinksInPath().path
                try DurableFile.copy(
                    from: FilePath(resolved),
                    to: destination)
            },
            copyTree: { source, destination in
                let resolved = URL(fileURLWithPath: source.string)
                    .resolvingSymlinksInPath()
                try FileManager.default.createDirectory(
                    at: URL(
                        fileURLWithPath: destination.removingLastComponent().string),
                    withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: resolved,
                    to: URL(fileURLWithPath: destination.string))
            },
            read: { path in
                Array(try Data(contentsOf: URL(fileURLWithPath: path.string)))
            },
            readPrefix: { path, count in
                let handle = try FileHandle(
                    forReadingFrom: URL(fileURLWithPath: path.string))
                defer { try? handle.close() }
                return Array(try handle.read(upToCount: count) ?? Data())
            },
            readSymbolicLink: { path in
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: path.string)
            },
            remove: { path in
                guard (try? path.stat(followTargetSymlink: false)) != nil else {
                    return
                }
                try FileManager.default.removeItem(atPath: path.string)
            },
            move: { source, destination in
                try FileManager.default.moveItem(
                    atPath: source.string,
                    toPath: destination.string)
            },
            listRecursively: { root in
                guard
                    let enumerator = FileManager.default.enumerator(
                        atPath: root.string)
                else { return [] }
                return try enumerator.compactMap { value -> ActionFileSystem.Entry? in
                    guard let relative = value as? String else { return nil }
                    let path = root.appending(relative)
                    guard let metadata = try inspect(path, false) else { return nil }
                    return ActionFileSystem.Entry(
                        path: path,
                        relativePath: relative,
                        metadata: metadata)
                }
            },
            digestFile: { try ArtifactHasher.digest(file: $0) },
            digestTree: {
                try ArtifactHasher.digest(tree: $0, excluding: $1)
            },
            publishGeneration: {
                try GenerationPublisher.publish(
                    candidate: $0,
                    generation: $1,
                    active: $2)
            },
            pruneDirectories: { try DirectoryLifecycle.prune($0) },
            replaceSymlink: { path, target in
                if FileManager.default.fileExists(atPath: path.string)
                    || (try? FileManager.default.destinationOfSymbolicLink(
                        atPath: path.string)) != nil
                {
                    try FileManager.default.removeItem(atPath: path.string)
                }
                try FileManager.default.createDirectory(
                    atPath: path.removingLastComponent().string,
                    withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    atPath: path.string,
                    withDestinationPath: target)
            },
            setPermissions: { path, permissions in
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: path.string)
            },
            write: { bytes, path in
                try DurableFile.write(Data(bytes), to: path)
            })
    }

    private func executeRegistered(
        _ command: CommandSpec,
        stage: TaskID?,
        onStarted: (@Sendable (Int32) async -> Void)?,
        process: CommandProcessCancellation
    ) async throws -> CommandResult {
        guard let timeout = command.timeoutNanoseconds else {
            do {
                let result = try await executeWithoutTimeout(
                    command,
                    stage: stage,
                    onStarted: onStarted,
                    process: process)
                process.finished()
                return result
            } catch {
                process.finished()
                throw error
            }
        }
        return try await withThrowingTaskGroup(
            of: TimedExecutionOutcome.self,
            returning: CommandResult.self
        ) { group in
            group.addTask {
                do {
                    let result = try await self.executeWithoutTimeout(
                        command,
                        stage: stage,
                        onStarted: onStarted,
                        process: process)
                    process.finished()
                    return .command(.success(result))
                } catch {
                    process.finished()
                    return .command(.failure(RuntimeExecutionFailure(error)))
                }
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .nanoseconds(Int64(timeout)))
                return .deadline
            }
            let first = try await group.next()!
            switch first {
            case .command(let outcome):
                group.cancelAll()
                switch outcome {
                case .success(let result):
                    return result
                case .failure(let failure):
                    throw failure.underlying
                }
            case .deadline:
                process.requestTermination()
                await waitForProcessCompletion(
                    process.completion,
                    gracePeriod: .seconds(2))
                group.cancelAll()
                return CommandResult(status: 0, timedOut: true)
            }
        }
    }

    private func executeWithoutTimeout(
        _ command: CommandSpec,
        stage: TaskID?,
        onStarted: (@Sendable (Int32) async -> Void)?,
        process: CommandProcessCancellation
    ) async throws -> CommandResult {
        let command =
            if let taskOutputPresentation {
                command.withOutput(
                    taskOutputPresentation.output(for: command.output))
            } else {
                command
            }
        let executable: Subprocess.Executable =
            switch command.executable {
            case .named(let name): .name(name)
            case .operationalNamed(let name): .name(name)
            case .path(let path): .path(.init(path.string))
            case .artifact(let reference): .path(.init(reference.path.string))
            case .taskOutput(let path): .path(.init(path.string))
            }
        var validatedEnvironment: [Subprocess.Environment.Key: String] = [:]
        for (name, value) in command.environment {
            guard !name.utf8.contains(0), !name.contains("="),
                name.utf8.first.map({ !(48...57).contains($0) }) ?? true,
                let key = Subprocess.Environment.Key(rawValue: name)
            else {
                throw RuntimeFailure.invalidEnvironmentKey(name)
            }
            guard !value.utf8.contains(0) else {
                throw RuntimeFailure.invalidEnvironmentValue(key: name)
            }
            validatedEnvironment[key] = value
        }
        let environment = Subprocess.Environment.custom(validatedEnvironment)
        var platform = Subprocess.PlatformOptions()
        #if !os(Windows)
        platform.processGroupID = command.output == .terminal ? nil : 0
        platform.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: command.output != .terminal,
                allowedDurationToNextStep: .seconds(2))
        ]
        #endif

        switch command.input {
        case .none:
            return try await execute(
                command,
                executable: executable,
                environment: environment,
                platform: platform,
                input: NoInput.none,
                stage: stage,
                onStarted: onStarted,
                process: process)
        case .terminal:
            return try await execute(
                command,
                executable: executable,
                environment: environment,
                platform: platform,
                input: FileDescriptorInput.standardInput,
                stage: stage,
                onStarted: onStarted,
                process: process)
        case .bytes(let bytes):
            return try await execute(
                command,
                executable: executable,
                environment: environment,
                platform: platform,
                input: ArrayInput.array(bytes),
                stage: stage,
                onStarted: onStarted,
                process: process)
        }
    }

    private func execute<Input: InputProtocol>(
        _ command: CommandSpec,
        executable: Subprocess.Executable,
        environment: Subprocess.Environment,
        platform: Subprocess.PlatformOptions,
        input: consuming Input,
        stage: TaskID?,
        onStarted: (@Sendable (Int32) async -> Void)?,
        process: CommandProcessCancellation
    ) async throws -> CommandResult {
        if command.output == .terminal {
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(command.arguments),
                environment: environment,
                workingDirectory: .init(command.workingDirectory.string),
                platformOptions: platform,
                input: input,
                output: .currentStandardOutput,
                error: .currentStandardError
            ) { execution in
                process.started(
                    processIdentifier: execution.processIdentifier.value,
                    processGroup: false)
                await onStarted?(execution.processIdentifier.value)
            }
            return CommandResult(status: statusCode(result.terminationStatus))
        }

        return try await executeStreaming(
            command,
            executable: executable,
            environment: environment,
            platform: platform,
            input: input,
            logging: logging,
            stage: stage,
            onStarted: onStarted,
            process: process)
    }

    private func executeStreaming<Input: InputProtocol>(
        _ command: CommandSpec,
        executable: Subprocess.Executable,
        environment: Subprocess.Environment,
        platform: Subprocess.PlatformOptions,
        input: consuming Input,
        logging: CommandLogging?,
        stage: TaskID?,
        onStarted: (@Sendable (Int32) async -> Void)?,
        process: CommandProcessCancellation
    ) async throws -> CommandResult {
        let file: FilePath? =
            switch command.output {
            case .file(let path): path
            default: nil
            }
        let sink = try CommandOutputSink(
            logging: file == nil ? logging : nil,
            stage: stage,
            file: file)
        let commandResult: CommandResult
        do {
            switch command.output {
            case .combined(let limit):
                let result = try await Subprocess.run(
                    executable,
                    arguments: Arguments(command.arguments),
                    environment: environment,
                    workingDirectory: .init(command.workingDirectory.string),
                    platformOptions: platform,
                    input: input,
                    output: .sequence,
                    error: .combinedWithOutput
                ) { execution in
                    process.started(
                        processIdentifier: execution.processIdentifier.value,
                        processGroup: true)
                    let registration = await self.cancellation.registerProcessGroup(
                        execution.processIdentifier.value)
                    await onStarted?(execution.processIdentifier.value)
                    do {
                        let bytes = try await collect(
                            execution.standardOutput,
                            limit: limit,
                            mirror: nil,
                            sink: sink)
                        await self.cancellation.unregisterProcessGroup(registration)
                        return bytes
                    } catch {
                        await self.cancellation.unregisterProcessGroup(registration)
                        throw error
                    }
                }
                commandResult = CommandResult(
                    status: statusCode(result.terminationStatus),
                    standardOutput: String(decoding: result.closureResult, as: UTF8.self))
            case .inherited, .logged, .file, .captured:
                let captureLimit: Int? =
                    switch command.output {
                    case .captured(let limit): limit
                    default: nil
                    }
                let result = try await Subprocess.run(
                    executable,
                    arguments: Arguments(command.arguments),
                    environment: environment,
                    workingDirectory: .init(command.workingDirectory.string),
                    platformOptions: platform,
                    input: input,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    process.started(
                        processIdentifier: execution.processIdentifier.value,
                        processGroup: true)
                    let registration = await self.cancellation.registerProcessGroup(
                        execution.processIdentifier.value)
                    await onStarted?(execution.processIdentifier.value)
                    do {
                        let bytes = try await withThrowingTaskGroup(
                            of: StreamResult.self,
                            returning: [UInt8].self
                        ) { group in
                            group.addTask {
                                StreamResult(
                                    stream: .stdout,
                                    bytes: try await collect(
                                        execution.standardOutput,
                                        limit: captureLimit,
                                        mirror: command.output == .inherited
                                            ? .standardOutput : nil,
                                        sink: sink))
                            }
                            group.addTask {
                                StreamResult(
                                    stream: .stderr,
                                    bytes: try await collect(
                                        execution.standardError,
                                        limit: nil,
                                        mirror: command.output == .logged
                                            || file != nil
                                            ? nil : .standardError,
                                        sink: sink))
                            }
                            var captured: [UInt8] = []
                            for try await result in group where result.stream == .stdout {
                                captured = result.bytes
                            }
                            return captured
                        }
                        await self.cancellation.unregisterProcessGroup(registration)
                        return bytes
                    } catch {
                        await self.cancellation.unregisterProcessGroup(registration)
                        throw error
                    }
                }
                commandResult = CommandResult(
                    status: statusCode(result.terminationStatus),
                    standardOutput: String(decoding: result.closureResult, as: UTF8.self))
            case .terminal:
                preconditionFailure("terminal commands are executed with inherited descriptors")
            }
        } catch {
            try? await sink.finish()
            throw error
        }
        try await sink.finish()
        return commandResult
    }
}

private func defaultColliderDownloadCacheRoot() -> FilePath {
    FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("collider/downloads", isDirectory: true).path)
}

enum TaskOutputPresentation: Sendable {
    case stream
    case quiet

    func output(for output: CommandSpec.Output) -> CommandSpec.Output {
        switch (self, output) {
        case (.stream, .logged):
            .inherited
        case (.quiet, .inherited):
            .logged
        case (.stream, .inherited), (.stream, .terminal), (.stream, .file),
            (.stream, .captured), (.stream, .combined), (.quiet, .logged),
            (.quiet, .terminal), (.quiet, .file), (.quiet, .captured),
            (.quiet, .combined):
            output
        }
    }
}

extension CommandSpec {
    fileprivate func withOutput(_ output: Output) -> CommandSpec {
        guard output != self.output else { return self }
        return CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            input: input,
            output: output,
            timeoutNanoseconds: timeoutNanoseconds)
    }
}

private enum TimedExecutionOutcome: Sendable {
    case command(Result<CommandResult, RuntimeExecutionFailure>)
    case deadline
}

private struct RuntimeExecutionFailure: Error, @unchecked Sendable {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }
}

private final class CommandProcessCancellation: Sendable {
    private struct Target: Sendable {
        let processIdentifier: Int32
        let processGroup: Bool
    }

    private enum State: Sendable {
        case starting(terminationRequested: Bool)
        case running(Target, terminationRequested: Bool)
        case finished
    }

    private let state = Mutex<State>(.starting(terminationRequested: false))
    let completion: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        completion = pair.stream
        completionContinuation = pair.continuation
    }

    func started(
        processIdentifier: Int32,
        processGroup: Bool
    ) {
        let target = Target(
            processIdentifier: processIdentifier,
            processGroup: processGroup)
        let terminate = state.withLock { state -> Bool in
            switch state {
            case .starting(let terminationRequested):
                state = .running(
                    target,
                    terminationRequested: terminationRequested)
                return terminationRequested
            case .running, .finished:
                return false
            }
        }
        if terminate {
            terminateProcess(target)
        }
    }

    func requestTermination() {
        let target = state.withLock { state -> Target? in
            switch state {
            case .starting:
                state = .starting(terminationRequested: true)
                return nil
            case .running(let target, _):
                state = .running(target, terminationRequested: true)
                return target
            case .finished:
                return nil
            }
        }
        if let target {
            terminateProcess(target)
        }
    }

    func finished() {
        let shouldFinish = state.withLock { state -> Bool in
            guard case .finished = state else {
                state = .finished
                return true
            }
            return false
        }
        if shouldFinish {
            completionContinuation.finish()
        }
    }

    private func terminateProcess(_ target: Target) {
        #if !os(Windows)
        let identifier =
            target.processGroup
            ? -target.processIdentifier
            : target.processIdentifier
        _ = kill(identifier, Signal.terminate.rawValue)
        #else
        _ = target
        #endif
    }
}

private func waitForProcessCompletion(
    _ completion: AsyncStream<Void>,
    gracePeriod: Duration
) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in completion {
                return
            }
        }
        group.addTask {
            try? await ContinuousClock().sleep(for: gracePeriod)
        }
        await group.next()
        group.cancelAll()
    }
}

private enum OutputStream: Sendable, Equatable { case stdout, stderr }

private struct StreamResult: Sendable {
    let stream: OutputStream
    let bytes: [UInt8]
}

package actor CommandOutputSink {
    let logging: CommandLogging?
    let stage: TaskID?
    var file: FileDescriptor?

    package init(
        logging: CommandLogging?,
        stage: TaskID?,
        file path: FilePath?
    ) throws {
        self.logging = logging
        self.stage = stage
        file =
            if let path {
                try FileDescriptor.open(
                    path,
                    .writeOnly,
                    options: [.create, .truncate, .closeOnExec],
                    permissions: .ownerReadWrite)
            } else {
                nil
            }
    }

    package func write(
        _ bytes: [UInt8],
        mirror: FileDescriptor?
    ) async throws {
        if let logging {
            try await logging.registry.appendLog(bytes, stage: stage, in: logging.run)
        }
        if let file {
            try file.writeAll(CredentialScrubber.bytes(bytes))
        }
        if let mirror { try mirror.writeAll(bytes) }
    }

    package func finish() throws {
        guard let file else {
            return
        }
        self.file = nil
        do {
            guard collider_sync_file(file.rawValue) == 0 else {
                throw Errno(rawValue: errno)
            }
        } catch {
            try? file.close()
            throw error
        }
        try file.close()
    }
}

private func collect(
    _ sequence: SubprocessOutputSequence,
    limit: Int?,
    mirror: FileDescriptor?,
    sink: CommandOutputSink
) async throws -> [UInt8] {
    var captured: [UInt8] = []
    for try await chunk in sequence {
        let bytes = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
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
    return captured
}

private func statusCode(_ status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code): code
    #if !os(Windows)
    case .signaled(let signal): 128 + signal
    #endif
    }
}
