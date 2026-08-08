import ArgumentParser

struct Clean: ColliderWorkspaceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a component's graph-declared rebuildable storage.")

    @Argument(help: "Canonical component name or alias.")
    var component: String

    @Flag(help: "Print exact resolved removals without applying them.")
    var dryRun = false

    @Flag(help: "Emit stable machine-readable records.")
    var json = false

    mutating func run(in context: WorkspaceContext) async throws {
        let catalog = try ComponentRegistry(context: context).componentCatalog()
        try await RepositoryCache(context: context, catalog: catalog).clean(
            component: component,
            dryRun: dryRun,
            json: json)
    }
}
