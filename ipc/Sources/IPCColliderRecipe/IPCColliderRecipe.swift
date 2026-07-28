import ColliderCore
import SystemPackage

public enum IPCColliderRecipe {
    public static func builds(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        let transport = root.appending("transport")
        let controlProtocol = root.appending("control-protocol")
        let controlClient = root.appending("control-client")
        let controlServiceCore = root.appending("control-service-core")
        let controlService = root.appending("control-service")
        return [
            task(
                "ipc.transport.build", transport, environment, ["build"],
                [TaskID(rawValue: "config.build")], swiftPM),
            task(
                "ipc.control-protocol.build", controlProtocol, environment,
                ["build"], [TaskID(rawValue: "ipc.transport.build")], swiftPM),
            task(
                "ipc.control-client.build", controlClient, environment,
                ["build"], [TaskID(rawValue: "ipc.control-protocol.build")],
                swiftPM),
            task(
                "ipc.control-service-core.build",
                controlServiceCore, environment, ["build"],
                [TaskID(rawValue: "ipc.control-client.build")], swiftPM),
            task(
                "ipc.control-service.build",
                controlService, environment, ["build"],
                [TaskID(rawValue: "ipc.control-service-core.build")], swiftPM),
            task(
                "ipc.build", root, environment, ["build"],
                [TaskID(rawValue: "ipc.control-service.build")], swiftPM),
        ]
    }

    public static func tests(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        let transport = root.appending("transport")
        let controlProtocol = root.appending("control-protocol")
        let controlClient = root.appending("control-client")
        let controlServiceCore = root.appending("control-service-core")
        let controlService = root.appending("control-service")
        let session = root.removingLastComponent()
            .appending("platform-linux/session")
        return [
            task(
                "ipc.transport.test", transport, environment, ["test"],
                [TaskID(rawValue: "ipc.build")], swiftPM,
                includesTests: true),
            task(
                "ipc.control-protocol.test", controlProtocol, environment,
                ["test"], [TaskID(rawValue: "ipc.transport.test")], swiftPM,
                includesTests: true),
            task(
                "ipc.control-client.test", controlClient, environment, ["test"],
                [TaskID(rawValue: "ipc.control-protocol.test")], swiftPM,
                includesTests: true),
            task(
                "ipc.control-service-core.test",
                controlServiceCore, environment, ["test"],
                [TaskID(rawValue: "ipc.control-client.test")], swiftPM,
                includesTests: true),
            task(
                "ipc.session-control.test",
                session, environment, ["test"],
                [TaskID(rawValue: "ipc.control-service-core.test")], swiftPM,
                includesTests: true),
            task(
                "ipc.test", controlService, environment, ["build"],
                [TaskID(rawValue: "ipc.session-control.test")], swiftPM),
        ]
    }
}

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation,
    includesTests: Bool = false
) -> TaskDeclaration {
    var inputs: [ArtifactInput] = [
        .file(root.appending("Package.swift")),
        .tree(root.appending("Sources")),
        swiftPM.identityInput,
        .tool(.named("swift")),
    ]
    if includesTests {
        inputs.append(.tree(root.appending("Tests")))
    }
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "ipc"),
        dependencies: dependencies,
        inputs: inputs,
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("ipc"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
