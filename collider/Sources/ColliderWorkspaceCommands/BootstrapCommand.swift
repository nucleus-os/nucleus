import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Bootstrap: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, browser, or a component name.")
    var component: String?

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).bootstrap(
            selection: component, controls: taskOptions.controls)
    }
}
