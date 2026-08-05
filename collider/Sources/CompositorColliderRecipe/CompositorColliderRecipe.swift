import ColliderCore
import SystemPackage

package enum CompositorEntrypoints {
    package static let testGPUDRM = ComponentEntrypointID(
        rawValue: "test.gpu-drm")
}

package enum CompositorTaskIDs {
    package static let testGPUDRM = TaskID(rawValue: "compositor-core.test-gpu-drm")
    package static let preflightGPUDRM = TaskID(
        rawValue: "compositor-core.preflight-gpu-drm")
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
        let preflight = try preflightDRMGPU(
            root: root,
            environment: context.environment,
            swiftPM: swiftPM)
        let test = testDRMGPU(
            root: root,
            environment: context.environment,
            swiftPM: swiftPM)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [preflight, test],
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
            [CompositorTaskIDs.preflightGPUDRM],
            swiftPM: swiftPM)
    }

    public static func preflightDRMGPU(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) throws -> TaskDeclaration {
        try preflightTask(
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
) throws -> TaskDeclaration {
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
        ],
        locks: [.checkout("compositor-core")],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(
                CompositorLanePreflightAction(
                    execution: try swiftPM.ociExecutableExecution(
                        executable: swiftPM.executable("NucleusVulkanLaneProbe"),
                        arguments: [lane],
                        workingDirectory: root,
                        environment: environment),
                    probeName: "vulkan.\(lane)")))
}

private struct CompositorLanePreflightAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                nested: OCIExecutionActionIdentity(execution))
        }
    }

    static let kind: ActionKind = "compositor.preflight-lane"

    let execution: OCIExecution
    let probeName: String

    var identity: Identity {
        Identity(execution: execution)
    }

    var requirements: ActionRequirements {
        ociActionRequirements(execution: execution)
    }

    var environment: [String: String] { execution.environment }

    func execute(in context: ActionContext) async throws {
        let result = try await context.containers.run(execution)
        guard result.status == 0 else {
            throw CompositorPreflightFailure.commandFailed(result.status)
        }
        context.observations.recordHardwareProbe(
            name: probeName,
            result: "passed")
    }
}

private enum CompositorPreflightFailure: Error {
    case commandFailed(Int32)
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
