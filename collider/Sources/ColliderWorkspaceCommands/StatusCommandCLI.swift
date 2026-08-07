import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Status: ColliderWorkspaceCommand {
    @OptionGroup var reportOptions: ReportOptions
    mutating func run(in context: WorkspaceContext) async throws {
        try RepositoryState(context: context).printStatus(
            json: reportOptions.json)
    }
}
