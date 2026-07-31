import ColliderCore

public enum NativeBuilderColliderRecipe {
    public static func prepare(
        _ configuration: NativeBuildContainerConfiguration
    ) -> TaskDeclaration? {
        #if os(macOS)
        return nil
        #else
        return TaskDeclaration(
            id: TaskID(rawValue: "native.builder"),
            component: ComponentID(rawValue: "native"),
            inputs: [
                .tree(configuration.context),
                .tool(.named("podman")),
            ],
            outputs: [
                OutputDeclaration(
                    path: configuration.imageID,
                    validation: .regularFile)
            ],
            locks: [.checkout("native-builder-image")],
            cachePolicy: .contentAddressed,
            operation: .prepareBuildContainer(
                BuildContainerPreparation(
                    context: configuration.context,
                    containerFile: configuration.context.appending(
                        "Containerfile"),
                    imageID: configuration.imageID,
                    imageName: "localhost/nucleus-native-build",
                    environment: configuration.environment)))
        #endif
    }
}
