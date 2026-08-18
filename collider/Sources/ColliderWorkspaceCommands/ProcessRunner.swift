import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

extension WorkspaceContext {
    @discardableResult
    package func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        capture: Bool = false,
        environmentOverrides: [String: String] = [:],
        input: CommandSpec.Input? = nil,
        output: CommandSpec.Output? = nil,
        timeoutSeconds: Int? = nil,
        timeoutIsSuccess: Bool = false,
        acceptedExitStatuses: Set<Int32> = [0],
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
            workingDirectory: directory.map(FilePath.init) ?? root,
            environment: childEnvironment,
            input: input ?? (terminal ? .terminal : .none),
            output: output
                ?? (terminal
                    ? .terminal
                    : capture
                        ? .captured(limit: 64 * 1_024 * 1_024)
                        : .inherited),
            timeoutNanoseconds: timeoutSeconds.map { UInt64($0) * 1_000_000_000 })
        let result = try await runtime.execute(specification, stage: stage)
        guard
            (result.timedOut && timeoutIsSuccess)
                || acceptedExitStatuses.contains(result.status)
        else {
            throw WorkspaceFailure.process([executable] + arguments, result.status)
        }
        return capture
            ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    package func withRunningCommand<Value: Sendable>(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        output: CommandSpec.Output = .inherited,
        terminal: Bool = false,
        timeoutSeconds: Int? = nil,
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
            workingDirectory: directory.map(FilePath.init) ?? root,
            environment: childEnvironment,
            input: terminal ? .terminal : .none,
            output: terminal ? .terminal : output,
            timeoutNanoseconds: timeoutSeconds.map {
                UInt64($0) * 1_000_000_000
            })
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
                    let outcome:
                        Result<
                            CommandResult,
                            RunningCommandFailure
                        >
                    do {
                        let result = try await runtime.execute(
                            specification,
                            stage: stage
                        ) { processIdentifier in
                            await state.started(
                                processIdentifier: processIdentifier)
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
            lockRoot
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory.string, isDirectory: true),
            withIntermediateDirectories: true)
        let lock = try WorkspaceFileLock(
            path: directory.appending("verification.lock").string,
            purpose: "workspace verification")
        defer { withExtendedLifetime(lock) {} }
        return try await body()
    }
}

package struct RunningCommand: Sendable {
    fileprivate let state: RunningCommandState

    package func waitUntilReady() async throws {
        try await state.waitUntilReady()
    }

    package var isRunning: Bool {
        get async { await state.isRunning }
    }

    package var terminationStatus: Int32? {
        get async { await state.terminationStatus }
    }

    package var processIdentifier: Int32? {
        get async { await state.processIdentifier }
    }

    package func wait() async throws -> CommandResult {
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
    private(set) var processIdentifier: Int32?
    private var readiness: [CheckedContinuation<Result<Void, RunningCommandFailure>, Never>] = []
    private var completion:
        [CheckedContinuation<
            Result<CommandResult, RunningCommandFailure>,
            Never
        >] = []

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

    func started(processIdentifier: Int32) {
        guard case .starting = phase else { return }
        self.processIdentifier = processIdentifier
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

func sanitizedEnvironment(
    _ environment: [String: String]
) -> [String: String] {
    let fixed = Set([
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM",
        "SHELL", "SDKROOT", "JAVA_HOME", "CC", "CXX", "LD_LIBRARY_PATH",
        "WAYLAND_DISPLAY",
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
