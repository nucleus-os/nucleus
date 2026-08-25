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
            // An informational command reports and exits through `CleanExit`
            // rather than composing an application. Async ones are run as
            // such: `ParsableCommand` supplies a synchronous `run()` that
            // requests help, so dispatching an `AsyncParsableCommand` through
            // the synchronous path silently prints usage instead of running
            // it.
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var informationalCommand = command
                try informationalCommand.run()
            }
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
        // write into the store this account may not be permitted to make. The
        // command does not fail here: it continues as the identity that may.
        if workspaceCommand.requiresBuilderIdentity,
            !BuilderElevation.executesDirectly()
        {
            #if os(macOS)
            try BuilderElevation.reexecuteAsBuilder(
                arguments: arguments,
                workspaceRoot: workspace)
            #endif
        }
        let registry = RunRegistry(
            root: nucleusRunRegistryRoot(workspaceRoot: workspace))
        if workspaceCommand.recordsRun {
            try await registry.reconcileAbandonedRuns()
        }
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
                        command: [CommandLine.arguments[0]] + arguments,
                        provenance: ProtectedMainSourceAssertion.runProvenance(
                            environment: processEnvironment))
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
        let revalidation = sourceRevalidation(environment: environment)
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
                sourceRevalidation: revalidation,
                ociConfiguration: ociConfiguration),
            signals: signals)
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
            try await rejectSupersededSource(revalidation)
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
            // The success path already revalidated to raise this; asking
            // again would repeat every Git read it took to answer.
            let superseded: [PlannedSourceClosure]
            if let failure = error as? SupersededSourceFailure {
                superseded = failure.closures
            } else {
                superseded = await supersedingSourceClosures(revalidation)
            }
            let status =
                superseded.isEmpty
                ? commandFailureStatus(error, wasInterrupted: wasInterrupted)
                : .superseded
            let contextualFailure = reportedExecutionFailure(
                error,
                status: status,
                runLogPath: application.run?.directory.appending("run.log").string)
            if let run = application.run, let contextualFailure {
                try? await application.registry.appendLog(
                    Array("Error: \(contextualFailure)\n".utf8),
                    in: run)
            }
            // A superseded run says which source moved under it. Nothing else
            // records that, and "superseded" alone leaves the reader to guess
            // between an edit they made and one they did not.
            if status == .superseded, let run = application.run {
                try? await application.registry.appendLog(
                    Array(
                        ("Superseded: "
                            + SupersededSourceFailure(closures: superseded)
                                .description).utf8),
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

struct SupersededSourceFailure: Error, CustomStringConvertible {
    let closures: [PlannedSourceClosure]

    /// A closure is hashed as a whole, so a closure of one path says which
    /// path changed and a closure of several says only that something in it
    /// did. Claiming every path in a closure changed would overstate what was
    /// measured.
    var description: String {
        "source this run consumed changed while it ran\n"
            + closures.map { closure in
                let paths = closure.paths.map(\.string).joined(separator: ", ")
                return closure.paths.count == 1
                    ? "  changed: \(paths)\n"
                    : "  changed within: \(paths)\n"
            }.joined()
    }
}

/// Collects what each plan reads, or nothing when this invocation does not
/// revalidate.
///
/// A run is superseded by a change to source it consumed. What it consumed is
/// what its plans read, which planning digests as it freezes each plan, so
/// there is nothing to collect until a plan exists and nothing to compare for
/// a command that plans nothing.
private func sourceRevalidation(
    environment: [String: String]
) -> SourceRevalidation? {
    guard environment["NUCLEUS_REVALIDATE_SOURCE"] == "1" else { return nil }
    return SourceRevalidation()
}

private func supersedingSourceClosures(
    _ revalidation: SourceRevalidation?
) async -> [PlannedSourceClosure] {
    guard let revalidation else { return [] }
    return await revalidation.supersedingClosures()
}

private func rejectSupersededSource(
    _ revalidation: SourceRevalidation?
) async throws {
    let superseded = await supersedingSourceClosures(revalidation)
    guard !superseded.isEmpty else { return }
    throw SupersededSourceFailure(closures: superseded)
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
