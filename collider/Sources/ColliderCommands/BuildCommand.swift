import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Build: TaskControlledCommand {
    @OptionGroup var taskOptions: TaskControlOptions
    @Argument(help: "all, runtime, swift-sdk, android, browser, or a component name.")
    var component: ComponentSelection?

    mutating func run() async throws {
        let workspace = try context()
        switch component {
        case .swiftSDK:
            try await SwiftSDKCommand(context: workspace).rebuild(
                RebuildOptions(controls: taskOptions.controls))
        case .android:
            try await AndroidCommand(context: workspace).run(
                .build(gradleArguments: []),
                controls: taskOptions.controls)
        case .browser:
            try await ChromiumCommand(context: workspace).run(
                .build,
                controls: taskOptions.controls)
        case .none, .all, .runtime, .tracy, .vulkan, .wayland, .core, .config, .ipc,
            .linux, .reactNative, .compositor, .shell, .androidRuntime, .loader,
            .gpuHeadless, .gpuDRM:
            try await ComponentRegistry(context: workspace).build(
                selection: component, controls: taskOptions.controls)
        }
    }
}
