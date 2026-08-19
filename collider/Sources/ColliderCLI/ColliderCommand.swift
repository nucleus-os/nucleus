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
        let taskCommand = workspaceCommand as? any TaskControlledCommand
        let dryRun = taskCommand?.taskOptions.dryRun == true
        let suppressTerminalSummary = dryRun
        let suppressHumanSummary =
            taskCommand?.taskOptions.quiet == true
            && taskCommand?.outputOptions.format == .text
        let console = CommandConsole.process(
            options: workspaceCommand.outputOptions,
            presentationKind: workspaceCommand.presentationKind,
            dryRun: dryRun,
            environment: processEnvironment,
            standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1,
            standardErrorIsTerminal: isatty(STDERR_FILENO) == 1)
        defer { try? console.finishProgress() }
        var environment = processEnvironment
        let workspace = try resolveWorkspaceRoot(environment: environment)
        environment = nucleusWorkspaceEnvironment(
            root: workspace,
            environment: environment)
        // Before the registry opens a run, because recording one is itself a
        // write into the store this account may not be permitted to make.
        if workspaceCommand.requiresExecutionAdmission {
            try requireBuildStoreWriteAccess()
        }
        let registry = RunRegistry(
            root: nucleusRunRegistryRoot(workspaceRoot: workspace))
        try await registry.reconcileAbandonedRuns()
        let observations: AsyncStream<RunObservation>? =
            if workspaceCommand.recordsRun {
                try await registry.observations()
            } else {
                nil
            }
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
        let observationTask: Task<Void, Never>? = observations.map { observations in
            Task {
                await consumeRunObservations(
                    observations,
                    console: console,
                    registry: registry,
                    run: run)
            }
        }
        defer { observationTask?.cancel() }
        let cancellation = RuntimeCancellation()
        let logging = run.map { CommandLogging(registry: registry, run: $0) }
        let hostPhases = HostPhaseRecorder(registry: registry, run: run)
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
        let ociConfiguration = nucleusOCIRuntimeConfiguration(workspaceRoot: workspace)
        let runtime = ColliderRuntime(
            logging: logging,
            cancellation: cancellation,
            taskOutputObserver: TaskOutputObserver(
                output: { try? console.taskOutput($0) },
                terminalWillBegin: { try? console.terminalWillSuspend() },
                terminalDidEnd: { try? console.terminalDidResume() }),
            downloadCacheRoot: cacheLayout.downloads,
            ociConfiguration: ociConfiguration,
            ociBackend: ociBackend)
        let signals = RuntimeSignalHandlers(
            cancellation: cancellation,
            terminal: RuntimeTerminalSignalCallbacks(
                willInterrupt: {
                    observationTask?.cancel()
                    try? console.terminalWillInterrupt()
                },
                didResize: { try? console.terminalDidResize() },
                willSuspend: { try? console.terminalWillSuspend() },
                didResume: { try? console.terminalDidResume() }))
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
                console: console,
                hostPhases: hostPhases,
                ociConfiguration: ociConfiguration),
            signals: signals)
        let sourceAtStart = try revalidatedSourceSnapshot(
            workspace: workspace,
            environment: environment)
        defer {
            application.signals.cancel()
        }
        var executionAdmission: ColliderFileLock?
        defer { withExtendedLifetime(executionAdmission) {} }
        do {
            if workspaceCommand.requiresExecutionAdmission {
                executionAdmission = try await acquireColliderFileLock(
                    path: hostExecutionAdmissionLockPath(
                        hostBuildRoot: application.workspace.hostBuildRoot,
                        provisionedMachineLease: provisionedHostExecutionLease),
                    purpose: "Collider host execution admission",
                    resource: "host execution admission",
                    run: run,
                    registry: registry,
                    cancellation: cancellation)
            }
            // Planning resolves every declared tool, so the pinned host tools
            // must exist before it runs rather than being produced by it.
            if workspaceCommand.presentationKind == .taskGraph {
                try await stageHostToolchain(in: application.workspace)
            }
            if workspaceCommand.presentationKind == .phase {
                try await hostPhases.withPhase(commandPhaseName(arguments)) {
                    try await workspaceCommand.run(in: application.workspace)
                }
            } else {
                try await workspaceCommand.run(in: application.workspace)
            }
            await application.runtime.shutdown()
            try rejectSupersededSource(
                sourceAtStart,
                workspace: workspace,
                environment: environment)
            if let run = application.run {
                try await application.registry.finish(run, status: .succeeded)
                await observationTask?.value
                if !suppressTerminalSummary {
                    try await reportTerminalSummary(
                        run: run,
                        application: application,
                        console: console,
                        suppressHumanSummary: suppressHumanSummary)
                }
            }
        } catch let cleanExit as CleanExit {
            await application.runtime.shutdown()
            if let run = application.run {
                try? await application.registry.finish(
                    run,
                    status: .succeeded)
                await observationTask?.value
                if !suppressTerminalSummary {
                    try? await reportTerminalSummary(
                        run: run,
                        application: application,
                        console: console,
                        suppressHumanSummary: suppressHumanSummary)
                }
            }
            throw cleanExit
        } catch {
            await application.runtime.shutdown()
            let wasInterrupted = await application.cancellation.wasInterrupted()
            let interruptionSignal =
                await application.cancellation.receivedInterruptionSignal()
            let sourceWasSuperseded = sourceIdentityChanged(
                sourceAtStart,
                workspace: workspace,
                environment: environment)
            let status =
                sourceWasSuperseded
                ? .superseded
                : commandFailureStatus(error, wasInterrupted: wasInterrupted)
            let contextualFailure = reportedExecutionFailure(
                error,
                status: status,
                runLogPath: application.run?.directory.appending("run.log").string)
            if let run = application.run, let contextualFailure {
                try? await application.registry.appendLog(
                    Array("Error: \(contextualFailure)\n".utf8),
                    in: run)
            }
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
                    status: status,
                    failedTask: contextualFailure?.task)
                await observationTask?.value
            }
            if let contextualFailure {
                try? console.failure(contextualFailure)
            }
            if let run = application.run {
                if !suppressTerminalSummary {
                    try? await reportTerminalSummary(
                        run: run,
                        application: application,
                        console: console,
                        suppressHumanSummary: suppressHumanSummary)
                }
            }
            throw commandExitCode(
                status: status,
                interruptionSignal: interruptionSignal)
        }
    }
}

