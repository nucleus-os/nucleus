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
            executableTask(
                id: "ipc.build",
                root: root,
                controlService: controlService,
                environment: environment,
                dependencies: [
                    TaskID(rawValue: "ipc.transport.build"),
                    TaskID(rawValue: "ipc.control-protocol.build"),
                    TaskID(rawValue: "ipc.control-client.build"),
                    TaskID(rawValue: "ipc.control-service-core.build"),
                    TaskID(rawValue: "ipc.control-service.build"),
                ],
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.transport.build"),
                    TaskID(rawValue: "ipc.control-protocol.build"),
                    TaskID(rawValue: "ipc.control-client.build"),
                    TaskID(rawValue: "ipc.control-service-core.build"),
                    TaskID(rawValue: "ipc.control-service.build"),
                ],
                swiftPM: swiftPM),
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
                [TaskID(rawValue: "ipc.transport.build")], swiftPM,
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.transport.build")
                ],
                includesTests: true),
            task(
                "ipc.control-protocol.test", controlProtocol, environment,
                ["test"],
                [
                    TaskID(rawValue: "ipc.transport.test"),
                    TaskID(rawValue: "ipc.control-protocol.build"),
                ], swiftPM,
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.control-protocol.build")
                ],
                includesTests: true),
            task(
                "ipc.control-client.test", controlClient, environment, ["test"],
                [
                    TaskID(rawValue: "ipc.control-protocol.test"),
                    TaskID(rawValue: "ipc.control-client.build"),
                ], swiftPM,
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.control-client.build")
                ],
                includesTests: true),
            task(
                "ipc.control-service-core.test",
                controlServiceCore, environment, ["test"],
                [
                    TaskID(rawValue: "ipc.control-client.test"),
                    TaskID(rawValue: "ipc.control-service-core.build"),
                ], swiftPM,
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.control-service-core.build")
                ],
                includesTests: true),
            task(
                "ipc.session-control.test",
                session, environment, ["test"],
                [TaskID(rawValue: "ipc.control-service-core.test")], swiftPM,
                includesTests: true),
            executableTask(
                id: "ipc.test",
                root: root,
                controlService: controlService,
                environment: environment,
                dependencies: [
                    TaskID(rawValue: "ipc.session-control.test"),
                    TaskID(rawValue: "ipc.build"),
                ],
                subsumedDependencies: [
                    TaskID(rawValue: "ipc.build")
                ],
                swiftPM: swiftPM),
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
    subsumedDependencies: [TaskID] = [],
    includesTests: Bool = false
) -> TaskDeclaration {
    let buildProduct: (String, String)? =
        switch id {
        case "ipc.transport.build":
            ("transport", "NucleusIPCTransport")
        case "ipc.control-protocol.build":
            ("control-protocol", "NucleusControlProtocol")
        case "ipc.control-client.build":
            ("control-client", "NucleusControlClient")
        case "ipc.control-service-core.build":
            ("control-service-core", "NucleusControlService")
        case "ipc.control-service.build":
            ("control-service", "NucleusControlService")
        default:
            nil
        }
    let testProduct: (String, String)? =
        switch id {
        case "ipc.transport.test":
            ("transport", "NucleusIPCTransportPackagePackageTests")
        case "ipc.control-protocol.test":
            ("control-protocol", "NucleusControlProtocolPackagePackageTests")
        case "ipc.control-client.test":
            ("control-client", "NucleusControlClientPackagePackageTests")
        case "ipc.control-service-core.test":
            ("control-service-core", "NucleusControlServicePackagePackageTests")
        case "ipc.session-control.test":
            ("session", "NucleusLinuxSessionPackagePackageTests")
        default:
            nil
        }
    var inputs: [ArtifactInput] = [
        .tree(root.appending("Sources")),
        swiftPM.identityInput,
        .tool(.named("swift")),
    ]
    if includesTests {
        inputs.append(.tree(root.appending("Tests")))
    }
    let testRequirement = testProduct.map {
        swiftPM.testProduct(
            package: $0.0,
            testProduct: $0.1,
            packageRoot: root,
            environment: environment)
    }
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "ipc"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: buildProduct.map { value in
            [
                swiftPM.product(
                    package: value.0,
                    product: value.1,
                    packageRoot: root,
                    environment: environment)
            ]
        } ?? [],
        swiftTests: testRequirement.map { [$0] } ?? [],
        inputs: inputs,
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("ipc")],
        cachePolicy: testRequirement == nil
            ? .contentAddressed
            : .always,
        operation: testRequirement.map {
            .runSwiftTest(SwiftTestExecution(requirement: $0))
        } ?? .sequence([]))
}

private func executableTask(
    id: String,
    root: FilePath,
    controlService: FilePath,
    environment: [String: String],
    dependencies: [TaskID],
    subsumedDependencies: [TaskID],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "ipc"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: [
            swiftPM.product(
                package: "control-service",
                product: "NucleusControlService",
                packageRoot: controlService,
                environment: environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: swiftPM.executable("NucleusControlService"),
                        validation: .executableFile)
                ]),
            swiftPM.product(
                package: "ipc",
                product: "nucleus",
                packageRoot: root,
                environment: environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: swiftPM.executable("nucleus"),
                        validation: .executableFile)
                ]),
        ],
        inputs: [
            .tree(root.appending("Sources")),
            .tree(controlService.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("ipc")],
        operation: .sequence([]))
}
