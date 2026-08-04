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
        let task = generate(
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
    ) -> TaskDeclaration {
        TaskDeclaration(
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
                    path: root.appending("Sources/Vulkan/Vulkan.swift"),
                    validation: .regularFile)
            ],
            locks: [.checkout("vulkan")],
            operation: .command(
                CommandSpec(
                    executable: .taskOutput(swiftPM.executable("VulkanGen")),
                    arguments: [
                        root.appending("third-party/vk.xml").string,
                        root.appending("Sources/Vulkan/Vulkan.swift").string,
                        "1",
                    ],
                    workingDirectory: root,
                    environment: environment)))
    }
}
