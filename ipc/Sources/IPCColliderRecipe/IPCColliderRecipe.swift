import ColliderCore
import SystemPackage

public enum IPCColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "ipc.build", root, environment, ["build"],
            [TaskID(rawValue: "config.build")], swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "ipc.test", root, environment, ["test"],
            [TaskID(rawValue: "ipc.build")], swiftPM)
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
        component: ComponentID(rawValue: "ipc"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("ipc"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
