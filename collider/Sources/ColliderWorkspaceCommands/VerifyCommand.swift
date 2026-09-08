import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Verify: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, or a runtime component name.")
    var component: String?

    var requiresExclusiveVerification: Bool { requiresExecutionAdmission }

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).verify(
            selection: component,
            controls: taskOptions.controls)
    }
}
