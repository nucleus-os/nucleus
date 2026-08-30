import ColliderCore
import ColliderDownloads
import ColliderPersistence
import ColliderPlatformC
import ColliderProcess
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
    public let managedLabelNamespace: String
    public let persistentWorkspaceOwner: String?
    public let loggerLabel: String

    public init(
        isolatedNetwork: String,
        guestHome: String,
        managedLabels: [String],
        managedLabelNamespace: String,
        persistentWorkspaceOwner: String?,
        loggerLabel: String
    ) {
        precondition(!isolatedNetwork.isEmpty)
        precondition(guestHome.hasPrefix("/"))
        precondition(!managedLabels.isEmpty)
        precondition(!managedLabelNamespace.isEmpty)
        precondition(!managedLabelNamespace.contains("="))
        precondition(persistentWorkspaceOwner?.isEmpty != true)
        precondition(!loggerLabel.isEmpty)
        self.isolatedNetwork = isolatedNetwork
        self.guestHome = guestHome
        self.managedLabels = managedLabels
        self.managedLabelNamespace = managedLabelNamespace
        self.persistentWorkspaceOwner = persistentWorkspaceOwner
        self.loggerLabel = loggerLabel
    }

    public static let engineDefault = OCIRuntimeConfiguration(
        isolatedNetwork: "collider-internal",
        guestHome: "/home/collider",
        managedLabels: ["dev.collider.managed=true"],
        managedLabelNamespace: "dev.collider",
        persistentWorkspaceOwner: nil,
        loggerLabel: "dev.collider.apple-container")
}

