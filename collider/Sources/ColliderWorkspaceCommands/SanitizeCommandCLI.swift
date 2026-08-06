import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Sanitize: TaskControlledCommand {
    @Argument var selection: SanitizerSelection = .all
    mutating func run() async throws {
        let workspace = try context()
        try await workspace.withExclusiveVerification {
            try await SanitizerCommand(context: workspace).run(
                selection, controls: taskOptions.controls)
        }
    }

    @OptionGroup var taskOptions: TaskControlOptions
}
