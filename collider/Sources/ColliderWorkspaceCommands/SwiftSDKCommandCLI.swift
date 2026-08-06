import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct SwiftSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-sdk",
        abstract: "Build and inspect Nucleus Swift SDK artifacts.",
        subcommands: [Rebuild.self, Status.self])

    struct Rebuild: TaskControlledCommand {
        @OptionGroup var taskOptions: TaskControlOptions

        var rebuildOptions: RebuildOptions {
            RebuildOptions(controls: taskOptions.controls)
        }

        mutating func run() async throws {
            try await SwiftSDKCommand(context: context()).rebuild(
                rebuildOptions)
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        mutating func run() async throws {
            try SwiftSDKStatus(context: context()).run(
                json: reportOptions.json)
        }
    }
}
