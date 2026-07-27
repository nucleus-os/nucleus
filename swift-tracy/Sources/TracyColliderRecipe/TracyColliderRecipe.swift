import ColliderCore
import SystemPackage

public enum TracyColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        swiftTask(
            id: "tracy.build",
            root: root,
            environment: environment,
            arguments: ["build"],
            swiftPM: swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        swiftTask(
            id: "tracy.test",
            root: root,
            environment: environment,
            arguments: ["test"],
            dependencies: [TaskID(rawValue: "tracy.build")],
            swiftPM: swiftPM)
    }
}

private func swiftTask(
    id: String,
    root: FilePath,
    environment: [String: String],
    arguments: [String],
    dependencies: [TaskID] = [],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "tracy"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("tracy"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
