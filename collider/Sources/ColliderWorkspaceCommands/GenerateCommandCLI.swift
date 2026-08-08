import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Generate: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "Generator target: vulkan or wayland.")
    var target: String

    mutating func run(in context: WorkspaceContext) async throws {
        try await ComponentRegistry(context: context).generate(
            target, controls: taskOptions.controls)
    }
}
