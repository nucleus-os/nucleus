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
                dependencies: [TaskID(rawValue: "linux.base.build")],
                subsumedDependencies: [
                    TaskID(rawValue: "linux.base.build")
                ],
                includesTests: true,
                swiftPM: swiftPM),
            task(
                "linux.desktop.test", root: desktop, environment: environment,
                arguments: ["test"],
                dependencies: [
                    TaskID(rawValue: "linux.base.test"),
                    TaskID(rawValue: "linux.desktop.build"),
                ],
                subsumedDependencies: [
                    TaskID(rawValue: "linux.desktop.build")
                ],
                includesTests: true,
                swiftPM: swiftPM),
            task(
                "session-protocol.test", root: protocolRoot,
                environment: environment, arguments: ["test"],
                dependencies: [
                    TaskID(rawValue: "linux.desktop.test"),
                    TaskID(rawValue: "session-protocol.build"),
                ],
                subsumedDependencies: [
                    TaskID(rawValue: "session-protocol.build")
                ],
                includesTests: true,
                swiftPM: swiftPM),
            task(
                "linux.test", root: session, environment: environment,
                arguments: ["test"],
                dependencies: [
                    TaskID(rawValue: "session-protocol.test"),
                    TaskID(rawValue: "linux.build"),
                ],
                subsumedDependencies: [
                    TaskID(rawValue: "linux.build")
                ],
                includesTests: true,
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
    subsumedDependencies: [TaskID] = [],
    includesTests: Bool = false,
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let buildProduct: (String, String)? =
        switch id {
        case "linux.base.build":
            ("platform-linux", "NucleusLinux")
        case "linux.desktop.build":
            ("desktop", "NucleusLinuxDesktop")
        case "session-protocol.build":
            ("protocol", "NucleusSessionProtocol")
        case "linux.build":
            ("session", "NucleusSessionSupervisor")
        default:
            nil
        }
    let testProduct: (String, String)? =
        switch id {
        case "linux.base.test":
            ("platform-linux", "NucleusLinuxPlatformPackageTests")
        case "linux.desktop.test":
            ("desktop", "NucleusLinuxDesktopPackagePackageTests")
        case "session-protocol.test":
            ("protocol", "NucleusSessionProtocolPackagePackageTests")
        case "linux.test":
            ("session", "NucleusLinuxSessionPackagePackageTests")
        default:
            nil
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
        component: ComponentID(rawValue: "linux"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: buildProduct.map { value in
            [
                swiftPM.product(
                    package: value.0,
                    product: value.1,
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: value.1 == "NucleusSessionSupervisor"
                        ? [
                            PathPostcondition(
                                path: swiftPM.executable(value.1),
                                validation: .executableFile)
                        ]
                        : [])
            ]
        } ?? [],
        swiftTests: testRequirement.map { [$0] } ?? [],
        inputs: [
            .tree(root.appending("Sources"))
        ] + (includesTests ? [.tree(root.appending("Tests"))] : []) + [
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("linux")],
        cachePolicy: testRequirement == nil
            ? .contentAddressed
            : .always,
        operation: testRequirement.map {
            .runSwiftTest(SwiftTestExecution(requirement: $0))
        } ?? .sequence([]))
}
