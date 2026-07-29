import ColliderCore
import SystemPackage

public enum CompositorColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.build", root, environment, ["build"],
            [
                TaskID(rawValue: "rn.build")
            ],
            isTest: false,
            swiftPM: swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test", root, environment,
            ["test", "--skip", "gpu(Loader|Headless|DRM)_"],
            [TaskID(rawValue: "compositor-core.build")],
            isTest: true,
            subsumedDependencies: [
                TaskID(rawValue: "compositor-core.build")
            ],
            swiftPM: swiftPM)
    }

    public static func testVulkanLoader(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-loader", root, environment,
            ["test", "--filter", "gpuLoader_"],
            [TaskID(rawValue: "compositor-core.preflight-loader")],
            isTest: true,
            swiftPM: swiftPM)
    }

    public static func preflightVulkanLoader(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-loader", root, environment, "loader",
            [],
            swiftPM)
    }

    public static func testHeadlessGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-gpu-headless", root, environment,
            ["test", "--filter", "gpuHeadless_"],
            [TaskID(rawValue: "compositor-core.preflight-gpu-headless")],
            isTest: true,
            swiftPM: swiftPM)
    }

    public static func preflightHeadlessGPU(
        root: FilePath,
        environment: [String: String],
        lavapipeTask: TaskID,
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-gpu-headless", root, environment,
            "gpu-headless",
            [lavapipeTask],
            swiftPM)
    }

    public static func testDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-gpu-drm", root, environment,
            ["test", "--filter", "gpuDRM_"],
            [TaskID(rawValue: "compositor-core.preflight-gpu-drm")],
            isTest: true,
            swiftPM: swiftPM)
    }

    public static func preflightDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-gpu-drm", root, environment, "gpu-drm",
            [],
            swiftPM)
    }
}

private func preflightTask(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ lane: String,
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        swiftProducts: [
            swiftPM.product(
                package: "compositor-core",
                product: "NucleusVulkanLaneProbe",
                packageRoot: root,
                environment: environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: swiftPM.executable("NucleusVulkanLaneProbe"),
                        validation: .executableFile)
                ])
        ],
        inputs: [
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        outputs: [],
        locks: [.checkout("compositor-core")],
        cachePolicy: .always,
        operation: .command(
            CommandSpec(
                executable: .taskOutput(
                    swiftPM.executable(
                        "NucleusVulkanLaneProbe")),
                arguments: [lane],
                workingDirectory: root,
                environment: environment)))
}

private func packageTask(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    isTest: Bool,
    subsumedDependencies: [TaskID] = [],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let isBuild = arguments == ["build"]
    let runnerArguments = isTest ? Array(arguments.dropFirst()) : []
    let testRequirement =
        isTest
        ? swiftPM.testProduct(
            package: "compositor-core",
            testProduct: "compositor-corePackageTests",
            packageRoot: root,
            environment: environment,
            arguments: runnerArguments) : nil
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: isBuild
            ? [
                swiftPM.product(
                    package: "compositor-core",
                    product: "NucleusRenderServer",
                    packageRoot: root,
                    environment: environment)
            ] : [],
        swiftTests: testRequirement.map { [$0] } ?? [],
        inputs: [
            .tree(root.appending("Sources"))
        ] + (isTest ? [.tree(root.appending("Tests"))] : [])
            + [swiftPM.identityInput, .tool(.named("swift"))],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("compositor-core")],
        cachePolicy: isTest ? .always : .contentAddressed,
        operation: testRequirement.map {
            .runSwiftTest(SwiftTestExecution(requirement: $0))
        } ?? .sequence([]))
}
