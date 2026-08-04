import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Benchmark: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    mutating func run() async throws {
        let workspace = try context()
        try await workspace.withExclusiveVerification {
            try await BenchmarkCommand(context: workspace).run(
                controls: taskOptions.controls)
        }
    }
}
