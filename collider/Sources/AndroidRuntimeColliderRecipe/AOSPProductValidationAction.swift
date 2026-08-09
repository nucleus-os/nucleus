import ColliderCore
import Foundation
import SystemPackage

#if canImport(FoundationXML)
import FoundationXML
#endif

struct ValidateAOSPProductAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let productSource: FilePath
        let sourceProvenance: FilePath
        let buildRoot: FilePath
        let signingIdentity: FilePath
        let product: String
        let release: String
        let variant: String
        let buildNumber: String
        let buildTimestamp: UInt64
        let expectedPlatformSDK: UInt32
        let expectedVendorAPILevel: UInt32
        let sourceOverlays: [AOSPProductSourceOverlay]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: productSource.string)
            encoder.append(tag: 2, string: sourceProvenance.string)
            encoder.append(tag: 3, string: buildRoot.string)
            encoder.append(tag: 4, string: signingIdentity.string)
            encoder.append(tag: 5, string: product)
            encoder.append(tag: 6, string: release)
            encoder.append(tag: 7, string: variant)
            encoder.append(tag: 8, string: buildNumber)
            encoder.append(tag: 9, integer: buildTimestamp)
            encoder.append(tag: 10, integer: UInt64(expectedPlatformSDK))
            encoder.append(tag: 11, integer: UInt64(expectedVendorAPILevel))
            var overlays = CanonicalDigestEncoder(
                identityPathMap: encoder.identityPathMap)
            for overlay in sourceOverlays.sorted(by: {
                $0.relativeDestination < $1.relativeDestination
            }) {
                overlays.append(tag: 1, string: overlay.source.string)
                overlays.append(tag: 2, string: overlay.relativeDestination)
            }
            encoder.append(tag: 12, bytes: overlays.bytes)
            encoder.append(tag: 13, string: aospPackageValidationProgram)
        }
    }

    static let kind: ActionKind = "android-runtime.validate-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(
            productSource: build.productSource,
            sourceProvenance: build.sourceProvenance,
            buildRoot: build.artifactRoot,
            signingIdentity: build.signingIdentity,
            product: build.product,
            release: build.release,
            variant: build.variant,
            buildNumber: build.buildNumber,
            buildTimestamp: build.buildTimestamp,
            expectedPlatformSDK: build.expectedPlatformSDK,
            expectedVendorAPILevel: build.expectedVendorAPILevel,
            sourceOverlays: build.sourceOverlays)
    }

    var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .input(build.productSource)),
            ActionEffect(.read, scope: .input(build.sourceProvenance)),
            ActionEffect(.read, scope: .input(build.containerImageID)),
            ActionEffect(.read, scope: .input(build.signingIdentity)),
            ActionEffect(.readWrite, scope: .scratch(build.artifactRoot)),
        ]
        for overlay in build.sourceOverlays {
            let effect = ActionEffect(.read, scope: .input(overlay.source))
            if !effects.contains(effect) { effects.append(effect) }
        }
        return ActionRequirements(
            effects: effects,
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: build.outputWorkspace,
                    target: "/src/out",
                    access: .readOnly)
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .androidX86_64(
                apiLevel: build.expectedPlatformSDK))
    }

    var environment: [String: String] { build.environment }

    func execute(in context: ActionContext) async throws {
        try await AOSPProductValidationWorkflow(
            build: build,
            context: context
        ).execute()
    }
}

private struct AOSPProductValidationWorkflow {
    let build: AOSPProductBuild
    let context: ActionContext

