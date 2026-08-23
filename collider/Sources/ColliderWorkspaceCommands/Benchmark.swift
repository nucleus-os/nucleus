import ColliderCore

struct BenchmarkCommand {
    let context: WorkspaceContext

    func run(controls: TaskControls) async throws {
        let catalog = try await ComponentRegistry(context: context).componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: BenchmarkEntrypoints.run,
                    selection: BenchmarkColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }
}
