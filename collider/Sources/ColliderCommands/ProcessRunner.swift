import ColliderCore
import ColliderRuntime
import Foundation
import Synchronization
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum WorkspaceFailure: Error, CustomStringConvertible, Sendable {
    case message(String)
    case process([String], Int32)

    var description: String {
        switch self {
        case .message(let value): value
        case .process(let command, let status):
            "command failed with exit \(status): \(command.joined(separator: " "))"
        }
    }
}

/// Walk up from `start` for a Nucleus clone root: a directory holding both the
/// `collider-setup.sh` entry point and the `collider` tool package manifest.
func discoverWorkspaceRoot(from start: String) -> String? {
    var directory = URL(fileURLWithPath: start).standardizedFileURL
    let fileManager = FileManager.default
    while true {
        let marker = directory.appendingPathComponent("collider-setup.sh").path
        let manifest = directory.appendingPathComponent("collider/Package.swift").path
        if fileManager.fileExists(atPath: marker),
            fileManager.fileExists(atPath: manifest)
        {
            return directory.path
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
}

/// The active workspace root. The `collider` launcher and `collider-setup.sh`
/// export `NUCLEUS_WORKSPACE_ROOT`; a directly invoked binary discovers it from
/// the current directory. A command run outside any clone is rejected, so every
/// command is gated to inside a Nucleus workspace.
func resolveWorkspaceRoot(environment: [String: String]) throws -> String {
    if let root = environment["NUCLEUS_WORKSPACE_ROOT"], !root.isEmpty {
        return root
    }
    if let discovered = discoverWorkspaceRoot(
        from: FileManager.default.currentDirectoryPath)
    {
        return discovered
    }
    throw WorkspaceFailure.message(
        "collider must be run inside a Nucleus workspace "
            + "(no clone at or above the current directory)")
}

private let activeCommandLogging = Mutex<CommandLogging?>(nil)
private let activeCancellation = Mutex<RuntimeCancellation?>(nil)
private let activeRuntime = Mutex<ColliderRuntime?>(nil)

func setActiveCommandRuntime(
    logging: CommandLogging?,
    cancellation: RuntimeCancellation?,
    runtime: ColliderRuntime?
) {
    activeCommandLogging.withLock { $0 = logging }
    activeCancellation.withLock { $0 = cancellation }
    activeRuntime.withLock { $0 = runtime }
}

struct WorkspaceContext: Sendable {
    let root: URL
    let environment: [String: String]
    let runtime: ColliderRuntime

    init(
        root: URL,
        environment: [String: String],
        runtime: ColliderRuntime = ColliderRuntime()
    ) {
        self.root = root
        self.environment = environment
        self.runtime = runtime
    }

    static func load() throws -> WorkspaceContext {
        var environment = ProcessInfo.processInfo.environment
        let root = try resolveWorkspaceRoot(environment: environment)
        environment["NUCLEUS_WORKSPACE_ROOT"] = root
        let logging = activeCommandLogging.withLock { $0 }
        let cancellation =
            activeCancellation.withLock { $0 }
            ?? RuntimeCancellation()
        let runtime =
            activeRuntime.withLock { $0 }
            ?? ColliderRuntime(
                logging: logging,
                cancellation: cancellation)
        if let logging {
            environment["NUCLEUS_RUN_DIR"] = logging.run.directory.string
            environment["NUCLEUS_RUN_LOG"] =
                logging.run.directory
                .appending("run.log").string
        }
        return WorkspaceContext(
            root: URL(fileURLWithPath: root),
            environment: environment,
            runtime: runtime)
    }

    func repository(_ name: String) -> URL { root.appendingPathComponent(name) }

    var taskEnvironment: [String: String] { sanitizedEnvironment(environment) }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        capture: Bool = false,
        environmentOverrides: [String: String] = [:],
        output: CommandSpec.Output? = nil,
        timeoutSeconds: Int? = nil,
        timeoutIsSuccess: Bool = false,
        terminal: Bool = false,
        stage: TaskID? = nil
    ) async throws -> String {
        let childEnvironment = sanitizedEnvironment(
            environment.merging(environmentOverrides) { _, override in override })
        let executableReference: CommandSpec.Executable =
            executable.contains("/")
            ? .path(FilePath(executable))
            : .named(executable)
        let specification = CommandSpec(
            executable: executableReference,
            arguments: arguments,
            workingDirectory: FilePath((directory ?? root).path),
            environment: childEnvironment,
            input: terminal ? .terminal : .none,
            output: output
                ?? (terminal
                    ? .terminal
                    : capture
                        ? .captured(limit: 64 * 1_024 * 1_024)
                        : .inherited),
            timeoutNanoseconds: timeoutSeconds.map { UInt64($0) * 1_000_000_000 })
        let result = try await runtime.execute(specification, stage: stage)
        guard (result.timedOut && timeoutIsSuccess) || result.status == 0 else {
            throw WorkspaceFailure.process([executable] + arguments, result.status)
        }
        return capture
            ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    func withRunningCommand<Value: Sendable>(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        output: CommandSpec.Output = .inherited,
        stage: TaskID? = nil,
        _ body: @escaping @Sendable (RunningCommand) async throws -> Value
    ) async throws -> Value {
        let childEnvironment = sanitizedEnvironment(
            environment.merging(environmentOverrides) { _, override in override })
        let executableReference: CommandSpec.Executable =
            executable.contains("/")
            ? .path(FilePath(executable))
            : .named(executable)
        let specification = CommandSpec(
            executable: executableReference,
            arguments: arguments,
            workingDirectory: FilePath((directory ?? root).path),
            environment: childEnvironment,
            output: output)
        let state = RunningCommandState()
        let handle = RunningCommand(state: state)
        let cancellation = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        defer { cancellation.continuation.finish() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: RunningCommandScopeEvent<Value>.self,
                returning: Value.self
            ) { group in
                group.addTask {
                    let outcome: Result<
                        CommandResult,
                        RunningCommandFailure
                    >
                    do {
                        let result = try await runtime.execute(
                            specification,
                            stage: stage
                        ) {
                            await state.started()
                        }
                        outcome = .success(result)
                    } catch {
                        outcome = .failure(RunningCommandFailure(error))
                    }
                    await state.finished(outcome)
                    return .command(outcome)
                }
                group.addTask {
                    do {
                        return .body(.success(try await body(handle)))
                    } catch {
                        return .body(.failure(RunningCommandFailure(error)))
                    }
                }
                group.addTask {
                    for await _ in cancellation.stream {
                        return .cancelled
                    }
                    return .cancelled
                }

                while let event = try await group.next() {
                    switch event {
                    case .command(.success):
                        continue
                    case .command(.failure(let failure)):
                        group.cancelAll()
                        cancellation.continuation.finish()
                        throw failure.underlying
                    case .body(.success(let value)):
                        group.cancelAll()
                        cancellation.continuation.finish()
                        return value
                    case .body(.failure(let failure)):
                        group.cancelAll()
                        cancellation.continuation.finish()
                        throw failure.underlying
                    case .cancelled:
                        group.cancelAll()
                        throw CancellationError()
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            cancellation.continuation.yield(())
        }
    }

    func withExclusiveVerification<Result>(
        _ body: () async throws -> Result
    ) async throws -> Result {
        let directory =
            root
            .appendingPathComponent(".nucleus/locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let lock = try WorkspaceFileLock(
            path: directory.appendingPathComponent("verification.lock").path,
            purpose: "workspace verification")
        defer { withExtendedLifetime(lock) {} }
        return try await body()
    }
}

struct RunningCommand: Sendable {
    fileprivate let state: RunningCommandState

    func waitUntilReady() async throws {
        try await state.waitUntilReady()
    }

    var isRunning: Bool {
        get async { await state.isRunning }
    }

    var terminationStatus: Int32? {
        get async { await state.terminationStatus }
    }

    func wait() async throws -> CommandResult {
        try await state.wait()
    }
}

private struct RunningCommandFailure: Error, @unchecked Sendable {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }
}

private enum RunningCommandScopeEvent<Value: Sendable>: Sendable {
    case command(Result<CommandResult, RunningCommandFailure>)
    case body(Result<Value, RunningCommandFailure>)
    case cancelled
}

private actor RunningCommandState {
    private enum Phase {
        case starting
        case running
        case finished(Result<CommandResult, RunningCommandFailure>)
    }

    private var phase = Phase.starting
    private var readiness: [
        CheckedContinuation<Result<Void, RunningCommandFailure>, Never>
    ] = []
    private var completion: [
        CheckedContinuation<
            Result<CommandResult, RunningCommandFailure>,
            Never
        >
    ] = []

    var isRunning: Bool {
        switch phase {
        case .starting, .running: true
        case .finished: false
        }
    }

    var terminationStatus: Int32? {
        guard case .finished(.success(let result)) = phase else {
            return nil
        }
        return result.status
    }

    func started() {
        guard case .starting = phase else { return }
        phase = .running
        let waiters = readiness
        readiness.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: .success(())) }
    }

    func finished(
        _ result: Result<CommandResult, RunningCommandFailure>
    ) {
        guard isRunning else { return }
        let wasStarting: Bool
        if case .starting = phase {
            wasStarting = true
        } else {
            wasStarting = false
        }
        phase = .finished(result)
        if wasStarting {
            let readyResult = result.map { _ in () }
            let waiters = readiness
            readiness.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume(returning: readyResult)
            }
        }
        let waiters = completion
        completion.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func waitUntilReady() async throws {
        let result: Result<Void, RunningCommandFailure>
        switch phase {
        case .running:
            return
        case .finished(let completion):
            result = completion.map { _ in () }
        case .starting:
            result = await withCheckedContinuation { continuation in
                readiness.append(continuation)
            }
        }
        try result.get()
    }

    func wait() async throws -> CommandResult {
        let outcome: Result<CommandResult, RunningCommandFailure>
        switch phase {
        case .finished(let result):
            outcome = result
        case .starting, .running:
            outcome = await withCheckedContinuation { continuation in
                self.completion.append(continuation)
            }
        }
        return try outcome.get()
    }
}

private func sanitizedEnvironment(
    _ environment: [String: String]
) -> [String: String] {
    let fixed = Set([
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM",
        "SHELL", "SDKROOT", "JAVA_HOME", "CC", "CXX", "LD_LIBRARY_PATH",
        "PKG_CONFIG_PATH", "SWIFTCI_USE_LOCAL_DEPS",
    ])
    let deniedFragments = ["TOKEN", "PASSWORD", "SECRET", "CREDENTIAL"]
    return environment.filter { key, _ in
        let upper = key.uppercased()
        guard !deniedFragments.contains(where: upper.contains) else { return false }
        return fixed.contains(key)
            || key.hasPrefix("LC_")
            || key.hasPrefix("XDG_")
            || key.hasPrefix("NUCLEUS_")
            || key.hasPrefix("ANDROID_")
            || key.hasPrefix("SWIFT_")
    }
}

final class WorkspaceFileLock {
    private let lock: ColliderFileLock

    init(path: String, purpose: String, waitForExistingOwner: Bool = true) throws {
        do {
            lock = try ColliderFileLock(
                path: FilePath(path),
                purpose: purpose,
                waitForExistingOwner: waitForExistingOwner)
        } catch {
            throw WorkspaceFailure.message(String(describing: error))
        }
    }
}
