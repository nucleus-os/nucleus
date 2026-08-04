import ArgumentParser
import QualificationColliderRecipe

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
        let catalog = try ComponentRegistry(context: context).componentCatalog()
        let selected = try selection.sanitizers.flatMap { sanitizer in
            try catalog.roots(
                named: sanitizer.entrypoint,
                selection: SanitizerColliderRecipe.descriptor.canonicalName)
        }
        try await context.execute(
            tasks: catalog.tasks,
            selected: selected,
            controls: controls)
    }
}
