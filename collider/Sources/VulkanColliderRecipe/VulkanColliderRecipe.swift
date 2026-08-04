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
        let task = try generate(
            root: context.componentRoot(descriptor),
            environment: context.environment,
            swiftPM: try context.swiftPM(.hostDebug))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task],
            entrypoints: [
                ComponentEntrypoint(id: .generate, roots: [task.id])
            ])
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) throws -> TaskDeclaration {
        let output = root.appending("Sources/Vulkan/Vulkan.swift")
        return TaskDeclaration(
            id: TaskID(rawValue: "vulkan.generate"),
            component: ComponentID(rawValue: "vulkan"),
            swiftProducts: [
                swiftPM.product(
                    package: "swift-vulkan",
                    product: "VulkanGen",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("VulkanGen"),
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .tree(root.appending("Tools/VulkanGen")),
                .file(root.appending("third-party/vk.xml")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: output,
                    validation: .regularFile)
            ],
            locks: [.checkout("vulkan")],
            operation: .action(
                try AnyColliderAction(
                    GenerateVulkanBindingsAction(
                        generator: swiftPM.executable("VulkanGen"),
                        registry: root.appending("third-party/vk.xml"),
                        output: output,
                        workingDirectory: root,
                        environment: environment))))
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

    let generator: FilePath
    let registry: FilePath
    let output: FilePath
    let workingDirectory: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(generator: generator, registry: registry, output: output)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "vulkan-generator",
                    executable: .taskOutput(generator),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(registry)),
                ActionEffect(.write, scope: .output(output)),
            ])
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(generator),
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
