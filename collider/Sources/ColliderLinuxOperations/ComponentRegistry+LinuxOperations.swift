import ColliderCore
import ColliderWorkspaceCommands
import ShellColliderRecipe
import SystemPackage

extension ComponentRegistry {
    func buildTracyReceivers(
        controls: TaskControls = TaskControls()
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .bootstrap,
                    selection: "tracy")
            ],
            controls: controls)
    }

    func publishDevelopmentRuntime(
        prefix: FilePath,
        selection: RuntimeBuildSelection,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = try shellRuntimePublicationConfiguration(
            prefix: prefix,
            selection: selection)
        let catalog = try componentCatalog(
            hostAugmentation: .linux(shellConfiguration: configuration))
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .install,
                    selection: ShellColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }
}
