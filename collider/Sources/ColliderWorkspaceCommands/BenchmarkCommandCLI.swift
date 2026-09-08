import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Benchmark: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions

    var requiresExclusiveVerification: Bool { requiresExecutionAdmission }

    mutating func run(in context: WorkspaceContext) async throws {
        try await BenchmarkCommand(context: context).run(
            controls: taskOptions.controls)
    }
}
