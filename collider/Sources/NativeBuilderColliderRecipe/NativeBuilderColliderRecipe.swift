import ColliderCore
import SystemPackage

package enum NativeBuilderTaskIDs {
    package static let prepare = TaskID(rawValue: "native.builder")
}

public struct NativeBuilderArtifacts: Sendable {
    public let component: ComponentDefinition
    public let configuration: NativeOCIBaseConfiguration
}

public enum NativeBuilderColliderRecipe {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "native"),
        canonicalName: "native-builder",
        directoryName: "core/build-container")

    public static func prepare(
        context: FilePath,
        imageID: FilePath,
        ccache: FilePath,
        environment: [String: String]
    ) throws -> NativeBuilderArtifacts {
        var builder = TaskBuilder(
            id: NativeBuilderTaskIDs.prepare,
            component: descriptor.id)
        let image: ArtifactReference<FileArtifact> = try builder.output(
            "image-id",
            path: imageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [
                .tree(context)
            ],
            postconditions: [
                PathPostcondition(
                    path: ccache,
                    validation: .exists)
            ],
            locks: [.checkout("native-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareNativeBuilderImageAction(
                        cache: ccache,
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: context,
                            containerFile: context.appending(
                                "Containerfile"),
                            imageID: imageID,
                            imageName: "localhost/nucleus-linux-build",
                            environment: environment))))
        let configuration = NativeOCIBaseConfiguration(
            context: context,
            image: image,
            ccache: ccache,
            environment: environment)
        return NativeBuilderArtifacts(
            component: try ComponentDefinition(
                descriptor: descriptor,
                tasks: [task],
                entrypoints: [
                    ComponentEntrypoint(id: .bootstrap, roots: [task.id])
                ]),
            configuration: configuration)
    }
}

private struct PrepareNativeBuilderImageAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let cache: FilePath
        let preparation: OCIImagePreparation

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                nested: OCIImagePreparationActionIdentity(preparation))
            encoder.append(tag: 2, string: cache.string)
        }
    }

    static let kind: ActionKind = "native.prepare-builder-image"

    let cache: FilePath
    let preparation: OCIImagePreparation

    var identity: Identity {
        Identity(cache: cache, preparation: preparation)
    }

    var requirements: ActionRequirements {
        let image = ociImagePreparationActionRequirements(
            preparation: preparation)
        return ActionRequirements(
            effects: image.effects + [
                ActionEffect(.write, scope: .scratch(cache))
            ],
            resources: image.resources,
            executionPlatform: image.executionPlatform)
    }

    var environment: [String: String] { preparation.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(cache)
        try await context.containers.prepareImage(preparation)
    }
}
