import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [
        RNSpec.self, Vulkan.self, Wayland.self,
    ])
    struct RNSpec: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.reactNative, taskOptions: taskOptions)
        }
    }
    struct Vulkan: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.vulkan, taskOptions: taskOptions)
        }
    }
    struct Wayland: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions
        mutating func run() async throws {
            try await runGenerator(.wayland, taskOptions: taskOptions)
        }
    }
}

private func runGenerator(
    _ component: GeneratorComponent,
    taskOptions: TaskControlOptions
) async throws {
    try await ComponentRegistry(context: context()).generate(
        component, controls: taskOptions.controls)
}
