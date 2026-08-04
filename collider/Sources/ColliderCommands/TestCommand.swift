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
    var component: ComponentSelection?

    mutating func run() async throws {
        let workspace = try context()
        if component == .android {
            try await workspace.withExclusiveVerification {
                try await AndroidCommand(context: workspace).run(
                    .build(gradleArguments: []),
                    controls: taskOptions.controls)
            }
            return
        }
        try await workspace.withExclusiveVerification {
            try await ComponentRegistry(context: workspace).test(
                selection: component, controls: taskOptions.controls)
        }
    }
}
