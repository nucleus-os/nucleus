import ColliderCore
import SystemPackage

package enum CompositorTaskIDs {
    package static let testGPUDRM = TaskID(rawValue: "compositor-core.test-gpu-drm")
    package static let preflightGPUDRM = TaskID(
        rawValue: "compositor-core.preflight-gpu-drm")
}

public enum CompositorColliderRecipe {
    public static func testDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        testTask(
            CompositorTaskIDs.testGPUDRM, root, environment,
            ["test", "--filter", "gpuDRM_"],
            [CompositorTaskIDs.preflightGPUDRM],
            swiftPM: swiftPM)
    }

    public static func preflightDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        preflightTask(
            CompositorTaskIDs.preflightGPUDRM,
            root, environment, "gpu-drm",
            [],
            swiftPM)
    }
}

private func preflightTask(
    _ id: TaskID,
    _ root: FilePath,
    _ environment: [String: String],
    _ lane: String,
    _ dependencies: [TaskID],
    _ swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    return TaskDeclaration(
        id: id,
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

private func testTask(
    _ id: TaskID,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let testRequirement = swiftPM.testProduct(
        package: "compositor-core",
        testProduct: "compositor-corePackageTests",
        packageRoot: root,
        environment: environment,
        arguments: Array(arguments.dropFirst()))
    return TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        swiftTests: [testRequirement],
        inputs: [
            .tree(root.appending("Sources")),
            .tree(root.appending("Tests")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("compositor-core")],
        cachePolicy: .always,
        operation: .sequence([]))
}
