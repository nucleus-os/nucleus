import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Test: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(
        help: """
            all, runtime, android, browser, loader, gpu-headless, gpu-drm, \
            or a component name.
            """)
    var component: String?

    mutating func run() async throws {
        let workspace = try context()
        try await workspace.withExclusiveVerification {
            try await ComponentRegistry(context: workspace).test(
                selection: component, controls: taskOptions.controls)
        }
    }
}
