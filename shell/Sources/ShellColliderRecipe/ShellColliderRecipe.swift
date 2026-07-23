import ColliderCore
import SystemPackage

public enum ShellColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("shell.build", root, environment, ["build"], [TaskID(rawValue: "compositor.build")]) }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("shell.test", root, environment, ["test"], [TaskID(rawValue: "shell.build")]) }
}
private func task(_ id: String, _ root: FilePath, _ environment: [String: String], _ arguments: [String], _ dependencies: [TaskID]) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: "shell"), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("Sources")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout("shell")], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
