import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Cache: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and explicitly reclaim Collider-owned generated storage.",
        subcommands: [Status.self, Prune.self])
    struct Status: ColliderWorkspaceCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Report ownership, retention, allocation, and reclaimability for declared storage.")
        @OptionGroup var reportOptions: ReportOptions
        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryCache(context: context).status(
                json: reportOptions.json)
        }
    }
    struct Prune: ColliderWorkspaceCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove stale run records, abandoned Swift SDK candidates, and dangling OCI images."
        )
        @Flag(help: "Print removals without applying them.")
        var dryRun = false
        @Flag(help: "Emit stable machine-readable records.")
        var json = false
        @Option(name: .customLong("keep-runs"), help: "Number of recent completed runs to retain.")
        var keepRuns = 20

        mutating func validate() throws {
            guard keepRuns >= 0 else { throw ValidationError("--keep-runs must be nonnegative") }
        }

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryCache(context: context).prune(
                keepingRuns: keepRuns,
                dryRun: dryRun,
                json: json)
        }
    }
}
