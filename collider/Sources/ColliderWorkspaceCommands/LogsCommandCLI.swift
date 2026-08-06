import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Show.self, Tail.self])
    struct List: AsyncParsableCommand {
        @OptionGroup var reportOptions: ReportOptions
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try RepositoryState(context: workspace).list(
                kind: kind,
                json: reportOptions.json)
        }
    }
    struct Show: AsyncParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try RepositoryState(context: workspace).show(runID, kind: kind)
        }
    }
    struct Tail: AsyncParsableCommand {
        @Argument var runID: String?
        @Option var kind: String?
        mutating func run() async throws {
            let workspace = try context()
            try await RepositoryState(context: workspace).tail(
                runID,
                kind: kind)
        }
    }
}
