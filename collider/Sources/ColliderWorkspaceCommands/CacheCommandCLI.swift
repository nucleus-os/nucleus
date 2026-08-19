import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct Cache: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and explicitly reclaim Collider-owned generated storage.",
        subcommands: [Status.self, Prune.self, Reclaim.self])
    struct Status: ColliderWorkspaceCommand {
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
        var requiresExecutionAdmission: Bool { false }
        /// Measuring reaches the container service, which answers only in the
        /// builder's session. Reporting without measuring reads the filesystem
        /// and stays wherever it was invoked.
        var requiresBuilderIdentity: Bool { measureAllocations }
        mutating func run(in context: WorkspaceContext) async throws {
            let catalog = try ComponentRegistry(context: context).componentCatalog()
            try await RepositoryCache(
                context: context,
                catalog: catalog
            ).status(measureAllocations: measureAllocations)
        }
    }
    /// Reclamation removes nothing: it returns blocks a workspace already
    /// freed internally but still holds, because its filesystem is mounted
    /// without a discard option. It is separate from pruning for that reason.
    struct Reclaim: ColliderWorkspaceCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Return blocks freed inside persistent workspaces to the host filesystem.")
        @Flag(help: "Report the workspaces that would be trimmed without trimming them.")
        var dryRun = false
        @OptionGroup var outputOptions: CommandOutputOptions

        var requiresExecutionAdmission: Bool { !dryRun }

        mutating func run(in context: WorkspaceContext) async throws {
            let catalog = try ComponentRegistry(context: context).componentCatalog()
            try await RepositoryCache(
                context: context,
                catalog: catalog
            ).reclaim(dryRun: dryRun)
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
