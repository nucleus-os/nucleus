import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [
        Vulkan.self, Wayland.self,
    ])
    struct Vulkan: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run(in context: WorkspaceContext) async throws {
            try await runGenerator("vulkan", context: context, taskOptions: taskOptions)
        }
    }
    struct Wayland: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run(in context: WorkspaceContext) async throws {
            try await runGenerator("wayland", context: context, taskOptions: taskOptions)
        }
    }
}

private func runGenerator(
    _ component: String,
    context: WorkspaceContext,
    taskOptions: TaskControlOptions
) async throws {
    try await ComponentRegistry(context: context).generate(
        component, controls: taskOptions.controls)
}
