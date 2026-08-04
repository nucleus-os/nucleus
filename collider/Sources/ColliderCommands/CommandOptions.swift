import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct RunIDArgument: ExpressibleByArgument, Equatable, Sendable {
    let value: RunID

    init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        value = RunID(rawValue: argument)
    }
}

struct TaskControlOptions: ParsableArguments {
    @Flag(help: "Print the resolved task graph without executing it.")
    var dryRun = false

    @Flag(help: "Rebuild the selected tasks while reusing clean prerequisites.")
    var rebuild = false

    @Flag(help: "Explain why each selected task is clean or dirty.")
    var explain = false

    @Flag(help: "Print each leaf command before executing it.")
    var verbose = false

    @Flag(help: "Keep task output in the durable run log without streaming it.")
    var quiet = false

    @Flag(help: "Emit stable machine-readable records.")
    var json = false

    @Option(name: .customLong("run-id"), help: "Resume an interrupted run.")
    var runID: RunIDArgument?

    mutating func validate() throws {
        guard !quiet || !verbose else {
            throw ValidationError("--quiet and --verbose are mutually exclusive")
        }
    }

    var controls: TaskControls {
        TaskControls(
            dryRun: dryRun,
            rebuild: rebuild,
            explain: explain,
            verbose: verbose,
            quiet: quiet,
            json: json)
    }
}

protocol ResumableRun {
    var requestedRunID: RunID? { get }
}

protocol TaskControlledCommand: AsyncParsableCommand, ResumableRun {
    var taskOptions: TaskControlOptions { get set }
}

extension TaskControlledCommand {
    var requestedRunID: RunID? { taskOptions.runID?.value }
}

func requestedRunID(for command: any ParsableCommand) -> RunID? {
    (command as? any ResumableRun)?.requestedRunID
}

struct ReportOptions: ParsableArguments {
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
}

func context() throws -> WorkspaceContext { try WorkspaceContext.load() }