    func execute() async throws {
        try context.files.remove(validationRoot)
        try context.files.createDirectory(validationRoot)
        defer { try? context.files.remove(validationRoot) }

        let sourceProvenance = try JSONDecoder().decode(
            AOSPValidationSourceProvenance.self,
            from: Data(try context.files.read(build.sourceProvenance)))
        let productDigest = try aospProductDefinitionDigest(
            productSource: build.productSource,
            sourceOverlays: build.sourceOverlays,
            files: context.files)
        let staged = build.artifactRoot.appending("staged")
        let hostTools = FilePath("/src/out/host/linux-x86/bin")
        let targetFiles = staged.appending("\(build.product)-target_files.zip")
        let imageArchive = staged.appending("\(build.product)-images.zip")
        let imagesRoot = staged.appending("images")
        let environment = productEnvironment()
        let releasePEM = build.signingIdentity.appending("releasekey.pem")
        let avbTool = hostTools.appending("avbtool")

        var images: [AOSPImageProvenance.Image] = []
        for name in aospRequiredProductImages {
            let image = imagesRoot.appending(name)
            guard let metadata = try context.files.metadata(for: image),
                metadata.type == .regular
            else {
                throw failure("validated Android image is missing: \(name)")
            }
            images.append(
                AOSPImageProvenance.Image(
                    name: name,
                    size: metadata.size,
                    storageFormat: "raw",
                    sha256: try context.files.digest(file: image).hexadecimal))
        }
        try await checked(
            .path(avbTool),
            [
                "verify_image",
                "--image", imagesRoot.appending("vbmeta.img").string,
                "--key", releasePEM.string,
                "--follow_chain_partitions",
            ],
            in: imagesRoot,
            environment: environment)

        let systemBuildProperties = try await archiveEntry(
            archive: targetFiles,
            candidates: ["SYSTEM/build.prop"],
            environment: environment)
        let vendorBuildProperties = try await archiveEntry(
            archive: targetFiles,
            candidates: ["VENDOR/build.prop"],
            environment: environment)
        let systemProperties = aospProperties(systemBuildProperties)
        let vendorProperties = aospProperties(vendorBuildProperties)
        try await requireFontContract(
            archive: targetFiles,
            environment: environment)
        guard
            systemProperties["ro.build.version.sdk"]
                == String(build.expectedPlatformSDK)
        else {
            throw failure(
                "signed product SDK is "
                    + "\(systemProperties["ro.build.version.sdk"] ?? "missing"); "
                    + "expected \(build.expectedPlatformSDK)")
        }
        guard
            vendorProperties["ro.vendor.api_level"]
                == String(build.expectedVendorAPILevel)
                || vendorProperties["ro.board.api_level"]
                    == String(build.expectedVendorAPILevel)
        else {
            throw failure(
                "signed product does not declare vendor API level "
                    + "\(build.expectedVendorAPILevel)")
        }
        let fingerprint = systemProperties["ro.system.build.fingerprint"] ?? ""
        guard fingerprint.contains("/\(build.product):"),
            fingerprint.hasSuffix(":user/release-keys"),
            build.variant == "user"
        else {
            throw failure(
                "signed production product fingerprint is invalid: \(fingerprint)")
        }
        try await requireReleaseSigning(
            archive: targetFiles,
            hostTools: hostTools,
            environment: environment)

        let signing = try JSONDecoder().decode(
            AOSPSigningIdentity.self,
            from: Data(
                try context.files.read(
                    build.signingIdentity.appending("signing-identity.json"))))
        let provenance = AOSPImageProvenance(
            status: "signed",
            product: build.product,
            release: build.release,
            variant: build.variant,
            buildNumber: build.buildNumber,
            buildTimestamp: build.buildTimestamp,
            platformSDK: build.expectedPlatformSDK,
            vendorAPILevel: build.expectedVendorAPILevel,
            fingerprint: fingerprint,
            sourceManifestCommit: sourceProvenance.manifestCommit,
            sourceSuperprojectCommit: sourceProvenance.superprojectCommit,
            sourceManifestSHA256: sourceProvenance.resolvedManifestSHA256,
            productTreeSHA256: productDigest.hexadecimal,
            signingPurpose: signing.purpose,
            signingCertificates: signing.certificates,
            targetFilesSHA256: try context.files.digest(file: targetFiles).hexadecimal,
            imageArchiveSHA256: try context.files.digest(file: imageArchive).hexadecimal,
            images: images.sorted { $0.name < $1.name })
        try context.files.write(
            Array(try JSONEncoder().encode(provenance)),
            to: staged.appending("image-provenance.json"))
    }

    private func requireReleaseSigning(
        archive: FilePath,
        hostTools: FilePath,
        environment: [String: String]
    ) async throws {
        let releaseKey = build.signingIdentity.appending("releasekey")
        let releasePEM = FilePath(releaseKey.string + ".pem")
        let releaseCertificate = FilePath(releaseKey.string + ".x509.pem")
        let metadata = try await archiveEntry(
            archive: archive,
            candidates: ["META/misc_info.txt"],
            environment: environment)
        guard aospReleaseSigningMetadataUsesContainerKeys(metadata) else {
            throw failure(
                "signed target-files do not declare the Nucleus release keys")
        }

        let apksigner = hostTools.appending("apksigner")
        let avbTool = hostTools.appending("avbtool")
        let certificateOutput = try await captured(
            .named("openssl"),
            [
                "x509", "-in", releaseCertificate.string,
                "-noout", "-fingerprint", "-sha256",
            ],
            in: build.signingIdentity,
            environment: environment)
        guard let separator = certificateOutput.firstIndex(of: "=") else {
            throw failure(
                "could not read the Nucleus release certificate fingerprint")
        }
        let expectedCertificateDigest = certificateOutput[
            certificateOutput.index(after: separator)...
        ]
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        let program = validationRoot.appending("validate-aosp-packages.py")
        try context.files.write(
            Array(aospPackageValidationProgram.utf8),
            to: program)
        try await checked(
            .named("python3"),
            [
                program.string,
                "--archive", archive.string,
                "--scratch", validationRoot.string,
                "--apksigner", apksigner.string,
                "--avbtool", avbTool.string,
                "--release-key", releasePEM.string,
                "--certificate-sha256", expectedCertificateDigest,
                "--minimum-sdk", String(build.expectedPlatformSDK),
                "--workers", String(build.buildJobs),
            ],
            in: validationRoot,
            environment: environment)
    }

