import ColliderCore
import SystemPackage

public enum LinuxColliderRecipe {
    public static func builds(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        let desktop = root.appending("desktop")
        let protocolRoot = root.removingLastComponent()
            .appending("session/protocol")
        let session = root.appending("session")
        return [
            task(
                "linux.base.build", root: root, environment: environment,
                arguments: ["build"],
                dependencies: [TaskID(rawValue: "core.build")],
                swiftPM: swiftPM),
            task(
                "linux.desktop.build", root: desktop, environment: environment,
                arguments: ["build"],
                dependencies: [TaskID(rawValue: "linux.base.build")],
                swiftPM: swiftPM),
            task(
                "session-protocol.build", root: protocolRoot,
                environment: environment, arguments: ["build"],
                dependencies: [
                    TaskID(rawValue: "config.build"),
                    TaskID(rawValue: "ipc.build"),
                    TaskID(rawValue: "linux.desktop.build"),
                ],
                swiftPM: swiftPM),
            task(
                "linux.build", root: session, environment: environment,
                arguments: ["build"],
                dependencies: [TaskID(rawValue: "session-protocol.build")],
                swiftPM: swiftPM),
        ]
    }

    public static func tests(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        let desktop = root.appending("desktop")
        let protocolRoot = root.removingLastComponent()
            .appending("session/protocol")
        let session = root.appending("session")
        return [
            task(
                "linux.base.test", root: root, environment: environment,
                arguments: ["test"],
                dependencies: [TaskID(rawValue: "linux.build")],
                swiftPM: swiftPM),
            task(
                "linux.desktop.test", root: desktop, environment: environment,
                arguments: ["test"],
                dependencies: [TaskID(rawValue: "linux.base.test")],
                swiftPM: swiftPM),
            task(
                "session-protocol.test", root: protocolRoot,
                environment: environment, arguments: ["test"],
                dependencies: [TaskID(rawValue: "linux.desktop.test")],
                swiftPM: swiftPM),
            task(
                "linux.test", root: session, environment: environment,
                arguments: ["test"],
                dependencies: [TaskID(rawValue: "session-protocol.test")],
                swiftPM: swiftPM),
        ]
    }
}

private func task(
    _ id: String,
    root: FilePath,
    environment: [String: String],
    arguments: [String],
    dependencies: [TaskID],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "linux"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("linux"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
