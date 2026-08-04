import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Build: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, swift-sdk, android, browser, or a component name.")
    var component: String?

    mutating func run() async throws {
        let workspace = try context()
        try await ComponentRegistry(context: workspace).build(
            selection: component, controls: taskOptions.controls)
    }
}
