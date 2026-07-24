import ArgumentParser

enum AndroidOperation: Equatable, ExpressibleByArgument {
    case build(gradleArguments: [String])
    case native
    case verify(library: String?)

    init?(argument: String) {
        switch argument {
        case "build":
            self = .build(gradleArguments: [])
        case "native":
            self = .native
        case "verify":
            self = .verify(library: nil)
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
    ) throws {
        let registry = ComponentRegistry(context: context)
        switch operation {
        case .build(let gradleArguments):
            try registry.buildAndroidHost(
                gradleArguments: gradleArguments,
                controls: controls)
        case .native:
            try registry.buildAndroidNative(controls: controls)
        case .verify(let library):
            try registry.validateAndroidHost(
                library: library,
                controls: controls)
        }
    }
}
