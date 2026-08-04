import ColliderCore
import SystemPackage

package enum NativeBuilderTaskIDs {
    package static let prepare = TaskID(rawValue: "native.builder")
}

public struct NativeBuilderArtifacts: Sendable {
    public let component: ComponentDefinition
    public let configuration: NativeOCIConfiguration
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
        swiftSDKRoot: FilePath,
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
            operation: .sequence([
                .action(
                    try AnyColliderAction(
                        PrepareNativeBuilderCacheAction(
                            cache: ccache))),
                .action(
                    try AnyColliderAction(
                        PrepareNativeBuilderImageAction(
                            preparation: OCIImagePreparation(
                                executionPlatform: .linuxARM64OCI,
                                context: context,
                                containerFile: context.appending(
                                    "Containerfile"),
                                imageID: imageID,
                                imageName: "localhost/nucleus-linux-build",
                                environment: environment)))),
            ]))
        let configuration = NativeOCIConfiguration(
            context: context,
            image: image,
            ccache: ccache,
            swiftSDKRoot: swiftSDKRoot,
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
    static let kind: ActionKind = "native.prepare-builder-image"

    let identity: OCIImagePreparationActionIdentity

    init(preparation: OCIImagePreparation) {
        identity = OCIImagePreparationActionIdentity(preparation)
    }

    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: identity.preparation)
    }

    var environment: [String: String] { identity.preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.prepareImage(identity.preparation)
    }
}

private struct PrepareNativeBuilderCacheAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let cache: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: cache.string)
        }
    }

    static let kind: ActionKind = "native.prepare-builder-cache"

    let cache: FilePath

    var identity: Identity { Identity(cache: cache) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.write, scope: .scratch(cache))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(cache)
    }
}
