import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime

struct BrowserInstallCommand {
    let context: WorkspaceContext

    func run(
        controls: TaskControls = TaskControls(),
        installPrefix: String? = nil
    ) async throws {
        if !controls.dryRun {
            try await WorkspaceDoctor(context: context).run(
                scope: .browser,
                dryRun: false,
                quiet: true)
        }
        var environment = context.taskEnvironment
        if let installPrefix {
            environment["PREFIX"] = installPrefix
        }
        let catalog = try ComponentRegistry(context: context).componentCatalog(
            environment: environment)
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .install,
                    selection: ChromiumColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }
}
