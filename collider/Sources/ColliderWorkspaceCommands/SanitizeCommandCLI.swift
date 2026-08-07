import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Sanitize: TaskControlledCommand {
    @Argument var selection: SanitizerSelection = .all
    mutating func run(in context: WorkspaceContext) async throws {
        try await context.withExclusiveVerification {
            try await SanitizerCommand(context: context).run(
                selection, controls: taskOptions.controls)
        }
    }

    @OptionGroup var taskOptions: TaskControlOptions
}
