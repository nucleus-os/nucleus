import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Benchmark: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions

    mutating func run(in context: WorkspaceContext) async throws {
        try await context.withExclusiveVerification {
            try await BenchmarkCommand(context: context).run(
                controls: taskOptions.controls)
        }
    }
}
