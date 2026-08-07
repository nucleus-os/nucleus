import ArgumentParser
import ColliderCore
import ColliderRuntime
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

struct Run: ColliderWorkspaceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build, install, and launch a compositor session.")
    @OptionGroup var options: RunOptions

    mutating func validate() throws {
        do {
            _ = try options.validated()
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run(in context: WorkspaceContext) async throws {
        try await RunCommand(context: context).run(
            try options.validated())
    }

}
