import ColliderCore
import ColliderRuntime
import Dispatch
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
           fileManager.fileExists(atPath: manifest) {
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
        from: FileManager.default.currentDirectoryPath) {
        return discovered
    }
    throw WorkspaceFailure.message(
        "collider must be run inside a Nucleus workspace "
            + "(no clone at or above the current directory)")
}

private let activeCommandLogging = Mutex<CommandLogging?>(nil)
private let activeCancellation = Mutex<RuntimeCancellation?>(nil)

func setActiveCommandRuntime(
    logging: CommandLogging?,
    cancellation: RuntimeCancellation?
) {
    activeCommandLogging.withLock { $0 = logging }
    activeCancellation.withLock { $0 = cancellation }
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
        let cancellation = activeCancellation.withLock { $0 }
            ?? RuntimeCancellation()
        if let logging {
            environment["NUCLEUS_RUN_DIR"] = logging.run.directory.string
            environment["NUCLEUS_RUN_LOG"] = logging.run.directory
                .appending("run.log").string
        }
        return WorkspaceContext(
            root: URL(fileURLWithPath: root),
            environment: environment,
            runtime: ColliderRuntime(
                logging: logging,
                cancellation: cancellation))
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
        timeoutSeconds: Int? = nil,
        timeoutIsSuccess: Bool = false,
        terminal: Bool = false,
        stage: TaskID? = nil
    ) throws -> String {
        let childEnvironment = sanitizedEnvironment(
            environment.merging(environmentOverrides) { _, override in override })
        let executableReference: CommandSpec.Executable = executable.contains("/")
            ? .path(FilePath(executable))
            : .named(executable)
        let specification = CommandSpec(
            executable: executableReference,
            arguments: arguments,
            workingDirectory: FilePath((directory ?? root).path),
            environment: childEnvironment,
            input: terminal ? .terminal : .none,
            output: terminal
                ? .terminal
                : capture ? .captured(limit: 64 * 1_024 * 1_024) : .inherited,
            timeoutNanoseconds: timeoutSeconds.map { UInt64($0) * 1_000_000_000 })
        let result = try waitForAsyncResult {
            try await runtime.execute(specification, stage: stage)
        }
        guard (result.timedOut && timeoutIsSuccess) || result.status == 0 else {
            throw WorkspaceFailure.process([executable] + arguments, result.status)
        }
        return capture
            ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    func start(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        stage: TaskID? = nil
    ) -> WorkspaceManagedCommand {
        let childEnvironment = sanitizedEnvironment(
            environment.merging(environmentOverrides) { _, override in override })
        let executableReference: CommandSpec.Executable = executable.contains("/")
            ? .path(FilePath(executable))
            : .named(executable)
        let specification = CommandSpec(
            executable: executableReference,
            arguments: arguments,
            workingDirectory: FilePath((directory ?? root).path),
            environment: childEnvironment)
        return WorkspaceManagedCommand(
            runtime: runtime,
            specification: specification,
            stage: stage)
    }

    func withExclusiveVerification<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        let directory = root
            .appendingPathComponent(".nucleus/locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let lock = try WorkspaceFileLock(
            path: directory.appendingPathComponent("verification.lock").path,
            purpose: "workspace verification")
        return try withExtendedLifetime(lock) { try body() }
    }
}

final class WorkspaceManagedCommand: @unchecked Sendable {
    private let shared: ManagedCommandState
    private var task: Task<Void, Never>?

    init(
        runtime: ColliderRuntime,
        specification: CommandSpec,
        stage: TaskID?
    ) {
        let shared = ManagedCommandState()
        self.shared = shared
        self.task = nil
        shared.completion.enter()
        task = Task.detached { [shared] in
            do {
                let value = try await runtime.execute(specification, stage: stage)
                shared.state.withLock { $0 = .success(value) }
            } catch {
                shared.state.withLock {
                    $0 = .failure(.message(String(describing: error)))
                }
            }
            shared.completion.leave()
        }
    }

    var isRunning: Bool { shared.state.withLock { $0 == nil } }

    var terminationStatus: Int32? {
        shared.state.withLock { try? $0?.get().status }
    }

    func cancel() { task?.cancel() }

    @discardableResult
    func wait() throws -> CommandResult {
        shared.completion.wait()
        return try shared.state.withLock { try $0!.get() }
    }
}

private final class ManagedCommandState: @unchecked Sendable {
    let state = Mutex<Result<CommandResult, WorkspaceFailure>?>(nil)
    let completion = DispatchGroup()
}

func waitForAsyncResult<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let result = Mutex<Result<Value, PreservedAsyncFailure>?>(nil)
    let completion = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let value = try await operation()
            result.withLock { $0 = .success(value) }
        } catch {
            result.withLock { $0 = .failure(PreservedAsyncFailure(error)) }
        }
        completion.signal()
    }
    completion.wait()
    switch result.withLock({ $0! }) {
    case .success(let value): return value
    case .failure(let failure): throw failure.underlying
    }
}

private struct PreservedAsyncFailure: Error, @unchecked Sendable {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
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
