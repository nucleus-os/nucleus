import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Android: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Build.self, Native.self, Verify.self])

    struct Build: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        var operation: AndroidOperation { .build }

        mutating func run(in context: WorkspaceContext) async throws {
            try await AndroidCommand(context: context).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Native: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var operation: AndroidOperation { .native }

        mutating func run(in context: WorkspaceContext) async throws {
            try await AndroidCommand(context: context).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Verify: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        var operation: AndroidOperation { .verify }

        mutating func run(in context: WorkspaceContext) async throws {
            try await AndroidCommand(context: context).run(
                operation,
                controls: taskOptions.controls)
        }
    }
}
