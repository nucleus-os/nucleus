import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Show.self, Tail.self])
    struct List: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Option var kind: String?
        mutating func run(in context: WorkspaceContext) async throws {
            try RepositoryState(context: context).list(kind: kind)
        }
    }
    struct Show: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run(in context: WorkspaceContext) async throws {
            try RepositoryState(context: context).show(runID, kind: kind)
        }
    }
    struct Tail: ColliderWorkspaceCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).tail(
                runID,
                kind: kind)
        }
    }
}
