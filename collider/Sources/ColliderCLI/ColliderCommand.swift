import ArgumentParser
import ColliderCore
import ColliderPersistence
import ColliderRuntime
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

public struct ColliderCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "collider",
        abstract: "Build, test, and operate the Nucleus repository.",
        version: "0.1.0",
        subcommands: colliderCommandSubcommands())

    public init() {}

    public static func execute(arguments: [String]) async throws {
        var command = try parseAsRoot(arguments)
        let environment = ProcessInfo.processInfo.environment
        let workspace = try resolveWorkspaceRoot(environment: environment)
        let layout = WorkspaceLayout(root: workspace)
        let registry = RunRegistry(
            root: layout.state)
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
        let runtime = ColliderRuntime(
            logging: logging,
            cancellation: cancellation)
        let signals = RuntimeSignalHandlers(cancellation: cancellation)
        setActiveCommandRuntime(
            logging: logging,
            cancellation: cancellation,
            runtime: runtime)
        defer {
            signals.cancel()
            setActiveCommandRuntime(
                logging: nil,
                cancellation: nil,
                runtime: nil)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            await runtime.shutdown()
            try await registry.finish(run, status: .succeeded)
        } catch let cleanExit as CleanExit {
            await runtime.shutdown()
            try? await registry.finish(run, status: .succeeded)
            throw cleanExit
        } catch {
            await runtime.shutdown()
            let wasInterrupted = await cancellation.wasInterrupted()
            try? await registry.appendLog(
                Array("Error: \(error)\n".utf8),
                in: run)
            let status = commandFailureStatus(
                error,
                wasInterrupted: wasInterrupted)
            try? await registry.finish(run, status: status)
            throw error
        }
    }
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
