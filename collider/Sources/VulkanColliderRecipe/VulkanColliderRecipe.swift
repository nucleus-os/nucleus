import ColliderCore
import SystemPackage

public enum VulkanColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "vulkan"),
        canonicalName: "vulkan",
        directoryName: "swift-vulkan")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let generation = try generate(
            root: context.componentRoot(descriptor),
            environment: context.environment,
            swiftPM: try context.swiftPM(.hostDebug))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: generation.tasks,
            entrypoints: [
                ComponentEntrypoint(id: .generate, roots: [generation.task.id])
            ])
    }

    package struct Generation: Sendable {
        package let tasks: [TaskDeclaration]
        package let task: TaskDeclaration
    }

    package static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) throws -> Generation {
        var toolBuilder = TaskBuilder(
            id: TaskID(rawValue: "vulkan.generator"),
            component: descriptor.id)
        let generator: ArtifactReference<ExecutableArtifact> = try toolBuilder.output(
            "executable",
            path: swiftPM.executable("VulkanGen"),
            validation: .executableFile)
        let tool = toolBuilder.build(
            swiftProducts: [
                swiftPM.product(
                    package: "swift-vulkan",
                    product: "VulkanGen",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: generator.path,
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .tree(root.appending("Tools/VulkanGen")),
                swiftPM.identityInput,
            ],
            locks: [.checkout("vulkan")])

        let output = root.appending("Sources/Vulkan/Vulkan.swift")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "vulkan.generate"),
            component: descriptor.id)
        builder.consume(generator)
        let _: ArtifactReference<FileArtifact> = try builder.output(
            "bindings",
            path: output,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .file(root.appending("third-party/vk.xml"))
            ],
            locks: [.checkout("vulkan")],
            action:
                try AnyColliderAction(
                    GenerateVulkanBindingsAction(
                        generator: generator,
                        registry: root.appending("third-party/vk.xml"),
                        output: output,
                        workingDirectory: root,
                        environment: environment)))
        return Generation(tasks: [tool, task], task: task)
    }
}

private struct GenerateVulkanBindingsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generator: FilePath
        let registry: FilePath
        let output: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: generator.string)
            encoder.append(tag: 2, string: registry.string)
            encoder.append(tag: 3, string: output.string)
            encoder.append(tag: 4, integer: 1)
        }
    }

    static let kind: ActionKind = "vulkan.generate-bindings"

    let generator: ArtifactReference<ExecutableArtifact>
    let registry: FilePath
    let output: FilePath
    let workingDirectory: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(generator: generator.path, registry: registry, output: output)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "vulkan-generator",
                    executable: generator.executable,
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .input(registry)),
                ActionEffect(.write, scope: .output(output)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: generator.executable,
                arguments: [registry.string, output.string, "1"],
                workingDirectory: workingDirectory,
                environment: environment))
        guard result.status == 0 else {
            throw VulkanGenerationFailure.commandFailed(result.status)
        }
    }
}

private enum VulkanGenerationFailure: Error {
    case commandFailed(Int32)
}
