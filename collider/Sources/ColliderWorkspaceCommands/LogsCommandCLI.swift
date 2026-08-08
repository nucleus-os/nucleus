import ArgumentParser
import Foundation

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect durable run and task logs.",
        subcommands: [List.self, Path.self, Tail.self])

    struct List: ColliderInspectionCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument(help: "Run identifier, or latest.") var runID: String?

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).listLogs(runID)
        }
    }

    struct Path: ColliderInspectionCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument(help: "Run identifier, or latest.") var runID: String?
        @Option(help: "Select a task stage log instead of the complete run log.")
        var task: String?

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).reportLogPath(
                runID, task: task)
        }
    }

    struct Tail: ColliderInspectionCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument(help: "Run identifier, or latest.") var runID: String?
        @Option(help: "Select a task stage log instead of the complete run log.")
        var task: String?
        @Option(name: .shortAndLong, help: "Number of trailing lines to print.")
        var lines = 200
        @Flag(help: "Continue following appended output.") var follow = false

        mutating func validate() throws {
            guard lines > 0 else { throw ValidationError("--lines must be positive") }
            guard outputOptions.format == .text else {
                throw ValidationError("logs tail emits raw text and does not support JSON")
            }
        }

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).tail(
                runID,
                task: task,
                lineCount: lines,
                follow: follow)
        }
    }
}
