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
    @Flag(help: "Emit stable machine-readable records.")
    var json = false
    @Argument(
        help:
            "Prerequisite group: all, runtime, swift-sdk, android, browser, or ci-macos-builder.")
    var scope: DoctorScope = .all

    mutating func run(in context: WorkspaceContext) async throws {
        try await WorkspaceDoctor(context: context).run(
            scope: scope,
            dryRun: dryRun,
            json: json)
    }
}
