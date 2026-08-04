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
        @Argument(parsing: .postTerminator) var arguments: [String] = []

        var operation: AndroidOperation {
            .build(gradleArguments: arguments)
        }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Native: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var operation: AndroidOperation { .native }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
    struct Verify: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        @Argument var library: String?

        var operation: AndroidOperation {
            .verify(library: library)
        }

        mutating func run() async throws {
            try await AndroidCommand(context: context()).run(
                operation,
                controls: taskOptions.controls)
        }
    }
}
