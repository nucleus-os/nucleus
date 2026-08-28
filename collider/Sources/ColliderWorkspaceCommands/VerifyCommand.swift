import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Verify: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, or a runtime component name.")
    var component: String?

    mutating func run(in context: WorkspaceContext) async throws {
        if taskOptions.dryRun {
            try await ComponentRegistry(context: context).verify(
                selection: component,
                controls: taskOptions.controls)
            return
        }
        try await context.withExclusiveVerification {
            try await ComponentRegistry(context: context).verify(
                selection: component,
                controls: taskOptions.controls)
        }
    }
}
