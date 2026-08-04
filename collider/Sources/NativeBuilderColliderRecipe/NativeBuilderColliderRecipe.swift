import ColliderCore
import SystemPackage

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
        let task = try prepare(context.nativeBuilder)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task],
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: [task.id])
            ])
    }

    public static func prepare(
        _ configuration: NativeOCIConfiguration
    ) throws -> TaskDeclaration {
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
            assessmentPolicy: .incremental,
            operation: .sequence([
                .action(
                    try AnyColliderAction(
                        PrepareNativeBuilderCacheAction(
                            cache: configuration.ccache))),
                .action(
                    try AnyColliderAction(
                        PrepareNativeBuilderImageAction(
                            preparation: OCIImagePreparation(
                                executionPlatform: .linuxARM64OCI,
                                context: configuration.context,
                                containerFile: configuration.context.appending(
                                    "Containerfile"),
                                imageID: configuration.imageID,
                                imageName: "localhost/nucleus-linux-build",
                                environment: configuration.environment)))),
            ]))
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
