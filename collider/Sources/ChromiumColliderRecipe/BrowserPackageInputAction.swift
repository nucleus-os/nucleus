import ColliderCore
import Foundation
import SystemPackage

package struct PublishBrowserPackageInputAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let publication: BrowserPackageInputPublication

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(publication.target.architecture.rawValue)
            encoder.append(path: publication.distributionRoot)
            encoder.append(path: publication.packageInputRoot)
        }
    }

    package static let kind: ActionKind = "browser.publish-package-input"

    let publication: BrowserPackageInputPublication

    package init(publication: BrowserPackageInputPublication) {
        self.publication = publication
    }

    package var identity: Identity { Identity(publication: publication) }
    package var environment: [String: String] { [:] }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(
                    .read,
                    scope: .input(publication.distributionRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(publication.packageInputRoot)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let payload = try validatedBrowserPublicationPayload(
            distributionRoot: publication.distributionRoot,
            files: context.files)
        let payloadDigest = try context.files.digest(tree: payload)
        let buildManifest = payload.appending("nucleus-build-manifest.json")
        let manifest = BrowserPackageInputManifest(
            artifactTarget: publication.target.artifactTarget,
            payloadDigest: payloadDigest,
            payloadGeneration: try context.files.readSymbolicLink(
                publication.distributionRoot.appending("current")),
            buildManifestDigest: try context.files.digest(file: buildManifest))
        let manifestIdentity = manifest.identity
        let generations = publication.packageInputRoot.appending("generations")
        try context.files.createDirectory(generations)
        let candidate = generations.appending(
            ".sha256-\(manifestIdentity.hexadecimal).prepared")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        var published = false
        defer {
            if !published { try? context.files.remove(candidate) }
        }
        try context.files.write(
            try encodedJSON(manifest),
            to: candidate.appending("browser-package-input.json"))
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generations.appending(
                "sha256-\(manifestIdentity.hexadecimal)"),
            active: publication.packageInputRoot.appending("current"))
        published = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        _ = try validatedBrowserPackageInput(publication, files: files)
    }
}

@discardableResult
package func validatedBrowserPackageInput(
    _ publication: BrowserPackageInputPublication,
    files: ActionFileSystem
) throws -> BrowserPackageInputManifest {
    let current = publication.packageInputRoot.appending("current")
    guard
        try files.metadataWithoutFollowingSymlinks(for: current)?.type
            == .symbolicLink
    else {
        throw BrowserPackageInputFailure(
            "browser package input publication is missing")
    }
    let target = try files.readSymbolicLink(current)
    guard
        target.range(
            of: #"^generations/sha256-[0-9a-f]{64}$"#,
            options: .regularExpression) != nil
    else {
        throw BrowserPackageInputFailure(
            "browser package input is not content addressed: \(target)")
    }
    let manifestPath = publication.packageInputRoot.appending(target).appending(
        "browser-package-input.json")
    let manifest: BrowserPackageInputManifest
    do {
        manifest = try JSONDecoder().decode(
            BrowserPackageInputManifest.self,
            from: Data(files.read(manifestPath)))
    } catch {
        throw BrowserPackageInputFailure(
            "browser package input manifest is invalid: \(error)")
    }
    guard manifest.packageName == "nucleus-browser",
        manifest.artifactTarget == publication.target.artifactTarget,
        target == "generations/sha256-\(manifest.identity.hexadecimal)"
    else {
        throw BrowserPackageInputFailure(
            "browser package input identity does not match its target")
    }
    let payload = publication.distributionRoot.appending(
        manifest.payloadGeneration)
    let activePayload = try validatedBrowserPublicationPayload(
        distributionRoot: publication.distributionRoot,
        files: files)
    guard payload == activePayload,
        try files.digest(tree: payload) == manifest.payloadDigest,
        try files.digest(
            file: payload.appending("nucleus-build-manifest.json"))
            == manifest.buildManifestDigest
    else {
        throw BrowserPackageInputFailure(
            "browser package input does not match its immutable payload")
    }
    return manifest
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    var bytes = Array(try encoder.encode(value))
    bytes.append(0x0a)
    return bytes
}

private struct BrowserPackageInputFailure: Error, CustomStringConvertible,
    Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "browser package input failed: \(description)"
    }
}
