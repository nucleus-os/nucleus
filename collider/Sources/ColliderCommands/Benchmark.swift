import ColliderCore
import QualificationColliderRecipe

struct BenchmarkCommand {
    let context: WorkspaceContext

    func run(controls: TaskControls) async throws {
        let catalog = try ComponentRegistry(context: context).componentCatalog()
        try await context.execute(
            tasks: catalog.tasks,
            selected: try catalog.roots(
                named: .benchmark,
                selection: BenchmarkColliderRecipe.descriptor.canonicalName),
            controls: controls)
    }
}
