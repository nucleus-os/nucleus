import ColliderCore
import SystemPackage

package enum CompositorEntrypoints {
    package static let testGPUDRM = ComponentEntrypointID(
        rawValue: "test.gpu-drm")
}

package enum CompositorTaskIDs {
    package static let testGPUDRM = TaskID(rawValue: "compositor-core.test-gpu-drm")
}

public enum CompositorColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "compositor"),
        canonicalName: "compositor",
        directoryName: "compositor/compositor-core")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        let swiftPM = try context.swiftPM(.linux(.arm64))
        let test = testDRMGPU(
            root: root,
            environment: context.environment,
            swiftPM: swiftPM)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [test],
            entrypoints: [
                ComponentEntrypoint(
                    id: CompositorEntrypoints.testGPUDRM,
                    roots: [test.id])
            ])
    }

    public static func testDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        testTask(
            CompositorTaskIDs.testGPUDRM, root, environment,
            ["test", "--filter", "gpuDRM_"],
            [],
            swiftPM: swiftPM)
    }
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
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("compositor-core")],
        assessmentPolicy: .always)
}
