import ColliderCore
import SystemPackage

public enum CompositorAppColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("compositor.build", root, environment, ["build"], [TaskID(rawValue: "compositor-core.build")]) }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("compositor.test", root, environment, ["test"], [TaskID(rawValue: "compositor.build"), TaskID(rawValue: "compositor-core.test")]) }
}
private func task(_ id: String, _ root: FilePath, _ environment: [String: String], _ arguments: [String], _ dependencies: [TaskID]) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: "compositor"), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("Sources")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout("compositor")], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
