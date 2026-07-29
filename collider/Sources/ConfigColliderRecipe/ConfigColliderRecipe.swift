import ColliderCore
import SystemPackage

public enum ConfigColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let service = root.appending("config-service")
        return TaskDeclaration(
            id: TaskID(rawValue: "config.build"),
            component: ComponentID(rawValue: "config"),
            swiftProducts: [
                swiftPM.product(
                    package: "config",
                    product: "NucleusConfigIO",
                    packageRoot: root,
                    environment: environment),
                swiftPM.product(
                    package: "config-service",
                    product: "NucleusConfigService",
                    packageRoot: service,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("NucleusConfigService"),
                            validation: .executableFile)
                    ]),
            ],
            inputs: [
                .tree(root.appending("Sources")),
                .tree(service.appending("Sources")),
                swiftPM.identityInput,
            ],
            postconditions: [swiftPM.postcondition],
            locks: [.checkout("config")],
            operation: .sequence([]))
    }

    public static func tests(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        [
            testTask(
                id: "config.model.test",
                package: "model",
                product: "NucleusConfigModelPackageTests",
                root: root.appending("model"),
                environment: environment,
                dependencies: [TaskID(rawValue: "config.build")],
                swiftPM: swiftPM),
            testTask(
                id: "config.service-core.test",
                package: "config-service-core",
                product: "NucleusConfigServicePackagePackageTests",
                root: root.appending("config-service-core"),
                environment: environment,
                dependencies: [TaskID(rawValue: "config.model.test")],
                swiftPM: swiftPM),
            testTask(
                id: "config.test",
                package: "config",
                product: "NucleusConfigIOPackagePackageTests",
                root: root,
                environment: environment,
                dependencies: [
                    TaskID(rawValue: "config.service-core.test"),
                    TaskID(rawValue: "config.build"),
                ],
                subsumedDependencies: [TaskID(rawValue: "config.build")],
                swiftPM: swiftPM),
        ]
    }
}

private func testTask(
    id: String,
    package: String,
    product: String,
    root: FilePath,
    environment: [String: String],
    dependencies: [TaskID],
    subsumedDependencies: [TaskID] = [],
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let requirement = swiftPM.testProduct(
        package: package,
        testProduct: product,
        packageRoot: root,
        environment: environment)
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "config"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftTests: [requirement],
        locks: [.checkout("config")],
        cachePolicy: .always,
        operation: .runSwiftTest(
            SwiftTestExecution(
                requirement: requirement)))
}
