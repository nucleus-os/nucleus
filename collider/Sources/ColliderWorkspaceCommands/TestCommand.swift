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

    @Option(
        name: .customLong("filter"),
        help: ArgumentHelp(
            "Run only the tests whose names match this pattern. A filtered run "
                + "is a distinct task from the unfiltered one, so it never "
                + "records the component's full test task as satisfied."))
    var filter: String?

    mutating func run(in context: WorkspaceContext) async throws {
        var controls = taskOptions.controls
        controls.testFilter = filter
        try await context.withExclusiveVerification {
            try await ComponentRegistry(context: context).test(
                selection: component, controls: controls)
        }
    }
}
