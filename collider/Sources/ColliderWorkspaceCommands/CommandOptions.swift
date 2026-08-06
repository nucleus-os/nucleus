import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

package struct RunIDArgument: ExpressibleByArgument, Equatable, Sendable {
    package let value: RunID

    package init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        value = RunID(rawValue: argument)
    }
}

package struct TaskControlOptions: ParsableArguments {
    @Flag(help: "Print the resolved task graph without executing it.")
    package var dryRun = false

    @Flag(help: "Rebuild the selected tasks while reusing clean prerequisites.")
    package var rebuild = false

    @Flag(help: "Print each leaf command before executing it.")
    package var verbose = false

    @Flag(help: "Keep task output in the durable run log without streaming it.")
    package var quiet = false

    @Flag(help: "Emit stable machine-readable records.")
    package var json = false

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
            json: json)
    }
}

package protocol ResumableRun {
    var requestedRunID: RunID? { get }
}

package protocol TaskControlledCommand: AsyncParsableCommand, ResumableRun {
    var taskOptions: TaskControlOptions { get set }
}

extension TaskControlledCommand {
    package var requestedRunID: RunID? { taskOptions.runID?.value }
}

package func requestedRunID(for command: any ParsableCommand) -> RunID? {
    (command as? any ResumableRun)?.requestedRunID
}

struct ReportOptions: ParsableArguments {
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
}

package func context() throws -> WorkspaceContext { try WorkspaceContext.load() }