public actor ColliderRuntime {
    let logging: CommandLogging?
    let downloads: ColliderDownloads
    var taskOutputPresentation: TaskOutputPresentation?
    let taskOutputObserver: TaskOutputObserver
    public let cancellation: RuntimeCancellation
    let ociConfiguration: OCIRuntimeConfiguration
    let ociBackend: any OCIRuntimeBackend
    package nonisolated let hasOCIRuntimeBackend: Bool

    public init(
        logging: CommandLogging? = nil,
        cancellation: RuntimeCancellation = RuntimeCancellation(),
        taskOutputObserver: TaskOutputObserver = TaskOutputObserver()
    ) {
        self.init(
            logging: logging,
            cancellation: cancellation,
            taskOutputObserver: taskOutputObserver,
            downloadCacheRoot: defaultColliderDownloadCacheRoot(),
            ociConfiguration: .engineDefault,
            ociBackend: nil)
    }

    public init(
        logging: CommandLogging? = nil,
        cancellation: RuntimeCancellation = RuntimeCancellation(),
        taskOutputObserver: TaskOutputObserver = TaskOutputObserver(),
        downloadCacheRoot: FilePath,
        ociConfiguration: OCIRuntimeConfiguration,
        ociBackend: (any OCIRuntimeBackend)? = nil
    ) {
        self.logging = logging
        self.taskOutputObserver = taskOutputObserver
        downloads = ColliderDownloads(cacheRoot: downloadCacheRoot)
        self.cancellation = cancellation
        self.ociConfiguration = ociConfiguration
        hasOCIRuntimeBackend = ociBackend != nil
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
        try await ociBackend.diskUsage(configuration: ociConfiguration)
    }

    public func ociImages() async throws -> [OCIImageState] {
        try await ociBackend.images()
    }

    public func deleteOCIImages(references: [String]) async throws {
        try await ociBackend.deleteImages(references: references)
    }

    public func collectOrphanedOCIImageContent() async throws -> UInt64 {
        try await ociBackend.collectOrphanedImageContent()
    }

    public func ociInfrastructureImages() async throws -> OCIInfrastructureImages {
        try await ociBackend.infrastructureImages()
    }

    public func ociContainers() async throws -> [OCIContainerState] {
        try await ociBackend.containers()
    }

    public func deleteOCIContainer(named name: String) async throws {
        try await ociBackend.deleteContainer(named: name)
    }

    public func ociPersistentWorkspaces() async throws
        -> [OCIPersistentWorkspaceState]
    {
        try await ociBackend.persistentWorkspaces(configuration: ociConfiguration)
    }

    public func deleteOCIPersistentWorkspace(named name: String) async throws {
        try await ociBackend.deletePersistentWorkspace(
            named: name,
            configuration: ociConfiguration)
    }

    public func reclaimOCIPersistentWorkspace(
        _ workspace: PersistentWorkspaceDeclaration,
        imageReference: String
    ) async throws {
        try await ociBackend.reclaimPersistentWorkspace(
            workspace,
            imageReference: imageReference,
            configuration: ociConfiguration,
            cancellation: cancellation)
    }

    public func execute(_ command: CommandSpec) async throws -> CommandResult {
        try await execute(command, stage: nil, operationName: nil, onStarted: nil)
    }

    @discardableResult
    public func execute<Action: ColliderAction>(
        _ action: Action
    ) async throws -> TaskExecutionObservations {
        try await execute(try AnyColliderAction(action), stage: nil)
    }

    func execute(
        _ action: AnyColliderAction,
        stage: TaskID?
    ) async throws -> TaskExecutionObservations {
        let recordedObservations = Mutex(TaskExecutionObservations())
        let downloadProgress = downloadProgressRecorder(stage: stage)
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
                try await self.execute(
                    command,
                    stage: stage,
                    operationName: action.kind.rawValue)
            },
            downloads: ActionDownloader { specification, path in
                try await self.downloads.download(
                    specification,
                    to: path,
                    progress: downloadProgress)
            },
            containers: ActionContainerExecutor(
                prepareImage: { preparation in
                    try await self.prepareOCIImage(preparation, stage: stage)
                },
                run: { execution in
                    let outcome = try await self.executeOCI(
                        execution,
                        stage: stage,
                        operationName: action.kind.rawValue)
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
                                executableRequirements:
                                    execution.executableRequirements,
                                resourceLimits: execution.resourceLimits,
                                status: result.status,
                                timings: outcome.timings))
                    }
                    return result
                }
            ).scoped(to: action.requirements),
            observations: ActionObservationRecorder(
                record: { observation in
                    recordedObservations.withLock {
                        $0.actionStages.append(observation)
                    }
                },
                recordTestCases: { testCases in
                    recordedObservations.withLock {
                        $0.testCases.append(contentsOf: testCases)
                    }
                })
        )
        try await action.execute(in: context)
        return recordedObservations.withLock { $0 }
    }

    public func download(
        _ specification: DownloadSpec,
        to candidate: FilePath
    ) async throws {
        try await downloads.download(
            specification,
            to: candidate,
            progress: downloadProgressRecorder(stage: nil))
    }

    private func downloadProgressRecorder(
        stage: TaskID?
    ) -> @Sendable (DownloadProgress) -> Void {
        guard let logging else { return { _ in } }
        return { progress in
            Task {
                try? await logging.registry.record(
                    .download(
                        DownloadEvent(
                            task: stage,
                            digest: progress.digest,
                            receivedBytes: progress.receivedBytes,
                            expectedBytes: progress.expectedBytes)),
                    in: logging.run)
            }
        }
    }

    public func shutdown() async {
        await downloads.shutdown()
    }

    public func execute(
        _ command: CommandSpec,
        stage: TaskID?,
        operationName: String? = nil,
        onStarted: (@Sendable (Int32) async -> Void)? = nil
    ) async throws -> CommandResult {
        let context = await operationContext(
            for: command,
            stage: stage,
            operationName: operationName)
        if let logging {
            try? await logging.registry.record(
                .operation(.started(context)),
                in: logging.run)
        }
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
            }.recordingExecutionContext(context)
            try Task.checkCancellation()
            await cancellation.unregister(registration)
            if let logging {
                try? await logging.registry.record(
                    .operation(
                        .finished(
                            OperationResult(
                                context: context,
                                status: result.status,
                                signal: result.signal,
                                timedOut: result.timedOut))),
                    in: logging.run)
            }
            return result
        } catch {
            beginShutdown()
            if let task = shutdown.withLock({ $0 }) {
                await task.value
            }
            await cancellation.unregister(registration)
            let failure = executionFailure(
                error,
                context: context)
            if let logging {
                try? await logging.registry.record(
                    .operation(.failed(failure)),
                    in: logging.run)
            }
            if error is CancellationError { throw error }
            throw failure
        }
    }

    private func operationContext(
        for command: CommandSpec,
        stage: TaskID?,
        operationName: String?
    ) async -> OperationContext {
        let arguments = commandArguments(command)
        let logPath: String?
        if let logging, let stage {
            logPath = await logging.registry.stageLogPath(
                for: stage,
                in: logging.run
            ).string
        } else {
            logPath = nil
        }
        return OperationContext(
            task: stage,
            operation: operationName ?? arguments.first ?? "command",
            command: CredentialScrubber.command(arguments),
            invocation: CredentialScrubber.renderedCommand(arguments),
            workingDirectory: command.workingDirectory.string,
            logPath: logPath)
    }

    private func executionFailure(
        _ error: any Error,
        context: OperationContext
    ) -> ExecutionFailure {
        if let failure = error as? ExecutionFailure {
            return failure.addingContext(
                task: context.task,
                logPath: context.logPath)
        }
        return ExecutionFailure(
            task: context.task,
            operation: context.operation,
            command: context.command,
            invocation: context.invocation,
            workingDirectory: context.workingDirectory,
            logPath: context.logPath,
            reason: String(describing: error))
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
                // Contents and modes, never the source's access-control list:
                // a tree staged out of the checkout would otherwise carry the
                // rule that denies the executing identity from deleting it.
                guard
                    unsafe collider_copy_tree_without_acl(
                        resolved.path, destination.string) == 0
                else {
                    throw Errno(rawValue: errno)
                }
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
                try RemovalDenial.removeTree(path)
            },
            move: { source, destination in
                try FileManager.default.moveItem(
                    atPath: source.string,
                    toPath: destination.string)
            },
            normalizeTimestamps: { root, seconds in
                let stamp = Date(timeIntervalSince1970: TimeInterval(seconds))
                guard let walker = FileManager.default.enumerator(atPath: root.string)
                else { return }
                var paths: [String] = [root.string]
                while let entry = walker.nextObject() as? String {
                    paths.append(root.appending(entry).string)
                }
                // Deepest first, so setting a directory's own time is not
                // undone by writing something inside it afterwards.
                for path in paths.sorted(by: { $0.count > $1.count }) {
                    guard
                        (try? FileManager.default.attributesOfItem(atPath: path))?[.type]
                            as? FileAttributeType != .typeSymbolicLink
                    else { continue }
                    try? FileManager.default.setAttributes(
                        [.modificationDate: stamp],
                        ofItemAtPath: path)
                }
            },
            listDirectory: { root in
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: root.string)
                return try names.compactMap { name -> ActionFileSystem.Entry? in
                    let path = root.appending(name)
                    guard let metadata = try inspect(path, false) else { return nil }
                    return ActionFileSystem.Entry(
                        path: path,
                        relativePath: name,
                        metadata: metadata)
                }
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
                try DirectoryLifecycle.activate(target: target, link: path)
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
        let presentation: TaskOutputPresentation? =
            switch command.input {
            case .terminal: .raw
            case .none, .bytes: taskOutputPresentation
            }
        let command =
            if let presentation {
                command.withOutput(
                    presentation.output(for: command.output))
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
        let environment = Subprocess.Environment.custom(
            try ChildProcessEnvironment.validated(command.environment))
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
            taskOutputObserver.terminalWillBegin()
            defer { taskOutputObserver.terminalDidEnd() }
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
            return CommandResult(
                status: statusCode(result.terminationStatus),
                signal: signalCode(result.terminationStatus))
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
            logging: logging,
            stage: stage,
            file: file,
            presentation: taskOutputPresentation ?? .verbose,
            observer: taskOutputObserver)
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
                            stream: .standardOutput,
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
                    signal: signalCode(result.terminationStatus),
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
                                        stream: .standardOutput,
                                        sink: sink))
                            }
                            group.addTask {
                                StreamResult(
                                    stream: .stderr,
                                    bytes: try await collect(
                                        execution.standardError,
                                        limit: nil,
                                        stream: .standardError,
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
                    signal: signalCode(result.terminationStatus),
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

private func commandArguments(_ command: CommandSpec) -> [String] {
    let executable =
        switch command.executable {
        case .named(let name), .operationalNamed(let name): name
        case .path(let path): path.string
        case .artifact(let reference): reference.path.string
        case .taskOutput(let path): path.string
        }
    return [executable] + command.arguments
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
    let presentation: TaskOutputPresentation
    let observer: TaskOutputObserver
    var file: FileDescriptor?
    var isFinished = false

    package init(
        logging: CommandLogging?,
        stage: TaskID?,
        file path: FilePath?,
        presentation: TaskOutputPresentation,
        observer: TaskOutputObserver
    ) throws {
        self.logging = logging
        self.stage = stage
        self.presentation = presentation
        self.observer = observer
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
        stream: TaskOutputStream
    ) async throws {
        if let logging {
            try await logging.registry.appendLog(bytes, stage: stage, in: logging.run)
        }
        if let file {
            try file.writeAll(CredentialScrubber.bytes(bytes))
        }
        observer.output(
            .chunk(
                task: stage,
                stream: stream,
                bytes: bytes,
                presentation: presentation))
    }

    package func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        observer.output(.finished(task: stage, presentation: presentation))
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
    stream: TaskOutputStream,
    sink: CommandOutputSink
) async throws -> [UInt8] {
    var captured: [UInt8] = []
    var exceededLimit = false
    for try await chunk in sequence {
        let bytes = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
        if let limit {
            let remaining = max(0, limit - captured.count)
            if remaining > 0 {
                captured += bytes.prefix(remaining)
            }
            exceededLimit = exceededLimit || bytes.count > remaining
        }
        try await sink.write(bytes, stream: stream)
    }
    if let limit, exceededLimit {
        throw RuntimeFailure.outputLimitExceeded(limit)
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

private func signalCode(_ status: TerminationStatus) -> Int32? {
    switch status {
    case .exited: nil
    #if !os(Windows)
    case .signaled(let signal): signal
    #endif
    }
}
