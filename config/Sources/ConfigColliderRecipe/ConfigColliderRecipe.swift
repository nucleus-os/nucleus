import ColliderCore
import SystemPackage

public enum ConfigColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "config.build",
            root,
            environment,
            [
                (root, ["build"]),
                (root.appending("model"), ["build"]),
                (root.appending("config-service-core"), ["build"]),
                (root.appending("config-service"), ["build"]),
            ],
            [],
            swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "config.test",
            root,
            environment,
            [
                (root, ["test"]),
                (root.appending("model"), ["test"]),
                (root.appending("config-service-core"), ["test"]),
                (root.appending("config-service"), ["build"]),
            ],
            [TaskID(rawValue: "config.build")], swiftPM)
    }
}

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ commands: [(FilePath, [String])],
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "config"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            .tree(root.appending("Tests")),
            .file(root.appending("model/Package.swift")),
            .tree(root.appending("model/Sources")),
            .tree(root.appending("model/Tests")),
            .file(root.appending("config-service-core/Package.swift")),
            .tree(root.appending("config-service-core/Sources")),
            .tree(root.appending("config-service-core/Tests")),
            .file(root.appending("config-service/Package.swift")),
            .tree(root.appending("config-service/Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("config"), swiftPM.lock],
        operation: .sequence(commands.map { workingDirectory, arguments in
            .command(swiftPM.command(
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment))
        }))
}
