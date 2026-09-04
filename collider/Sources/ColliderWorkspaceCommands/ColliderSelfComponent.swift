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

    static func makeComponent(
        in context: WorkspaceContext
    ) async throws -> ComponentDefinition {
        let packageRoot = context.root.appending("collider")
        let engineRoot = packageRoot.appending("engine")
        // Release, like every other lane that runs tests. Collider's own
        // sources declare no `assert`, `assertionFailure`, or
        // `debugPrecondition`, so optimization elides no check it relies on,
        // and its sixty preconditions are retained. What debug was buying was
        // swift-system validating a `FilePath` component view on construction,
        // which this suite does constantly: one catalog costs 20.0 s debug and
        // 0.34 s release, and the whole bundle 45.9 s against 6.0 s.
        let cli = testTask(
            id: ColliderSelfTaskIDs.cliTests,
            package: "collider-cli",
            testProduct: "collider-cliPackageTests",
            invocation: try await context.swiftPMInvocation(
                packageRoot: packageRoot,
                configuration: .release,
                // These products are execution-only CI gates. Keeping DWARF
                // makes the linker chase explicit Clang modules through the
                // placement-independent prefix map after SwiftPM has removed
                // them, producing hundreds of missing-PCM diagnostics without
                // making the test binaries more useful.
                debugInformationFormat: SwiftDebugInformationFormat.none),
            environment: context.taskEnvironment)
        let engine = testTask(
            id: ColliderSelfTaskIDs.engineTests,
            package: "engine",
            testProduct: "enginePackageTests",
            invocation: try await context.swiftPMInvocation(
                packageRoot: engineRoot,
                configuration: .release,
                debugInformationFormat: SwiftDebugInformationFormat.none),
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
