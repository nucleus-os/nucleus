import ColliderCore
import SystemPackage

public enum VulkanColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("vulkan.build", root, environment, ["build"]) }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("vulkan.test", root, environment, ["test"], [TaskID(rawValue: "vulkan.build")]) }
    public static func generate(root: FilePath, environment: [String: String]) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "vulkan.generate"),
            component: ComponentID(rawValue: "vulkan"),
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Tools/VulkanGen")),
                .file(root.appending("third-party/vk.xml")),
                .tool(.named("swift")),
            ],
            outputs: [OutputDeclaration(
                path: root.appending("Sources/Vulkan/Vulkan.swift"),
                validation: .regularFile)],
            locks: [.checkout("vulkan")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
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

private func task(_ id: String, _ root: FilePath, _ environment: [String: String], _ arguments: [String], _ dependencies: [TaskID] = []) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: "vulkan"), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("Sources")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout("vulkan")], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
