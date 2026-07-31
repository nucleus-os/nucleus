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
            locks: [.checkout("native-builder-image")],
            cachePolicy: .contentAddressed,
            operation: .prepareOCIImage(
                OCIImagePreparation(
                    executionPlatform: .linuxAMD64OCI,
                    context: configuration.context,
                    containerFile: configuration.context.appending(
                        "Containerfile"),
                    imageID: configuration.imageID,
                    imageName: "localhost/nucleus-native-build",
                    environment: configuration.environment)))
    }
}
