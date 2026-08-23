import ArgumentParser
import ColliderCore

extension SanitizerKind: ExpressibleByArgument {}

enum SanitizerSelection: String, CaseIterable, ExpressibleByArgument {
    case all
    case address
    case undefined
    case thread

    var sanitizers: [SanitizerKind] {
        switch self {
        case .all: SanitizerKind.allCases
        case .address: [.address]
        case .undefined: [.undefined]
        case .thread: [.thread]
        }
    }
}

struct SanitizerCommand {
    let context: WorkspaceContext

    func run(
        _ selection: SanitizerSelection,
        controls: TaskControls
    ) async throws {
        let catalog = try await ComponentRegistry(context: context).componentCatalog()
        let requests = selection.sanitizers.map { sanitizer in
            ComponentEntrypointRequest(
                entrypoint: sanitizer.entrypoint,
                selection: SanitizerColliderRecipe.descriptor.canonicalName)
        }
        try await context.execute(
            catalog: catalog,
            requests: requests,
            controls: controls)
    }
}
