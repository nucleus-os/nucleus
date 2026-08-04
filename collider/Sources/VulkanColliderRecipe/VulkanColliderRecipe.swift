import ColliderCore
import SystemPackage

public enum VulkanColliderRecipe {
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

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID] = [],
    subsumedDependencies: [TaskID] = [],
    includesTests: Bool = false,
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let isBuild = arguments == ["build"]
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "vulkan"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: isBuild
            ? [
                swiftPM.product(
                    package: "swift-vulkan",
                    product: "SwiftVulkan",
                    packageRoot: root,
                    environment: environment)
            ] : [],
        inputs: [
            .tree(root.appending("Sources"))
        ] + (includesTests ? [.tree(root.appending("Tests"))] : []) + [
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("vulkan")] + (isBuild ? [] : [swiftPM.lock]),
        operation: isBuild
            ? .sequence([])
            : .command(
                swiftPM.command(
                    arguments: arguments,
                    workingDirectory: root,
                    environment: environment)))
}