private func commandPhaseName(_ arguments: [String]) -> String {
    let commandPath = arguments.prefix { !$0.hasPrefix("-") }
    return commandPath.isEmpty ? "collider" : commandPath.joined(separator: " ")
}

/// Refuses an invocation that would execute into a build store it cannot write.
///
/// A provisioned host has one store and one identity permitted to write it.
/// Without this check the invocation acquires admission, plans, and then fails
/// partway through on a permission error from somewhere deep in the graph. The
/// account is told instead, before any work, what does have write access.
/// Inspection never reaches here, so run and log reading stay available to the
/// group that can read the store.
func requireBuildStoreWriteAccess() throws {
    #if os(macOS)
    let store = MacOSMachineStorageLayout.buildStore
    guard MacOSMachineStorageLayout.buildStoreIsInstalled(),
        !FileManager.default.isWritableFile(atPath: store.string)
    else { return }
    throw WorkspaceFailure.message(
        "this account cannot write the machine build store at \(store); "
            + "run builds through \(MacOSMachineStorageLayout.builderLauncher)")
    #endif
}

/// The machine-wide execution lease, where a privileged provisioning step has
/// installed one. Only macOS builder hosts have one; on any other host a single
/// account runs Collider at all.
var provisionedHostExecutionLease: FilePath? {
    #if os(macOS)
    MacOSMachineStorageLayout.hostExecutionAdmission
    #else
    nil
    #endif
}

