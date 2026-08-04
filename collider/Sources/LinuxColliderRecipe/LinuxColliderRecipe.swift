import ColliderCore
import SystemPackage

public enum LinuxColliderRecipe {
    public static func architectureLane(
        architecture: PlatformArchitecture,
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        imageTask: TaskID,
        nativeDependencies: [TaskID],
        sdkRoot: FilePath,
        nativeSDKRoot: FilePath
    ) -> [TaskDeclaration] {
        let name = architecture.rawValue
        let buildID = TaskID(rawValue: "linux.\(name).build")
        let buildRequirement = swiftPM.product(
            package: "nucleus",
            product: "NucleusSessionSupervisor",
            packageRoot: root,
            environment: environment)
        let testRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: [
                "--no-parallel", "--skip",
                "gpu(DRM|Loader|Headless)_",
            ])
        let loaderRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: ["--filter", "gpuLoader_"])
        let headlessRequirement = swiftPM.testProduct(
            package: "nucleus",
            testProduct: "NucleusLinuxPlatformPackageTests",
            packageRoot: root,
            environment: environment,
            arguments: ["--filter", "gpuHeadless_"])
        let sharedInputs: [ArtifactInput] = [
            .tree(sdkRoot),
            .optionalTree(
                nativeSDKRoot,
                fallback: Array("native-sdk-not-provisioned".utf8)),
            swiftPM.identityInput,
        ]
        let build = TaskDeclaration(
            id: buildID,
            component: ComponentID(rawValue: "linux"),
            dependencies: [imageTask] + nativeDependencies,
            swiftProducts: [buildRequirement],
            inputs: sharedInputs,
            postconditions: [swiftPM.postcondition],
            locks: [.checkout("linux-\(name)")],
            cachePolicy: .contentAddressed,
            operation: .sequence([]))
        switch architecture {
        case .arm64:
            return [
                build,
                TaskDeclaration(
                    id: TaskID(rawValue: "linux.\(name).test"),
                    component: ComponentID(rawValue: "linux"),
                    dependencies: [buildID],
                    subsumedDependencies: [buildID],
                    swiftTests: [testRequirement],
                    inputs: sharedInputs,
                    postconditions: [swiftPM.postcondition],
                    locks: [.checkout("linux-\(name)")],
                    cachePolicy: .always,
                    operation: .sequence([])),
                laneTestTask(
                    id: "linux.\(name).test-loader",
                    buildID: buildID,
                    requirement: loaderRequirement,
                    sharedInputs: sharedInputs,
                    lockName: "linux-\(name)"),
                laneTestTask(
                    id: "linux.\(name).test-gpu-headless",
                    buildID: buildID,
                    requirement: headlessRequirement,
                    sharedInputs: sharedInputs,
                    lockName: "linux-\(name)"),
            ]
        case .x86_64:
            let probeRequirement = swiftPM.product(
                package: "nucleus",
                product: "NucleusVulkanLaneProbe",
                packageRoot: root,
                environment: environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: swiftPM.executable("NucleusVulkanLaneProbe"),
                        validation: .executableFile)
                ])
            return [
                build,
                translatedExecutableTask(
                    id: "linux.\(name).test",
                    buildID: buildID,
                    requirements: [buildRequirement, probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["loader"]),
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["gpu-headless"]),
                        (swiftPM.executable("NucleusSessionSupervisor"), ["--help"]),
                    ]),
                translatedExecutableTask(
                    id: "linux.\(name).test-loader",
                    buildID: buildID,
                    requirements: [probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["loader"])
                    ]),
                translatedExecutableTask(
                    id: "linux.\(name).test-gpu-headless",
                    buildID: buildID,
                    requirements: [probeRequirement],
                    inputs: sharedInputs,
                    swiftPM: swiftPM,
                    environment: environment,
                    operations: [
                        (swiftPM.executable("NucleusVulkanLaneProbe"), ["gpu-headless"])
                    ]),
            ]
        }
    }

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

private func laneTestTask(
    id: String,
    buildID: TaskID,
    requirement: SwiftTestRequirement,
    sharedInputs: [ArtifactInput],
    lockName: String
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "linux"),
        dependencies: [buildID],
        subsumedDependencies: [buildID],
        swiftTests: [requirement],
        inputs: sharedInputs,
        postconditions: [requirement.invocation.postcondition],
        locks: [.checkout(lockName)],
        cachePolicy: .always,
        operation: .sequence([]))
}

private func translatedExecutableTask(
    id: String,
    buildID: TaskID,
    requirements: [SwiftProductRequirement],
    inputs: [ArtifactInput],
    swiftPM: SwiftPMInvocation,
    environment: [String: String],
    operations: [(FilePath, [String])]
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "linux"),
        dependencies: [buildID],
        subsumedDependencies: requirements.contains(where: {
            $0.product == "NucleusSessionSupervisor"
        }) ? [buildID] : [],
        swiftProducts: requirements,
        inputs: inputs,
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("linux-x86_64")],
        cachePolicy: .always,
        operation: .sequence(
            operations.map { executable, arguments in
                swiftPM.operation(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: swiftPM.context.packageRoot,
                    environment: environment)
            }))
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
        operation: .sequence([]))
}
