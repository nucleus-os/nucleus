import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

extension ConsoleOutputFormat: ExpressibleByArgument {}
extension ConsoleColorPolicy: ExpressibleByArgument {}
extension ConsoleProgressPolicy: ExpressibleByArgument {}
extension ConsoleProgressFormat: ExpressibleByArgument {}

package struct CommandOutputOptions: ParsableArguments, Sendable {
    @Option(help: "Output format.")
    package var format: ConsoleOutputFormat = .text

    @Option(help: "Color policy for human output.")
    package var color: ConsoleColorPolicy = .auto

    @Option(help: "Progress rendering policy.")
    package var progress: ConsoleProgressPolicy = .auto

    @Option(name: .customLong("progress-format"), help: "Progress stream format.")
    package var progressFormat: ConsoleProgressFormat?

    package init() {}
}

package struct RunIDArgument: ExpressibleByArgument, Equatable, Sendable {
    package let value: RunID

    package init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        value = RunID(rawValue: argument)
    }
}

package struct TaskControlOptions: ParsableArguments {
    @OptionGroup package var outputOptions: CommandOutputOptions

    @Flag(help: "Print the resolved task graph without executing it.")
    package var dryRun = false

    @Flag(help: "Rebuild the selected tasks while reusing clean prerequisites.")
    package var rebuild = false

    @Flag(help: "Print each leaf command before executing it.")
    package var verbose = false

    @Flag(help: "Keep task output in the durable run log without streaming it.")
    package var quiet = false

    @Option(name: .customLong("run-id"), help: "Resume an interrupted run.")
    package var runID: RunIDArgument?

    package init() {}

    package mutating func validate() throws {
        guard !quiet || !verbose else {
            throw ValidationError("--quiet and --verbose are mutually exclusive")
        }
    }

    package var controls: TaskControls {
        TaskControls(
            dryRun: dryRun,
            rebuild: rebuild,
            verbose: verbose,
            quiet: quiet,
            format: outputOptions.format)
    }
}

package protocol ResumableRun {
    var requestedRunID: RunID? { get }
}

package protocol OutputConfiguredCommand {
    var outputOptions: CommandOutputOptions { get }
}

package protocol ColliderWorkspaceCommand: AsyncParsableCommand, OutputConfiguredCommand {
    var presentationKind: CommandPresentationKind { get }
    var recordsRun: Bool { get }
    var requiresExecutionAdmission: Bool { get }
    /// Whether this command must run as the identity that owns the build store.
    ///
    /// Distinct from admission: one says which account executes, the other says
    /// whether the host may execute anything else at the same time. Executing a
    /// task graph needs both. Measuring what persistent workspaces allocate
    /// needs only the first, because the container service answering that
    /// question lives in the builder's session while the question itself
    /// changes nothing and need not serialize against a running build.
    var requiresBuilderIdentity: Bool { get }
    mutating func run(in context: WorkspaceContext) async throws
}

extension ColliderWorkspaceCommand {
    package var presentationKind: CommandPresentationKind { .phase }
    package var recordsRun: Bool { true }
    package var requiresExecutionAdmission: Bool { true }
    package var requiresBuilderIdentity: Bool { requiresExecutionAdmission }

    package mutating func run() async throws {
        throw WorkspaceFailure.message(
            "Collider command execution requires application composition")
    }
}

package protocol ColliderInspectionCommand: ColliderWorkspaceCommand {}

extension ColliderInspectionCommand {
    package var presentationKind: CommandPresentationKind { .none }
    package var recordsRun: Bool { false }
    package var requiresExecutionAdmission: Bool { false }
}

package protocol TaskControlledCommand: ColliderWorkspaceCommand, ResumableRun {
    var taskOptions: TaskControlOptions { get set }
}

extension TaskControlledCommand {
    package var presentationKind: CommandPresentationKind { .taskGraph }
    package var requestedRunID: RunID? { taskOptions.runID?.value }
    package var outputOptions: CommandOutputOptions { taskOptions.outputOptions }
    package var requiresExecutionAdmission: Bool { !taskOptions.dryRun }
}

package func requestedRunID(for command: any ParsableCommand) -> RunID? {
    (command as? any ResumableRun)?.requestedRunID
}