    private func requireFontContract(
        archive: FilePath,
        environment: [String: String]
    ) async throws {
        let entries = try await captured(
            .named("unzip"),
            ["-Z1", archive.string],
            in: archive.removingLastComponent(),
            environment: environment
        ).split(whereSeparator: \.isNewline).map(String.init)
        let configurations = [
            "SYSTEM/etc/fonts.xml",
            "SYSTEM/etc/font_fallback.xml",
        ]
        for path in configurations where !entries.contains(path) {
            throw failure("signed Android font contract is missing \(path)")
        }
        var contents: [String: String] = [:]
        for path in configurations {
            contents[path] = try await archiveEntry(
                archive: archive,
                candidates: [path],
                environment: environment)
        }
        try validateAOSPFontContract(
            archiveEntries: entries,
            configurations: contents)
    }

    private func archiveEntry(
        archive: FilePath,
        candidates: [String],
        environment: [String: String]
    ) async throws -> String {
        var output = ""
        for candidate in candidates {
            let result = try await command(
                .named("unzip"),
                ["-p", archive.string, candidate],
                in: archive.removingLastComponent(),
                environment: environment)
            if result.status == 0, !result.standardOutput.isEmpty {
                output += result.standardOutput + "\n"
            }
        }
        guard !output.isEmpty else {
            throw failure("required metadata is missing from \(archive)")
        }
        return output
    }

    private func checked(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String]
    ) async throws {
        let result = try await command(
            executable,
            arguments,
            in: directory,
            environment: environment)
        guard result.succeeded else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw result.executionFailure(
                reason: "\(arguments.first ?? "command") failed"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    private func captured(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String]
    ) async throws -> String {
        let result = try await command(
            executable,
            arguments,
            in: directory,
            environment: environment)
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "\(arguments.first ?? "command") failed")
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func command(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String]
    ) async throws -> CommandResult {
        let executablePath =
            switch executable {
            case .named(let name), .operationalNamed(let name): name
            case .path(let path), .taskOutput(let path): containerPath(path.string)
            case .artifact(let reference): containerPath(reference.path.string)
            }
        return try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(validationRoot, "/validation")],
                readOnlyMounts: [
                    (build.source, "/src"),
                    (build.signingIdentity, "/keys"),
                    (build.artifactRoot, "/export"),
                ],
                persistentWorkspaceMounts: [build.readOnlyOutputMount],
                command: [executablePath]
                    + arguments.map(containerPath),
                workingDirectory: containerPath(directory.string),
                containerEnvironment: environment.mapValues(containerPath),
                output: .captured(limit: 32 * 1_024 * 1_024)))
    }

    private func productEnvironment() -> [String: String] {
        var environment = aospProductContainerToolEnvironment()
        environment["TARGET_PRODUCT"] = build.product
        environment["TARGET_BUILD_VARIANT"] = build.variant
        environment["TARGET_RELEASE"] = build.release
        environment["OUT_DIR"] = "out"
        environment["DIST_DIR"] = "/export/dist"
        environment["BUILD_NUMBER"] = build.buildNumber
        environment["BUILD_DATETIME"] = String(build.buildTimestamp)
        environment["BUILD_USERNAME"] = "nucleus"
        environment["BUILD_HOSTNAME"] = "collider"
        environment["TZ"] = "UTC"
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"
        environment["PATH"] =
            "/src/out/host/linux-x86/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    private func containerPath(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: validationRoot.string,
                with: "/validation"
            )
            .replacingOccurrences(
                of: build.signingIdentity.string,
                with: "/keys"
            )
            .replacingOccurrences(
                of: build.artifactRoot.string,
                with: "/export"
            )
            .replacingOccurrences(
                of: build.source.string,
                with: "/src")
    }

    private var validationRoot: FilePath {
        build.artifactRoot.appending("validation")
    }

    private func failure(_ message: String) -> AOSPProductValidationFailure {
        AOSPProductValidationFailure.invalidOutput(message)
    }
}

