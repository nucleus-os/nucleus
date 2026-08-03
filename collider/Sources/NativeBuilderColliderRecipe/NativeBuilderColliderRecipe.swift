import ColliderCore

public enum NativeBuilderColliderRecipe {
    public static func prepare(
        _ configuration: NativeOCIConfiguration
    ) -> TaskDeclaration {
        return TaskDeclaration(
            id: TaskID(rawValue: "native.builder"),
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
