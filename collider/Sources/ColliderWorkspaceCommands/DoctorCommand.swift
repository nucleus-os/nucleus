import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Doctor: ColliderWorkspaceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report missing tools and repository prerequisites.")
    @Flag(help: "Print the resolved checks without executing them.")
    var dryRun = false
    @OptionGroup var outputOptions: CommandOutputOptions
    @Argument(
        help:
            "Prerequisite group: all, runtime, swift-sdk, android, browser, or ci-macos-builder.")
    var scope: DoctorScope = .all

    var requiresExecutionAdmission: Bool { false }

    mutating func run(in context: WorkspaceContext) async throws {
        try await WorkspaceDoctor(context: context).run(
            scope: scope,
            dryRun: dryRun)
    }
}
