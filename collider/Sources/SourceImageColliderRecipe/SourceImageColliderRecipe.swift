import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SourceImageAssembly
import SystemPackage

package enum SourceImageEntrypoints {
    package static let test = ComponentEntrypointID(
        rawValue: "test.source-image")
}

package enum SourceImageTaskIDs {
    package static let attachment = TaskID(
        rawValue: "test.source-image.attachment")
}

/// Qualifies that a guest kernel reads the image the host built.
///
/// Every other property of a source image is established by reading it back on
/// the host with the same library that wrote it, which cannot show that a
/// kernel mounting it agrees. Only a container can, and a container is only
/// reachable from the builder identity, which is what executes a task graph.
/// So this is a task rather than a test: a test bundle run by hand reaches the
/// container service as `XPC connection error: Connection invalid` however
/// healthy the service is, and one that cannot run proves nothing.
///
/// The tree is a fixture rather than the prepared Chromium source, because
/// what is in question is the mechanism -- build an image, establish a
/// workspace from it, mount it read-only -- and a fixture that fits in a
/// second exercises it as completely as one that takes five minutes.
public enum SourceImageColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "source-image"),
        canonicalName: "source-image",
        directoryName: "collider/Sources/SourceImageAssembly")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.buildRoot.appending("source-image/attachment")
        var builder = TaskBuilder(
            id: SourceImageTaskIDs.attachment,
            component: descriptor.id)
        builder.consume(native.builder.base.image)
        _ = try builder.output(
            "image", path: root.appending("source.img"), validation: .regularFile)
        let task = builder.build(
            // Removable storage this task replaces, so a concurrent run may
            // not be reading it while this one rewrites it.
            locks: [.checkout("source-image-attachment")],
            assessmentPolicy: .always,
            action: try AnyColliderAction(
                SourceImageAttachmentAction(
                    root: root,
                    imageID: native.builder.base.imageID)))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task],
            entrypoints: [
                ComponentEntrypoint(
                    id: SourceImageEntrypoints.test,
                    roots: [task.id])
            ],
            storage: [
                StorageDeclaration(
                    id: "source-image-attachment",
                    owner: descriptor.id,
                    producers: [.task(task.id)],
                    storageClass: .cache,
                    root: root,
                    safetyRoot: root.removingLastComponent(),
                    // One image at a time; each run replaces it.
                    retentionPolicy: .singleWorkingSet)
            ])
    }
}
