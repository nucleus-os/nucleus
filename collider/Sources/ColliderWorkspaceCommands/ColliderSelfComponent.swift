import ColliderCore

package enum ColliderSelfTaskIDs {
    package static let cliTests = TaskID(rawValue: "collider.test.cli")
    package static let engineTests = TaskID(rawValue: "collider.test.engine")
}

enum ColliderSelfComponent {
    static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "collider"),
        canonicalName: "collider",
        directoryName: "collider")

    static func makeComponent(in context: WorkspaceContext) throws -> ComponentDefinition {
        let packageRoot = context.root.appending("collider")
        let engineRoot = packageRoot.appending("engine")
        let cli = testTask(
            id: ColliderSelfTaskIDs.cliTests,
            package: "collider-cli",
            testProduct: "collider-cliPackageTests",
            invocation: try context.swiftPMInvocation(packageRoot: packageRoot),
            environment: context.taskEnvironment)
        let engine = testTask(
            id: ColliderSelfTaskIDs.engineTests,
            package: "engine",
            testProduct: "enginePackageTests",
            invocation: try context.swiftPMInvocation(packageRoot: engineRoot),
            environment: context.taskEnvironment)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [cli, engine],
            entrypoints: [
                ComponentEntrypoint(
                    id: .testDefault,
                    roots: [cli.id, engine.id])
            ])
    }

    private static func testTask(
        id: TaskID,
        package: String,
        testProduct: String,
        invocation: SwiftPMInvocation,
        environment: [String: String]
    ) -> TaskDeclaration {
        let requirement = invocation.testProduct(
            package: package,
            testProduct: testProduct,
            packageRoot: invocation.context.packageRoot,
            environment: environment)
        return TaskBuilder(id: id, component: descriptor.id).build(
            swiftTests: [requirement],
            inputs: [invocation.identityInput],
            assessmentPolicy: .always)
    }
}
