import ArgumentParser
import CoreColliderRecipe

enum AndroidOperation: Equatable, ExpressibleByArgument {
    case build
    case native
    case verify

    init?(argument: String) {
        switch argument {
        case "build":
            self = .build
        case "native":
            self = .native
        case "verify":
            self = .verify
        default:
            return nil
        }
    }

    var defaultValueDescription: String {
        switch self {
        case .build: "build"
        case .native: "native"
        case .verify: "verify"
        }
    }
}

struct AndroidCommand {
    let context: WorkspaceContext

    func run(
        _ operation: AndroidOperation,
        controls: TaskControls = TaskControls()
    ) async throws {
        let registry = ComponentRegistry(context: context)
        switch operation {
        case .build:
            try await registry.runAndroid(
                CoreEntrypoints.androidBuild,
                controls: controls)
        case .native:
            try await registry.runAndroid(
                CoreEntrypoints.androidNative,
                controls: controls)
        case .verify:
            try await registry.runAndroid(
                CoreEntrypoints.androidVerify,
                controls: controls)
        }
    }
}
