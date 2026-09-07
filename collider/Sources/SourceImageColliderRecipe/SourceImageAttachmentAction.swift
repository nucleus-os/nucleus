import ColliderCore
import Foundation
import SourceImageAssembly
import SystemPackage

/// Builds a small image on the host and reads it from inside a container.
package struct SourceImageAttachmentAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        package let root: FilePath
        package let imageID: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: root)
            encoder.append(path: imageID)
        }
    }

    package static let kind: ActionKind = "source-image.attachment"

    private let root: FilePath
    private let imageID: FilePath

    package init(root: FilePath, imageID: FilePath) {
        self.root = root
        self.imageID = imageID
    }

    package var identity: Identity {
        Identity(root: root, imageID: imageID)
    }

    /// What the guest runs, and the single description the effects come from.
    ///
    /// Listing the effects by hand beside an execution is two descriptions of
    /// one thing, and the first sweep found them disagreeing: the container
    /// read the builder image, which the task consumed and the action had not
    /// declared. Deriving them means adding a mount cannot leave the
    /// declaration behind.
    private var execution: OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: imageID,
            hostname: "collider-source-image",
            workingDirectory: "/source",
            hostWorkingDirectory: root,
            mounts: [],
            // The image is mounted where it lies. There is no volume to
            // establish from it and no copy of its bytes: an artifact that
            // happens to be a filesystem is attached as one.
            blockImageMounts: [
                OCIBlockImageMount(
                    image: root.appending("source.img"),
                    target: "/source",
                    access: .readOnly)
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 1_024 * 1_024 * 1_024,
                processCount: 256),
            containerEnvironment: [:],
            // The builder image dispatches on a build mode, and this is not
            // one of them. Reading a filesystem needs a shell rather than a
            // builder, so the entrypoint is replaced instead of argued with.
            imageEntrypointOverride: "/bin/sh",
            // One line per fact, so a disagreement names which one.
            command: [
                "-c",
                "stat -c %i /source/readable; stat -c %i /source/nested/hardlink; "
                    + "stat -c %a /source/executable; "
                    + "readlink /source/relative-link; cat /source/readable",
            ],
            environment: [:],
            output: .captured(limit: 64 * 1_024))
    }

    package var requirements: ActionRequirements {
        let container = ociActionRequirements(execution: execution)
        return ActionRequirements(
            effects: ([ActionEffect(.readWrite, scope: .output(root))]
                + container.effects).uniqued(),
            persistentWorkspaceEffects: container.persistentWorkspaceEffects,
            // The action itself runs on the host: it writes the tree and the
            // image before anything can read them.
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let tree = root.appending("tree")
        try context.files.remove(tree)
        try context.files.createDirectory(tree.appending("nested"))
        try context.files.write(
            Array("portable contents\n".utf8), to: tree.appending("readable"))
        try context.files.write(
            Array("#!/bin/sh\nexit 0\n".utf8), to: tree.appending("executable"))
        try context.files.setPermissions(0o755, for: tree.appending("executable"))
        try context.files.replaceSymlink(
            at: tree.appending("relative-link"), target: "readable")
        // The declared filesystem has no hard link operation, because nothing
        // else needs one. This is inside the output this action declares, so
        // the effect still bounds it.
        try FileManager.default.linkItem(
            atPath: tree.appending("readable").string,
            toPath: tree.appending("nested/hardlink").string)

        try SourceTreeImage.write(tree: tree, to: root.appending("source.img"))

        let result = try await context.containers.execute(execution)
        let lines = result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard lines.count == 5 else {
            throw SourceImageAttachmentFailure(
                "the guest reported \(lines.count) facts rather than five: \(lines)")
        }
        // The guest kernel resolving both names to one inode is the claim the
        // host-side reading cannot make on the kernel's behalf.
        guard lines[0] == lines[1] else {
            throw SourceImageAttachmentFailure(
                "the guest sees two inodes for one file: \(lines[0]) and \(lines[1])")
        }
        guard lines[2] == "755" else {
            throw SourceImageAttachmentFailure(
                "the guest sees mode \(lines[2]) where the tree had 755")
        }
        guard lines[3] == "readable" else {
            throw SourceImageAttachmentFailure(
                "the guest resolves the symbolic link to \(lines[3])")
        }
        guard lines[4] == "portable contents" else {
            throw SourceImageAttachmentFailure(
                "the guest reads \(lines[4]) where the tree held its contents")
        }
    }
}

private struct SourceImageAttachmentFailure: Error, CustomStringConvertible,
    Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "source image attachment failed: \(description)"
    }
}
