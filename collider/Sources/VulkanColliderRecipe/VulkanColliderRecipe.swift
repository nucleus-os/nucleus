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
            ],
            storage: [
                StorageDeclaration(
                    id: "vulkan-generated-sources",
                    owner: descriptor.id,
                    producers: [.task(generation.task.id)],
                    storageClass: .source,
                    root: context.componentRoot(descriptor).appending(
                        "Sources/Vulkan/Vulkan.swift"),
                    safetyRoot: context.componentRoot(descriptor),
                    retentionPolicy: .protected)
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
        let generator: ExecutableReference = try toolBuilder.executableOutput(
            "executable",
            path: swiftPM.executable("VulkanGen"))
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
                .sourceCheckout(root.appending("Tools/VulkanGen")),
                swiftPM.identityInput,
            ],
            locks: [.checkout("vulkan")])

        let output = root.appending("Sources/Vulkan/Vulkan.swift")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "vulkan.generate"),
            component: descriptor.id)
        builder.consume(generator)
        let _: ArtifactReference = try builder.output(
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: generator)
            encoder.append(path: registry)
            encoder.append(path: output)
            encoder.append(1)
        }
    }

    static let kind: ActionKind = "vulkan.generate-bindings"

    let generator: ExecutableReference
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Vulkan binding generation failed")
        }
    }
}
