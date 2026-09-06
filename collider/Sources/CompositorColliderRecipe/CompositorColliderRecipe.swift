import ColliderCore
import NativeBuilderColliderRecipe
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
        let swiftPM = try context.swiftPM(.linux(.arm64, configuration: .release))
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let test = testDRMGPU(
            root: root,
            environment: context.environment,
            swiftPM: swiftPM,
            compilationArtifacts: try native.artifacts(
                for: NativeLinuxTarget(architecture: .arm64)))
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
        swiftPM: SwiftPMInvocation,
        compilationArtifacts: ArtifactReferenceSet
    ) -> TaskDeclaration {
        testTask(
            CompositorTaskIDs.testGPUDRM, root, environment,
            SwiftTestOptions(filters: ["gpuDRM_"]),
            [],
            swiftPM: swiftPM,
            compilationArtifacts: compilationArtifacts)
    }
}

private func testTask(
    _ id: TaskID,
    _ root: FilePath,
    _ environment: [String: String],
    _ options: SwiftTestOptions,
    _ dependencies: [TaskID],
    swiftPM: SwiftPMInvocation,
    compilationArtifacts: ArtifactReferenceSet
) -> TaskDeclaration {
    let testRequirement = swiftPM.testProduct(
        package: "compositor-core",
        testProduct: "compositor-corePackageTests",
        packageRoot: root,
        environment: environment,
        compilationArtifacts: compilationArtifacts,
        options: options)
    return TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        swiftTests: [testRequirement],
        inputs: [
            swiftPM.identityInput
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("compositor-core")],
        assessmentPolicy: .always)
}
