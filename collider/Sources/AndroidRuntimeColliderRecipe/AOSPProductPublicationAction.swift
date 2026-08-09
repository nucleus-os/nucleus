import ColliderCore
import SystemPackage

extension DirectoryNamePattern {
    fileprivate static let aospProduct = Self(
        rawValue: #"^[0-9]+-[a-z0-9][a-z0-9._-]*$"#)
}

struct PublishAOSPProductAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let buildRoot: FilePath
        let product: String

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: buildRoot.string)
            encoder.append(tag: 2, string: product)
        }
    }

    static let kind: ActionKind = "android-runtime.publish-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(buildRoot: build.artifactRoot, product: build.product)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .publication(aospBuildRoot))
            ],
            executionPlatform: .macOSARM64Native)
    }

    private var generations: FilePath {
        build.artifactRoot.removingLastComponent()
    }

    private var aospBuildRoot: FilePath {
        generations.removingLastComponent()
    }

    func execute(in context: ActionContext) async throws {
        let staged = build.artifactRoot.appending("staged")
        let signed = build.artifactRoot.appending("signed")
        let finalImages = build.artifactRoot.appending("images")
        try context.files.createDirectory(signed)

        try replace(
            staged.appending("\(build.product)-target_files.zip"),
            with: signed.appending("\(build.product)-target_files.zip"),
            files: context.files)
        try replace(
            staged.appending("\(build.product)-images.zip"),
            with: signed.appending("\(build.product)-images.zip"),
            files: context.files)

        let imageCandidate = build.artifactRoot.appending(
            ".images-publication-candidate")
        try context.files.remove(imageCandidate)
        defer { try? context.files.remove(imageCandidate) }
        guard
            try context.files.metadata(for: staged.appending("images"))?.type
                == .directory
        else {
            throw AOSPProductPublicationFailure.missingInput(
                staged.appending("images"))
        }
        try context.files.copyTree(
            from: staged.appending("images"),
            to: imageCandidate)
        try context.files.remove(finalImages)
        try context.files.move(from: imageCandidate, to: finalImages)

        // Provenance is the publication commit marker. Framework boot rejects
        // any artifact set whose digests do not match this file.
        try replace(
            staged.appending("image-provenance.json"),
            with: signed.appending("image-provenance.json"),
            files: context.files)

        let active = aospBuildRoot.appending("current")
        let generationName = build.artifactRoot.lastComponent?.string ?? ""
        try context.files.replaceSymlink(
            at: active,
            target: "generations/\(generationName)")
        try context.files.pruneDirectories(
            DirectoryRetentionPlan(
                safetyRoot: aospBuildRoot,
                rules: [
                    DirectoryRetentionRule(
                        root: generations,
                        current: active,
                        retain: AndroidRuntimeColliderRecipe.rollbackGenerationCount,
                        naming: .aospProduct)
                ]))
    }

    private func replace(
        _ source: FilePath,
        with destination: FilePath,
        files: ActionFileSystem
    ) throws {
        guard try files.metadata(for: source)?.type == .regular else {
            throw AOSPProductPublicationFailure.missingInput(source)
        }
        try files.remove(destination)
        try files.copy(from: source, to: destination)
    }
}

private enum AOSPProductPublicationFailure: Error, CustomStringConvertible {
    case missingInput(FilePath)

    var description: String {
        switch self {
        case .missingInput(let path):
            "AOSP publication input is missing: \(path)"
        }
    }
}
