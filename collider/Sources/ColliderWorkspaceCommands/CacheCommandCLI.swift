import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Cache: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and explicitly reclaim Collider-owned generated storage.",
        subcommands: [Status.self, Prune.self])
    struct Status: ColliderInspectionCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Report ownership, retention, allocation, and reclaimability for declared storage.")
        @Flag(
            name: .customLong("measure-allocations"),
            help:
                "Recursively measure declared storage allocation; this can be expensive for large source and compiler trees."
        )
        var measureAllocations = false
        @OptionGroup var outputOptions: CommandOutputOptions
        mutating func run(in context: WorkspaceContext) async throws {
            let catalog = try ComponentRegistry(context: context).componentCatalog()
            try await RepositoryCache(
                context: context,
                catalog: catalog
            ).status(measureAllocations: measureAllocations)
        }
    }
    struct Prune: ColliderWorkspaceCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Remove stale run records, abandoned Swift SDK candidates, and dangling OCI images."
        )
        @Flag(help: "Print removals without applying them.")
        var dryRun = false
        @OptionGroup var outputOptions: CommandOutputOptions

        var requiresExecutionAdmission: Bool { !dryRun }

        mutating func run(in context: WorkspaceContext) async throws {
            let catalog = try ComponentRegistry(context: context).componentCatalog()
            try await RepositoryCache(
                context: context,
                catalog: catalog
            ).prune(dryRun: dryRun)
        }
    }
}
