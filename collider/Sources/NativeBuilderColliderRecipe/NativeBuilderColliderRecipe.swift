import ColliderCore

package enum NativeBuilderTaskIDs {
    package static let prepare = TaskID(rawValue: "native.builder")
}

public enum NativeBuilderColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "native"),
        canonicalName: "native-builder",
        directoryName: "core/build-container")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let task = prepare(context.nativeBuilder)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task],
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: [task.id])
            ])
    }

    public static func prepare(
        _ configuration: NativeOCIConfiguration
    ) -> TaskDeclaration {
        return TaskDeclaration(
            id: NativeBuilderTaskIDs.prepare,
            component: ComponentID(rawValue: "native"),
            inputs: [
                .tree(configuration.context)
            ],
            outputs: [
                OutputDeclaration(
                    path: configuration.imageID,
                    validation: .regularFile)
            ],
            postconditions: [
                PathPostcondition(
                    path: configuration.ccache,
                    validation: .exists)
            ],
            locks: [.checkout("native-builder-image")],
            cachePolicy: .contentAddressed,
            operation: .sequence([
                .createDirectory(configuration.ccache),
                .prepareOCIImage(
                    OCIImagePreparation(
                        executionPlatform: .linuxARM64OCI,
                        context: configuration.context,
                        containerFile: configuration.context.appending(
                            "Containerfile"),
                        imageID: configuration.imageID,
                        imageName: "localhost/nucleus-linux-build",
                        environment: configuration.environment)),
            ]))
    }
}
