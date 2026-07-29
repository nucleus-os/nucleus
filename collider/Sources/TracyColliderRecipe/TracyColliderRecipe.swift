import ColliderCore
import SystemPackage

public enum TracyColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "tracy.build"),
            component: ComponentID(rawValue: "tracy"),
            swiftProducts: [
                swiftPM.product(
                    package: "swift-tracy",
                    product: "SwiftTracy",
                    packageRoot: root,
                    environment: environment)
            ],
            inputs: [
                .tree(root.appending("Sources")),
                swiftPM.identityInput,
            ],
            postconditions: [swiftPM.postcondition],
            locks: [.checkout("tracy")],
            operation: .sequence([]))
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let requirement = swiftPM.testProduct(
            package: "swift-tracy",
            testProduct: "swift-tracyPackageTests",
            packageRoot: root,
            environment: environment)
        return TaskDeclaration(
            id: TaskID(rawValue: "tracy.test"),
            component: ComponentID(rawValue: "tracy"),
            dependencies: [TaskID(rawValue: "tracy.build")],
            subsumedDependencies: [TaskID(rawValue: "tracy.build")],
            swiftTests: [requirement],
            locks: [.checkout("tracy")],
            cachePolicy: .always,
            operation: .runSwiftTest(
                SwiftTestExecution(
                    requirement: requirement)))
    }
}
