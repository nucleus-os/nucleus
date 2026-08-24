import ColliderCore
import Foundation
import SystemPackage

/// The hicolor icon sizes the browser package ships.
///
/// Chromium's theme directory decides this: it carries
/// `product_logo_<size>.png` for each of these and nothing else usable as an
/// app icon. It has a `product_logo_22_mono.png`, which is a symbolic
/// monochrome variant rather than a 22x22 app icon, and a
/// `product_logo_name_22.png`, which is a wordmark — so 22 is not a size the
/// package can offer.
///
/// The producer and the package contract read this one list. They previously
/// held the same literal twice, and the producer copied each size only when it
/// found one while the contract declared a symbolic link for every size
/// unconditionally, so a size Chromium does not ship became a dangling link in
/// the payload rather than an error at the point it went missing.
package let browserIconSizes = [16, 24, 32, 48, 64, 128, 256]

package struct BrowserPackageInputPublication: Hashable, Sendable {
    package let target: ArtifactTarget
    package let distributionRoot: FilePath
    package let packageInputRoot: FilePath

    package init(
        target: ArtifactTarget,
        distributionRoot: FilePath,
        packageInputRoot: FilePath
    ) {
        self.target = target
        self.distributionRoot = distributionRoot
        self.packageInputRoot = packageInputRoot
    }
}

package struct BrowserPackageInputManifest: Codable, Equatable, Sendable {
    package let packageName: String
    package let artifactTarget: ArtifactTarget
    package let payloadDigest: ArtifactDigest
    package let payloadGeneration: String
    package let buildManifestDigest: ArtifactDigest
    package let hostCapabilities: [String]

    package init(
        artifactTarget: ArtifactTarget,
        payloadDigest: ArtifactDigest,
        payloadGeneration: String,
        buildManifestDigest: ArtifactDigest
    ) {
        packageName = "nucleus-browser"
        self.artifactTarget = artifactTarget
        self.payloadDigest = payloadDigest
        self.payloadGeneration = payloadGeneration
        self.buildManifestDigest = buildManifestDigest
        hostCapabilities = [
            "audio.alsa",
            "desktop.at-spi",
            "desktop.gtk3",
            "device.udev",
            "font.fontconfig",
            "font.pango",
            "graphics.cairo",
            "graphics.gbm",
            "ipc.dbus",
            "network.nss",
            "printing.cups",
            "runtime.expat",
            "runtime.glib",
            "x11.compatibility",
            "xkb.common",
        ]
    }

    package var identity: ArtifactDigest {
        var encoder = IdentityEncoder()
        encoder.append("browser-package-input")
        encoder.append(artifactTarget.operatingSystem.rawValue)
        encoder.append(artifactTarget.architecture.rawValue)
        encoder.append(artifactTarget.abi ?? "")
        encoder.append(UInt64(artifactTarget.androidAPILevel ?? 0))
        encoder.append(digest: payloadDigest)
        encoder.append(payloadGeneration)
        encoder.append(digest: buildManifestDigest)
        encoder.appendSequence(hostCapabilities) { $0.append($1) }
        return ArtifactDigest.sha256(encoder.bytes)
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
        manifest.artifactTarget == publication.target,
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

package func validatedBrowserPublicationPayload(
    distributionRoot: FilePath,
    files: ActionFileSystem
) throws -> FilePath {
    let current = distributionRoot.appending("current")
    guard
        try files.metadataWithoutFollowingSymlinks(for: current)?.type
            == .symbolicLink
    else {
        throw BrowserPackageInputFailure(
            "published browser generation is missing")
    }
    let target = try files.readSymbolicLink(current)
    guard
        target.range(
            of: #"^generations/sha256-[0-9a-f]{64}$"#,
            options: .regularExpression) != nil
    else {
        throw BrowserPackageInputFailure(
            "published browser generation is not content addressed: \(target)")
    }
    let payload = distributionRoot.appending(target)
    try validateBrowserGenerationStructure(payload, files: files)
    let digest = try files.digest(tree: payload)
    guard target == "generations/sha256-\(digest.hexadecimal)" else {
        throw BrowserPackageInputFailure(
            "published browser generation digest does not match its payload")
    }
    return payload
}

package func validateBrowserGenerationStructure(
    _ generation: FilePath,
    files: ActionFileSystem
) throws {
    let runtime = generation.appending("runtime")
    for relative in [
        "nucleus-browser-bin", "chrome_crashpad_handler",
        "chrome_sandbox", "icudtl.dat", "resources.pak",
        "chrome_100_percent.pak", "chrome_200_percent.pak",
        "locales", "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
    ] {
        guard try files.metadata(for: runtime.appending(relative)) != nil else {
            throw BrowserPackageInputFailure(
                "browser generation is missing: \(relative)")
        }
    }
    for relative in browserIconSizes.map({
        "share/icons/hicolor/\($0)x\($0)/apps/dev.nucleus.Browser.png"
    }) + [
        "nucleus-build-manifest.json",
        "bin/nucleus-browser",
    ] {
        guard try files.metadata(for: generation.appending(relative)) != nil else {
            throw BrowserPackageInputFailure(
                "browser generation is missing: \(relative)")
        }
    }
}

private struct BrowserPackageInputFailure: Error, CustomStringConvertible,
    Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "browser package input failed: \(description)"
    }
}
