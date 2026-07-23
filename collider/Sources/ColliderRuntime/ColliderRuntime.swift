import ColliderCore
import ColliderDownloads
import Subprocess
import Synchronization
import SystemPackage

public struct CommandLogging: Sendable {
    public let registry: RunRegistry
    public let run: RunHandle

    public init(registry: RunRegistry, run: RunHandle) {
        self.registry = registry
        self.run = run
    }
}

public actor ColliderRuntime {
    let logging: CommandLogging?
    let downloads: ColliderDownloads
    var toolIdentityCache: [String: (FilePath, ArtifactDigest)] = [:]
    public let cancellation: RuntimeCancellation

    public init(
        logging: CommandLogging? = nil,
        cancellation: RuntimeCancellation = RuntimeCancellation()
    ) {
        self.logging = logging
        downloads = ColliderDownloads { progress in
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
    }

    public func execute(_ command: CommandSpec) async throws -> CommandResult {
        try await execute(command, stage: nil)
    }

    public func download(
        _ specification: DownloadSpec,
        to candidate: FilePath
    ) async throws {
        try await downloads.download(specification, to: candidate)
    }

    public func execute(
        _ command: CommandSpec,
        stage: TaskID?
    ) async throws -> CommandResult {
        let operation = Task {
            try await self.executeRegistered(command, stage: stage)
        }
        let registration = await cancellation.register { operation.cancel() }
        defer {
            Task { await cancellation.unregister(registration) }
        }
        let shutdown = Mutex<Task<Void, Never>?>(nil)
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                let task = Task {
                    #if !os(Windows)
                    await cancellation.forward(signal: Signal.terminate.rawValue)
                    let deadline = ContinuousClock().now.advanced(
                        by: .seconds(2))
                    while await cancellation.hasActiveProcessGroups(),
                          ContinuousClock().now < deadline
                    {
                        try? await ContinuousClock().sleep(
                            for: .milliseconds(10))
                    }
                    #endif
                    operation.cancel()
                    _ = try? await operation.value
                }
                shutdown.withLock { $0 = task }
            }
            try Task.checkCancellation()
            return result
        } catch {
            let task = shutdown.withLock { $0 }
            if let task { await task.value }
            throw error
        }
    }

    private func executeRegistered(
        _ command: CommandSpec,
        stage: TaskID?
    ) async throws -> CommandResult {
        guard let timeout = command.timeoutNanoseconds else {
            return try await executeWithoutTimeout(command, stage: stage)
        }
        return try await withThrowingTaskGroup(
            of: TimedExecutionOutcome.self,
            returning: CommandResult.self
        ) { group in
            group.addTask {
                .command(try await self.executeWithoutTimeout(command, stage: stage))
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .nanoseconds(Int64(timeout)))
                return .deadline
            }
            let first = try await group.next()!
            switch first {
            case .command(let result):
                group.cancelAll()
                return result
            case .deadline:
                #if !os(Windows)
                await cancellation.forward(signal: Signal.terminate.rawValue)
                let graceDeadline = ContinuousClock().now.advanced(by: .seconds(2))
                while await cancellation.hasActiveProcessGroups(),
                      ContinuousClock().now < graceDeadline
                {
                    try? await ContinuousClock().sleep(for: .milliseconds(10))
                }
                #endif
                group.cancelAll()
                return CommandResult(status: 0, timedOut: true)
            }
        }
    }

    private func executeWithoutTimeout(
        _ command: CommandSpec,
        stage: TaskID?
    ) async throws -> CommandResult {
        let executable: Subprocess.Executable = switch command.executable {
        case .named(let name): .name(name)
        case .path(let path): .path(path)
        case .taskOutput(let path): .path(path)
        }
        let environment = Subprocess.Environment.custom(
            Dictionary(uniqueKeysWithValues: command.environment.map {
                (Subprocess.Environment.Key(rawValue: $0.key)!, $0.value)
            }))
        var platform = Subprocess.PlatformOptions()
        #if !os(Windows)
        platform.processGroupID = command.output == .terminal ? nil : 0
        platform.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: command.output != .terminal,
                allowedDurationToNextStep: .seconds(2)),
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
                stage: stage)
        case .terminal:
            return try await execute(
                command,
                executable: executable,
                environment: environment,
                platform: platform,
                input: FileDescriptorInput.standardInput,
                stage: stage)
        case .bytes(let bytes):
            return try await execute(
                command,
                executable: executable,
                environment: environment,
                platform: platform,
                input: ArrayInput.array(bytes),
                stage: stage)
        }
    }

    private func execute<Input: InputProtocol>(
        _ command: CommandSpec,
        executable: Subprocess.Executable,
        environment: Subprocess.Environment,
        platform: Subprocess.PlatformOptions,
        input: consuming Input,
        stage: TaskID?
    ) async throws -> CommandResult {
        if command.output == .terminal {
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(command.arguments),
                environment: environment,
                workingDirectory: command.workingDirectory,
                platformOptions: platform,
                input: input,
                output: .currentStandardOutput,
                error: .currentStandardError)
            return CommandResult(status: statusCode(result.terminationStatus))
        }

        return try await executeStreaming(
            command,
            executable: executable,
            environment: environment,
            platform: platform,
            input: input,
            logging: logging,
            stage: stage)
    }

    private func executeStreaming<Input: InputProtocol>(
        _ command: CommandSpec,
        executable: Subprocess.Executable,
        environment: Subprocess.Environment,
        platform: Subprocess.PlatformOptions,
        input: consuming Input,
        logging: CommandLogging?,
        stage: TaskID?
    ) async throws -> CommandResult {
        let sink = CommandOutputSink(logging: logging, stage: stage)
        switch command.output {
        case .combined(let limit):
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(command.arguments),
                environment: environment,
                workingDirectory: command.workingDirectory,
                platformOptions: platform,
                input: input,
                output: .sequence,
                error: .combinedWithOutput
            ) { execution in
                let registration = await self.cancellation.registerProcessGroup(
                    execution.processIdentifier.value)
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
            return CommandResult(
                status: statusCode(result.terminationStatus),
                standardOutput: String(decoding: result.closureResult, as: UTF8.self))
        case .inherited, .logged, .captured:
            let captureLimit: Int? = switch command.output {
            case .captured(let limit): limit
            default: nil
            }
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(command.arguments),
                environment: environment,
                workingDirectory: command.workingDirectory,
                platformOptions: platform,
                input: input,
                output: .sequence,
                error: .sequence
            ) { execution in
                let registration = await self.cancellation.registerProcessGroup(
                    execution.processIdentifier.value)
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
            return CommandResult(
                status: statusCode(result.terminationStatus),
                standardOutput: String(decoding: result.closureResult, as: UTF8.self))
        case .terminal:
            preconditionFailure("terminal commands are executed with inherited descriptors")
        }
    }
}

private enum TimedExecutionOutcome: Sendable {
    case command(CommandResult)
    case deadline
}

private enum OutputStream: Sendable, Equatable { case stdout, stderr }

private struct StreamResult: Sendable {
    let stream: OutputStream
    let bytes: [UInt8]
}

private actor CommandOutputSink {
    let logging: CommandLogging?
    let stage: TaskID?

    init(logging: CommandLogging?, stage: TaskID?) {
        self.logging = logging
        self.stage = stage
    }

    func write(_ bytes: [UInt8], mirror: FileDescriptor?) async throws {
        if let logging {
            try await logging.registry.appendLog(bytes, stage: stage, in: logging.run)
        }
        if let mirror { try mirror.writeAll(bytes) }
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
        let bytes = chunk.withUnsafeBytes { Array($0) }
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
