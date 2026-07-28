import ColliderCore
import SystemPackage

public enum CompositorAppColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "compositor.build", root, environment, ["build"],
            [TaskID(rawValue: "compositor-core.build")], swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            // The launch-only package intentionally has no test targets. Its
            // test task verifies that the executable still builds after the
            // compositor-core test authority has passed.
            "compositor.test", root, environment, ["build"],
            [
                TaskID(rawValue: "compositor.build"),
                TaskID(rawValue: "compositor-core.test"),
            ],
            swiftPM)
    }
}
private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("compositor"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