/// The lock that admits one Collider task graph to this host.
///
/// A provisioned builder host owns one root-created lock file at a neutral
/// machine path. Both the trusted builder identity and the interactive developer
/// can hold it and read its holder record, and neither can replace it, so host
/// execution serializes across accounts without either reading the other's
/// storage. A host without that file runs Collider from one account, whose
/// per-user state root carries the same lock.
///
/// Presence, not writability, selects the machine lease. A lease whose ownership
/// or mode has drifted must fail the acquisition loudly; falling back would
/// silently split one host's serialization into two independent halves.
func hostExecutionAdmissionLockPath(
    hostBuildRoot: FilePath,
    provisionedMachineLease: FilePath?
) -> FilePath {
    if let provisionedMachineLease,
        FileManager.default.fileExists(atPath: provisionedMachineLease.string)
    {
        return provisionedMachineLease
    }
    return hostBuildRoot.appending("state/locks/host-execution.lock")
}

private func reportTerminalSummary(
    run: RunHandle,
    application: ColliderApplicationComposition,
    console: CommandConsole,
    suppressHumanSummary: Bool
) async throws {
    let snapshot = try await application.registry.recordedRun(run.id)
    let observed = try await application.registry.reducedEvents(in: snapshot)
    let summary = RunTerminalSummary(
        snapshot: snapshot,
        observedState: observed)
    if console.progressPresentation == .machine {
        try console.completeProgress(summary)
        return
    }
    if suppressHumanSummary { return }
    if console.format == .text {
        try console.completeProgress(summary)
        return
    }
    try console.report(
        summary,
        text: summary.text,
        humanDestination: .standardError)
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

private struct SupersededSourceFailure: Error {}

private func revalidatedSourceSnapshot(
    workspace: FilePath,
    environment: [String: String]
) throws -> ProductArtifactSourceSnapshot? {
    guard environment["NUCLEUS_REVALIDATE_SOURCE"] == "1" else { return nil }
    return try ProductArtifactSourceSnapshot.capture(
        repositoryRoot: workspace,
        sourceAuthority: .localDevelopment)
}

private func sourceIdentityChanged(
    _ initial: ProductArtifactSourceSnapshot?,
    workspace: FilePath,
    environment: [String: String]
) -> Bool {
    guard let initial else { return false }
    guard
        let current = try? revalidatedSourceSnapshot(
            workspace: workspace,
            environment: environment)
    else { return true }
    return sourceIdentityWasSuperseded(initial, current)
}

func sourceIdentityWasSuperseded(
    _ initial: ProductArtifactSourceSnapshot?,
    _ current: ProductArtifactSourceSnapshot?
) -> Bool {
    guard let initial else { return false }
    guard let current else { return true }
    return current.closure != initial.closure
}

private func rejectSupersededSource(
    _ initial: ProductArtifactSourceSnapshot?,
    workspace: FilePath,
    environment: [String: String]
) throws {
    guard
        sourceIdentityChanged(
            initial,
            workspace: workspace,
            environment: environment)
    else { return }
    throw SupersededSourceFailure()
}

func recordedExecutionFailure(
    _ error: any Error,
    runLogPath: String?
) -> ExecutionFailure {
    let failure =
        (error as? ExecutionFailure)
        ?? ExecutionFailure(reason: String(describing: error))
    return failure.addingContext(logPath: runLogPath)
}

func reportedExecutionFailure(
    _ error: any Error,
    status: RunStatus,
    runLogPath: String?
) -> ExecutionFailure? {
    guard status == .failed else { return nil }
    return recordedExecutionFailure(error, runLogPath: runLogPath)
}

func commandExitCode(
    status: RunStatus,
    interruptionSignal: Int32?
) -> ExitCode {
    guard status == .interrupted else { return .failure }
    return ExitCode(128 + (interruptionSignal ?? SIGINT))
}
