import ColliderCore
import SystemPackage

public enum VulkanColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "vulkan.build", root, environment, ["build"],
            swiftPM: swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "vulkan.test", root, environment, ["test"],
            [TaskID(rawValue: "vulkan.build")],
            swiftPM: swiftPM)
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "vulkan.generate"),
            component: ComponentID(rawValue: "vulkan"),
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Tools/VulkanGen")),
                .file(root.appending("third-party/vk.xml")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            outputs: [OutputDeclaration(
                path: root.appending("Sources/Vulkan/Vulkan.swift"),
                validation: .regularFile)],
            locks: [.checkout("vulkan"), swiftPM.lock],
            operation: .command(swiftPM.command(
                arguments: [
                    "run", "VulkanGen",
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
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "vulkan"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("vulkan"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
