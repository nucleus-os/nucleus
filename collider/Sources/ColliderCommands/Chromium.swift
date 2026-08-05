import ArgumentParser
import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime

enum ChromiumOperation: String, CaseIterable, ExpressibleByArgument {
    case doctor
    case bootstrap
    case build
    case test
    case install
}

struct ChromiumCommand {
    let context: WorkspaceContext

    func run(
        _ operation: ChromiumOperation,
        controls: TaskControls = TaskControls(),
        installPrefix: String? = nil
    ) async throws {
        if operation == .doctor {
            try await WorkspaceDoctor(context: context).run(
                scope: .browser,
                dryRun: controls.dryRun,
                json: controls.json)
            return
        }
        if !controls.dryRun {
            try await WorkspaceDoctor(context: context).run(
                scope: .browser,
                dryRun: false,
                json: false,
                quiet: true)
        }
        var environment = context.taskEnvironment
        if let installPrefix {
            environment["PREFIX"] = installPrefix
        }
        let catalog = try ComponentRegistry(context: context).componentCatalog(
            environment: environment)
        let entrypoint =
            switch operation {
            case .doctor: preconditionFailure("doctor handled by capability registry")
            case .bootstrap: ComponentEntrypointID.bootstrap
            case .build: ComponentEntrypointID.build
            case .test: ComponentEntrypointID.testDefault
            case .install: ComponentEntrypointID.install
            }
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: entrypoint,
                    selection: ChromiumColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }
}
