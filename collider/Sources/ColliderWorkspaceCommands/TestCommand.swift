import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Test: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(
        help: """
            all, runtime, collider, android, browser, loader, gpu-headless, \
            gpu-drm, or a component name.
            """)
    var component: String?

    mutating func run(in context: WorkspaceContext) async throws {
        try await context.withExclusiveVerification {
            try await ComponentRegistry(context: context).test(
                selection: component, controls: taskOptions.controls)
        }
    }
}
