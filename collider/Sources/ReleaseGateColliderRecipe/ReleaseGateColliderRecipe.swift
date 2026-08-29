import ColliderCore
import NativeBuilderColliderRecipe

package enum ReleaseGateEntrypoints {
    package static let test = ComponentEntrypointID(rawValue: "test.release-gate")
}

package enum ReleaseGateTaskIDs {
    package static let all: [TaskID] = suites.map {
        TaskID(rawValue: "test.release-gate.\($0.id)")
    }

    fileprivate static let suites: [(id: String, package: String, suite: String)] = [
        ("foundation-publication", "core", "NucleusFoundationPublicationStressTests"),
        ("foundation-lifecycle", "core", "NucleusFoundationLifecycleStressTests"),
        ("text-editor", "core", "NucleusTextEditorStressTests"),
        ("collection", "core", "NucleusCollectionStressTests"),
        (
            "platform-transport",
            "integration-tests/window-client-conformance",
            "NucleusPlatformTransportStressTests"
        ),
        (
            "compositor-transition",
            "compositor",
            "NucleusCompositorTransitionStressTests"
        ),
    ]
}

public enum ReleaseGateColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "release-gate"),
        canonicalName: "release-gate",
        directoryName: "integration-tests")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let swiftPM = try context.swiftPM(
            .linux(.arm64, configuration: .release))
        let targetArtifacts = try native.artifacts(
            for: NativeLinuxTarget(architecture: .arm64))
        let tasks = ReleaseGateTaskIDs.suites.map { suite in
            let requirement = swiftPM.testProduct(
                package: suite.package,
                testProduct: suite.suite,
                packageRoot: context.repositoryRoot.appending(suite.package),
                environment: context.environment,
                options: SwiftTestOptions(filters: [suite.suite]))
            var builder = TaskBuilder(
                id: TaskID(rawValue: "test.release-gate.\(suite.id)"),
                component: descriptor.id)
            builder.consume(targetArtifacts)
            return builder.build(
                swiftTests: [requirement],
                inputs: [swiftPM.identityInput],
                locks: [.checkout("test-release-gate")],
                assessmentPolicy: .always)
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: ReleaseGateEntrypoints.test,
                    roots: Set(tasks.map(\.id)))
            ])
    }
}
