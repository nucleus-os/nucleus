import ColliderCore
import Foundation
import SourceImageAssembly
import SystemPackage

/// Writes one prepared source generation into the image its consumers read.
///
/// The tree this images is immutable once published, so the image is a pure
/// function of it and is published as a generation beside it: one directory
/// per source identity, reclaimed by the same rule.
package struct BuildChromiumSourceImageAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let imaging: ChromiumSourceImaging

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(imaging.sourceID)
            encoder.append(path: imaging.sourceRoot)
            encoder.append(path: imaging.images)
            encoder.append(path: imaging.imageRoot)
            encoder.append(path: imaging.current)
            // The identity every entry is recorded under decides what a
            // consumer may read, so it belongs to what the image is.
            encoder.append(UInt64(chromiumSourceImageOwner.userID))
            encoder.append(UInt64(chromiumSourceImageOwner.groupID))
        }
    }

    package static let kind: ActionKind = "browser.build-source-image"

    let imaging: ChromiumSourceImaging

    package init(imaging: ChromiumSourceImaging) {
        self.imaging = imaging
    }

    package var identity: Identity { Identity(imaging: imaging) }
    package var environment: [String: String] { imaging.environment }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .publication(imaging.images)),
                ActionEffect(.read, scope: .input(imaging.sourceRoot)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        guard
            try context.files.metadata(
                for: imaging.sourceRoot.appending("source-provenance.json")
            )?.type == .regular
        else {
            throw failure(
                "Chromium source generation is not prepared: "
                    + imaging.sourceRoot.string)
        }
        if try context.files.metadata(for: imaging.image)?.type == .regular {
            try context.files.replaceSymlink(
                at: imaging.current, target: imaging.sourceID)
            return
        }

        try context.files.createDirectory(imaging.images)
        let candidate = imaging.images.appending(
            ".\(imaging.sourceID).preparing")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        try SourceTreeImage.write(
            tree: imaging.sourceRoot,
            to: candidate.appending("source.img"),
            identity: filesystemIdentity,
            owner: chromiumSourceImageOwner,
            overlays: try sysrootOverlays(files: context.files))
        try context.files.publishGeneration(
            candidate: candidate,
            generation: imaging.imageRoot,
            active: imaging.current)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        guard let metadata = try files.metadata(for: imaging.image),
            metadata.type == .regular,
            metadata.size > 0
        else {
            throw failure("Chromium source image is missing: \(imaging.image)")
        }
    }

    /// The sysroots, read from their archives rather than from the tree.
    ///
    /// A sysroot is a Debian root holding names that differ only in case, and
    /// the host volume is case insensitive, so the copy `gclient runhooks`
    /// leaves in the tree is missing entries. The consumer used to repair that
    /// by deleting the directory and extracting the archive itself; the image
    /// is where that now happens, because a read-only filesystem gives the
    /// consumer nowhere to do it.
    ///
    /// Which archives exist is a property of the generation rather than of the
    /// graph, so they are discovered here by the same rule the consumer used:
    /// every archive names the sysroot directory it belongs in, and a stamp
    /// must sit beside it.
    private func sysrootOverlays(
        files: ActionFileSystem
    ) throws -> [ArchiveOverlay] {
        let linux = FilePath("/chromium/src/build/linux")
        var overlays: [ArchiveOverlay] = []
        for entry in try files.listDirectory(imaging.sysrootArchives)
        where entry.relativePath.hasSuffix(".tar.xz") {
            let name = String(entry.relativePath.dropLast(".tar.xz".count))
            let stamp = imaging.sysrootArchives.appending("\(name).stamp")
            guard try files.metadata(for: stamp)?.type == .regular else {
                throw failure(
                    "Chromium sysroot archive has no stamp: \(entry.path)")
            }
            overlays.append(
                ArchiveOverlay(
                    archive: entry.path,
                    destination: linux.appending(name),
                    stamp: try files.read(stamp)))
        }
        guard !overlays.isEmpty else {
            throw failure(
                "Chromium source generation holds no Linux sysroot archive: "
                    + imaging.sysrootArchives.string)
        }
        return overlays.sorted { $0.destination.string < $1.destination.string }
    }

    /// The filesystem identity this image claims.
    ///
    /// Two distinct trees must not claim one filesystem UUID, and every
    /// machine preparing this revision must derive the same one, so it comes
    /// from the pinned inputs rather than from a generator.
    private var filesystemIdentity: UUID {
        let hexadecimal = ArtifactDigest.sha256(
            Array(imaging.sourceID.utf8)
        ).hexadecimal
        var digits = Array(hexadecimal.prefix(32))
        guard digits.count == 32 else {
            preconditionFailure("a sha256 digest is thirty-two hexadecimal digits")
        }
        for boundary in [20, 16, 12, 8] {
            digits.insert("-", at: boundary)
        }
        guard let identity = UUID(uuidString: String(digits)) else {
            preconditionFailure("hexadecimal digits name a UUID")
        }
        return identity
    }

    private func failure(_ description: String) -> ChromiumSourceImageFailure {
        ChromiumSourceImageFailure(description)
    }
}

/// The identity a Chromium build reads its source as.
///
/// The copy this replaces untarred with `--no-same-owner`, leaving the tree
/// owned by the builder that extracted it, and a checkout is not uniformly
/// world readable. Recording the same identity in the image keeps what a build
/// may read a property of the tree's modes rather than of how it arrived.
package let chromiumSourceImageOwner = OCIUserPolicy.builder

package struct ChromiumSourceImageFailure: Error, CustomStringConvertible,
    Sendable
{
    package let description: String

    init(_ description: String) {
        self.description = "Chromium source image failed: \(description)"
    }
}