func aospReleaseSigningMetadataUsesContainerKeys(_ metadata: String) -> Bool {
    let properties = aospProperties(metadata)
    return properties["avb_vbmeta_key_path"] == aospContainerReleasePEM
        && properties["avb_vbmeta_system_key_path"] == aospContainerReleasePEM
        && properties["default_system_dev_certificate"]
            == aospContainerReleaseKey
}

func validateAOSPFontContract(
    archiveEntries: [String],
    configurations: [String: String]
) throws {
    let required = [
        "SYSTEM/etc/fonts.xml",
        "SYSTEM/etc/font_fallback.xml",
    ]
    for path in required where configurations[path] == nil {
        throw AOSPProductValidationFailure.invalidOutput(
            "signed Android font contract is missing \(path)")
    }
    var referencesByConfiguration: [String: Set<String>] = [:]
    for path in required {
        guard let xml = configurations[path],
            let data = xml.data(using: .utf8)
        else { continue }
        let parser = XMLParser(data: data)
        let delegate = AOSPFontReferenceParser()
        // XMLParser keeps this reference unowned; the local strong reference
        // outlives the synchronous parse below.
        #if canImport(Darwin)
        unsafe parser.delegate = delegate
        #else
        parser.delegate = delegate
        #endif
        guard parser.parse() else {
            throw AOSPProductValidationFailure.invalidOutput(
                "signed Android font configuration is malformed: \(path)")
        }
        referencesByConfiguration[path] = delegate.references
    }
    guard
        referencesByConfiguration["SYSTEM/etc/fonts.xml"]?
            .contains("Roboto-Regular.ttf") == true
    else {
        throw AOSPProductValidationFailure.invalidOutput(
            "signed Android font contract has no Roboto default family")
    }

    // Android 17 loads font_fallback.xml as its runtime font map. fonts.xml is
    // the legacy compatibility and Zygote-preloading view, whose parser
    // deliberately tolerates entries for files omitted by the selected product.
    let references =
        referencesByConfiguration["SYSTEM/etc/font_fallback.xml"] ?? []
    let entries = Set(archiveEntries)
    let partitionRoots = ["SYSTEM", "PRODUCT", "SYSTEM_EXT", "VENDOR"]
    let missing = references.filter { reference in
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard !normalized.split(separator: "/").contains("..") else {
            return true
        }
        if normalized.hasPrefix("/") {
            let path = normalized.dropFirst()
            let components = path.split(separator: "/", maxSplits: 1)
            guard components.count == 2 else { return true }
            let partition = components[0].uppercased()
            guard partitionRoots.contains(partition) else { return true }
            return !entries.contains("\(partition)/\(components[1])")
        }
        return !entries.contains("SYSTEM/fonts/\(normalized)")
    }
    guard missing.isEmpty else {
        throw AOSPProductValidationFailure.invalidOutput(
            "signed Android font configurations reference missing fonts: "
                + missing.sorted().joined(separator: ", "))
    }
}

private final class AOSPFontReferenceParser: NSObject, XMLParserDelegate {
    private(set) var references: Set<String> = []
    private var fontText: String?
    private var depth = 0
    private var ignoredFamilyDepth: Int?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        if elementName == "family",
            ["true", "1"].contains(attributes["ignore"])
        {
            ignoredFamilyDepth = depth
        } else if elementName == "font", ignoredFamilyDepth == nil {
            fontText = ""
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        fontText?.append(string)
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if elementName == "font", let fontText {
            let reference = fontText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !reference.isEmpty { references.insert(reference) }
            self.fontText = nil
        }
        if elementName == "family", ignoredFamilyDepth == depth {
            ignoredFamilyDepth = nil
        }
        depth -= 1
    }
}

private func aospProperties(_ contents: String) -> [String: String] {
    Dictionary(
        uniqueKeysWithValues:
            contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=")
                else { return nil }
                return (
                    String(line[..<equals]),
                    String(line[line.index(after: equals)...])
                )
            })
}

private struct AOSPValidationSourceProvenance: Decodable {
    let manifestCommit: String
    let superprojectCommit: String
    let resolvedManifestSHA256: String
}

private struct AOSPImageProvenance: Encodable {
    struct Image: Encodable {
        let name: String
        let size: UInt64
        let storageFormat: String
        let sha256: String
    }

    let status: String
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
    let fingerprint: String
    let sourceManifestCommit: String
    let sourceSuperprojectCommit: String
    let sourceManifestSHA256: String
    let productTreeSHA256: String
    let signingPurpose: String
    let signingCertificates: [AOSPSigningIdentity.Certificate]
    let targetFilesSHA256: String
    let imageArchiveSHA256: String
    let images: [Image]
}

private enum AOSPProductValidationFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
    }
}
