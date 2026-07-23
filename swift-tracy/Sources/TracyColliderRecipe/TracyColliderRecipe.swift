import ColliderCore
import SystemPackage

public enum TracyColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration {
        swiftTask(id: "tracy.build", component: "tracy", root: root, environment: environment, arguments: ["build"])
    }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration {
        swiftTask(id: "tracy.test", component: "tracy", root: root, environment: environment, arguments: ["test"], dependencies: [TaskID(rawValue: "tracy.build")])
    }
}

private func swiftTask(id: String, component: String, root: FilePath, environment: [String: String], arguments: [String], dependencies: [TaskID] = []) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: component), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("Sources")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout(component)], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
