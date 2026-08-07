import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Browser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Doctor.self, Bootstrap.self, Build.self, Test.self])

    struct Doctor: ColliderWorkspaceCommand {
        @Flag(help: "Print the resolved browser checks without executing them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false

        mutating func run(in context: WorkspaceContext) async throws {
            try await ChromiumCommand(context: context).run(
                .doctor,
                controls: TaskControls(dryRun: dryRun, json: json))
        }
    }
    struct Bootstrap: BrowserTaskLeaf {
        static let operation = ChromiumOperation.bootstrap
        @OptionGroup var taskOptions: TaskControlOptions
    }
    struct Build: BrowserTaskLeaf {
        static let operation = ChromiumOperation.build
        @OptionGroup var taskOptions: TaskControlOptions
    }
    struct Test: BrowserTaskLeaf {
        static let operation = ChromiumOperation.test
        @OptionGroup var taskOptions: TaskControlOptions
    }
}

protocol BrowserTaskLeaf: TaskControlledCommand {
    static var operation: ChromiumOperation { get }
}

extension BrowserTaskLeaf {
    mutating func run(in context: WorkspaceContext) async throws {
        try await ChromiumCommand(context: context).run(
            Self.operation,
            controls: taskOptions.controls)
    }
}
