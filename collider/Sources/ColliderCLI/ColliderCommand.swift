import ArgumentParser
import ColliderCore
import ColliderPersistence
import ColliderRuntime
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(macOS)
import ColliderAppleContainer
#endif

public struct ColliderCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collider",
        abstract: "Build, test, and operate the Nucleus repository.",
        version: "0.1.0",
        subcommands: colliderCommandSubcommands())

    public init() {}

    public static func execute(arguments: [String]) async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        try validateColliderEntrypoint(environment: processEnvironment)
        let command = try parseAsRoot(arguments)
        guard var workspaceCommand = command as? any ColliderWorkspaceCommand else {
            var informationalCommand = command
            try informationalCommand.run()
            throw WorkspaceFailure.message(
                "parsed Collider command did not exit or accept application composition")
        }
        let console = CommandConsole.process(
            options: workspaceCommand.outputOptions,
            environment: processEnvironment,
            standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1,
            standardErrorIsTerminal: isatty(STDERR_FILENO) == 1)
        defer { try? console.finishProgress() }
        var environment = processEnvironment
        let workspace = try resolveWorkspaceRoot(environment: environment)
        environment = nucleusWorkspaceEnvironment(
            root: workspace,
            environment: environment)
        let layout = WorkspaceLayout(root: workspace)
        let registry = RunRegistry(root: layout.state)
        let requestedRunID = requestedRunID(for: command)
        let run: RunHandle?
        if workspaceCommand.recordsRun {
            run =
                if let requestedRunID {
                    try await registry.resume(requestedRunID)
                } else {
                    try await registry.begin(
                        command: [CommandLine.arguments[0]] + arguments)
                }
        } else {
            run = nil
        }
        let cancellation = RuntimeCancellation()
        let logging = run.map { CommandLogging(registry: registry, run: $0) }
        if let run {
            environment["NUCLEUS_RUN_DIR"] = run.directory.string
            environment["NUCLEUS_RUN_LOG"] = run.directory.appending("run.log").string
        }
        let cacheLayout = nucleusCacheLayout(environment: environment)
        #if os(macOS)
        let ociBackend: (any OCIRuntimeBackend)? = AppleContainerRuntimeBackend()
        #else
        let ociBackend: (any OCIRuntimeBackend)? = nil
        #endif
        let runtime = ColliderRuntime(
            logging: logging,
            cancellation: cancellation,
            downloadCacheRoot: cacheLayout.downloads,
            ociConfiguration: nucleusOCIRuntimeConfiguration,
            ociBackend: ociBackend)
        let signals = RuntimeSignalHandlers(cancellation: cancellation)
        let application = ColliderApplicationComposition(
            registry: registry,
            run: run,
            logging: logging,
            cancellation: cancellation,
            runtime: runtime,
            workspace: WorkspaceContext(
                root: workspace,
                environment: environment,
                runtime: runtime,
                console: console),
            signals: signals)
        defer {
            application.signals.cancel()
        }
        do {
            try await workspaceCommand.run(in: application.workspace)
            await application.runtime.shutdown()
            if let run = application.run {
                try await application.registry.finish(run, status: .succeeded)
            }
        } catch let cleanExit as CleanExit {
            await application.runtime.shutdown()
            if let run = application.run {
                try? await application.registry.finish(
                    run,
                    status: .succeeded)
            }
            throw cleanExit
        } catch {
            await application.runtime.shutdown()
            let wasInterrupted = await application.cancellation.wasInterrupted()
            let interruptionSignal =
                await application.cancellation.receivedInterruptionSignal()
            let failure =
                (error as? ExecutionFailure)
                ?? ExecutionFailure(reason: String(describing: error))
            if let run = application.run {
                try? await application.registry.appendLog(
                    Array("Error: \(failure)\n".utf8),
                    in: run)
            }
            let status = commandFailureStatus(
                error,
                wasInterrupted: wasInterrupted)
            if status == .interrupted, let run = application.run {
                try? await application.registry.record(
                    .interruption(
                        InterruptionEvent(
                            signal: interruptionSignal,
                            reason: "run interrupted")),
                    in: run)
            }
            if let run = application.run {
                try? await application.registry.finish(
                    run,
                    status: status)
            }
            try? console.failure(failure)
            throw ExitCode.failure
        }
    }
}

func validateColliderEntrypoint(environment: [String: String]) throws {
    let entrypoint = environment["COLLIDER_ENTRYPOINT"]
    guard entrypoint == "workspace-launcher" || entrypoint == "setup-bootstrap" else {
        throw WorkspaceFailure.message(
            "direct Collider executable invocation is unsupported; "
                + "run the installed 'collider' command")
    }
}

private struct ColliderApplicationComposition {
    let registry: RunRegistry
    let run: RunHandle?
    let logging: CommandLogging?
    let cancellation: RuntimeCancellation
    let runtime: ColliderRuntime
    let workspace: WorkspaceContext
    let signals: RuntimeSignalHandlers
}

func commandFailureStatus(
    _ error: any Error,
    wasInterrupted: Bool
) -> RunStatus {
    if wasInterrupted {
        return .interrupted
    }
    if error is CancellationError {
        return .interrupted
    }
    if case .resumptionIdentityChanged = error as? RunRegistryFailure {
        return .interrupted
    }
    return .failed
}
