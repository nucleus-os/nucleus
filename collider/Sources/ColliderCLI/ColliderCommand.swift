import ArgumentParser
import ColliderCore
import ColliderPersistence
import ColliderRuntime
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

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
        let command = try parseAsRoot(arguments)
        var environment = ProcessInfo.processInfo.environment
        let workspace = try resolveWorkspaceRoot(environment: environment)
        environment = nucleusWorkspaceEnvironment(
            root: workspace,
            environment: environment)
        let layout = WorkspaceLayout(root: workspace)
        let registry = RunRegistry(root: layout.state)
        let requestedRunID = requestedRunID(for: command)
        let run =
            if let requestedRunID {
                try await registry.resume(requestedRunID)
            } else {
                try await registry.begin(
                    command: [CommandLine.arguments[0]] + arguments)
            }
        let cancellation = RuntimeCancellation()
        let logging = CommandLogging(registry: registry, run: run)
        environment["NUCLEUS_RUN_DIR"] = run.directory.string
        environment["NUCLEUS_RUN_LOG"] = run.directory.appending("run.log").string
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
                runtime: runtime),
            signals: signals)
        defer {
            application.signals.cancel()
        }
        do {
            guard var workspaceCommand = command as? any ColliderWorkspaceCommand
            else {
                throw WorkspaceFailure.message(
                    "parsed Collider leaf does not accept application composition")
            }
            try await workspaceCommand.run(in: application.workspace)
            await application.runtime.shutdown()
            try await application.registry.finish(application.run, status: .succeeded)
        } catch let cleanExit as CleanExit {
            await application.runtime.shutdown()
            try? await application.registry.finish(
                application.run,
                status: .succeeded)
            throw cleanExit
        } catch {
            await application.runtime.shutdown()
            let wasInterrupted = await application.cancellation.wasInterrupted()
            try? await application.registry.appendLog(
                Array("Error: \(error)\n".utf8),
                in: application.run)
            let status = commandFailureStatus(
                error,
                wasInterrupted: wasInterrupted)
            try? await application.registry.finish(
                application.run,
                status: status)
            throw error
        }
    }
}

private struct ColliderApplicationComposition {
    let registry: RunRegistry
    let run: RunHandle
    let logging: CommandLogging
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
