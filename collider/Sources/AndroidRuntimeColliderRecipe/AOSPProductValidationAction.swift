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
            var overlays = CanonicalDigestEncoder()
            for overlay in sourceOverlays.sorted(by: {
                $0.relativeDestination < $1.relativeDestination
            }) {
                overlays.append(tag: 1, string: overlay.source.string)
                overlays.append(tag: 2, string: overlay.relativeDestination)
            }
            encoder.append(tag: 12, bytes: overlays.bytes)
        }
    }

    static let kind: ActionKind = "android-runtime.validate-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(
            productSource: build.productSource,
            sourceProvenance: build.sourceProvenance,
            buildRoot: build.buildRoot,
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
            ActionEffect(.read, scope: .input(build.signingIdentity)),
            ActionEffect(.readWrite, scope: .scratch(build.buildRoot)),
        ]
        for overlay in build.sourceOverlays {
            let effect = ActionEffect(.read, scope: .input(overlay.source))
            if !effects.contains(effect) { effects.append(effect) }
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "openssl",
                    executable: .named("openssl"),
                    role: .semantic),
                ActionToolRequirement(
                    "unzip",
                    executable: .named("unzip"),
                    role: .semantic),
            ],
            effects: effects)
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
        let sourceProvenance = try JSONDecoder().decode(
            AOSPValidationSourceProvenance.self,
            from: Data(try context.files.read(build.sourceProvenance)))
        let productDigest = try aospProductDefinitionDigest(
            productSource: build.productSource,
            sourceOverlays: build.sourceOverlays,
            files: context.files)
        let output = build.buildRoot.appending("out")
        let staged = build.buildRoot.appending("staged")
        let hostTools = output.appending("host/linux-x86/bin")
        let targetFiles = staged.appending("\(build.product)-target_files.zip")
        let imageArchive = staged.appending("\(build.product)-images.zip")
        let imagesRoot = staged.appending("images")
        let environment = productEnvironment(hostTools: hostTools)
        let releasePEM = build.signingIdentity.appending("releasekey.pem")
        let avbTool = hostTools.appending("avbtool")
        try requireExecutable(avbTool)

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
        try requireExecutable(apksigner)
        try requireExecutable(avbTool)
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

        let validation = archive.removingLastComponent().appending(
            ".package-validation")
        try context.files.remove(validation)
        defer { try? context.files.remove(validation) }
        try context.files.createDirectory(validation)
        let archiveEntries = try await captured(
            .named("unzip"),
            ["-Z1", archive.string],
            in: archive.removingLastComponent(),
            environment: environment
        ).split(whereSeparator: \.isNewline).map(String.init)
        let extensions = archiveEntries.map {
            URL(fileURLWithPath: $0).pathExtension.lowercased()
        }
        guard extensions.contains("apk"),
            extensions.contains("apex"),
            !extensions.contains("capex")
        else {
            throw failure(
                "signed target-files must contain APKs and uncompressed "
                    + "APEXes and must not contain CAPEXes")
        }
        try await checked(
            .named("unzip"),
            [
                "-q", archive.string, "*.apk", "*.apex",
                "-d", validation.string,
            ],
            in: archive.removingLastComponent(),
            environment: environment)

        let packages = try context.files.listRecursively(validation)
            .filter {
                guard $0.metadata.type == .regular else { return false }
                switch URL(fileURLWithPath: $0.path.string).pathExtension.lowercased() {
                case "apk", "apex": return true
                default: return false
                }
            }
            .map(\.path)
            .sorted { $0.string < $1.string }
        guard packages.contains(where: { fileExtension($0) == "apk" }),
            packages.contains(where: { fileExtension($0) == "apex" })
        else {
            throw failure(
                "signed target-files do not contain APK and APEX packages")
        }
        for (index, package) in packages.enumerated() {
            try await requirePackageCertificate(
                package,
                expectedDigest: expectedCertificateDigest,
                apksigner: apksigner,
                environment: environment)
            if fileExtension(package) == "apex" {
                try await requireAPEXPayloadSignature(
                    package,
                    validationRoot: validation,
                    index: index,
                    releasePEM: releasePEM,
                    avbTool: avbTool,
                    environment: environment)
            }
        }
    }

    private func requirePackageCertificate(
        _ package: FilePath,
        expectedDigest: String,
        apksigner: FilePath,
        environment: [String: String]
    ) async throws {
        let result = try await command(
            .path(apksigner),
            [
                "verify", "--print-certs", "--min-sdk-version",
                String(build.expectedPlatformSDK), package.string,
            ],
            in: package.removingLastComponent(),
            environment: environment)
        let digests = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let marker = "certificate SHA-256 digest:"
                guard let range = line.range(of: marker) else { return nil }
                return line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        guard result.status == 0, digests == [expectedDigest] else {
            throw failure(
                "package does not carry exactly the Nucleus release "
                    + "certificate: \(package)")
        }
    }

    private func requireAPEXPayloadSignature(
        _ apex: FilePath,
        validationRoot: FilePath,
        index: Int,
        releasePEM: FilePath,
        avbTool: FilePath,
        environment: [String: String]
    ) async throws {
        let payload = validationRoot.appending(".apex-payload-\(index)")
        try context.files.createDirectory(payload)
        try await checked(
            .named("unzip"),
            [
                "-q", apex.string, "apex_payload.img",
                "-d", payload.string,
            ],
            in: payload,
            environment: environment)
        try await checked(
            .path(avbTool),
            [
                "verify_image", "--image",
                payload.appending("apex_payload.img").string,
                "--key", releasePEM.string,
            ],
            in: payload,
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
        guard result.status == 0 else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw failure(
                "\(arguments.first ?? "command") failed"
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
        guard result.status == 0 else {
            throw failure("\(arguments.first ?? "command") failed")
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
        try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: .captured(limit: 32 * 1_024 * 1_024)))
    }

    private func requireExecutable(_ path: FilePath) throws {
        guard let metadata = try context.files.metadata(for: path),
            metadata.type == .regular,
            metadata.ownerExecutable
        else {
            throw failure("AOSP verification executable is missing: \(path)")
        }
    }

    private func productEnvironment(hostTools: FilePath) -> [String: String] {
        var environment = build.environment
        environment["TARGET_PRODUCT"] = build.product
        environment["TARGET_BUILD_VARIANT"] = build.variant
        environment["TARGET_RELEASE"] = build.release
        environment["OUT_DIR"] = build.buildRoot.appending("out").string
        environment["DIST_DIR"] = build.buildRoot.appending("dist").string
        environment["BUILD_NUMBER"] = build.buildNumber
        environment["BUILD_DATETIME"] = String(build.buildTimestamp)
        environment["BUILD_USERNAME"] = "nucleus"
        environment["BUILD_HOSTNAME"] = "collider"
        environment["TZ"] = "UTC"
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"
        environment["PATH"] =
            hostTools.string + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    private func fileExtension(_ path: FilePath) -> String {
        URL(fileURLWithPath: path.string).pathExtension.lowercased()
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
    var references: Set<String> = []
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
        references.formUnion(delegate.references)
    }
    let entries = Set(archiveEntries)
    let roots = ["SYSTEM", "PRODUCT", "SYSTEM_EXT", "VENDOR"]
    let missing = references.filter { reference in
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized.hasPrefix("/") {
            let path = normalized.dropFirst()
            let components = path.split(separator: "/", maxSplits: 1)
            guard components.count == 2 else { return true }
            let partition = components[0].uppercased()
            return !entries.contains("\(partition)/\(components[1])")
        }
        return !roots.contains { entries.contains("\($0)/fonts/\(normalized)") }
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

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        if elementName == "font" { fontText = "" }
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
        guard elementName == "font", let fontText else { return }
        references.insert(fontText)
        self.fontText = nil
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
