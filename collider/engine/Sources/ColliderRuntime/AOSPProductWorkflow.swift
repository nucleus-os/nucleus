import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareAOSPSigningIdentity(
        _ preparation: AOSPSigningIdentityPreparation,
        stage: TaskID
    ) async throws {
        if FileManager.default.fileExists(
            atPath: preparation.destination.string)
        {
            try await validateAOSPSigningIdentity(
                preparation,
                stage: stage)
            return
        }

        let parent = preparation.destination.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let candidate = parent.appending(
            ".\(preparation.destination.lastComponent?.string ?? "signing")"
                + ".candidate-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: candidate.string)
        }
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)

        var certificates: [AOSPSigningIdentity.Certificate] = []
        for alias in aospSigningAliases {
            let base = candidate.appending(alias)
            let privateKey = FilePath(base.string + ".pem")
            let certificate = FilePath(base.string + ".x509.pem")
            let pkcs8 = FilePath(base.string + ".pk8")
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "genpkey",
                    "-algorithm", "RSA",
                    "-pkeyopt", "rsa_keygen_bits:4096",
                    "-out", privateKey.string,
                ],
                in: candidate,
                environment: preparation.environment,
                stage: stage)
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "req",
                    "-new",
                    "-x509",
                    "-sha256",
                    "-key", privateKey.string,
                    "-out", certificate.string,
                    "-days", "3650",
                    "-subj", preparation.subject
                        + "/CN=Nucleus Android \(alias)",
                ],
                in: candidate,
                environment: preparation.environment,
                stage: stage)
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "pkcs8",
                    "-in", privateKey.string,
                    "-topk8",
                    "-outform", "DER",
                    "-out", pkcs8.string,
                    "-nocrypt",
                ],
                in: candidate,
                environment: preparation.environment,
                stage: stage)
            for path in [privateKey, pkcs8] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path.string)
            }
            certificates.append(AOSPSigningIdentity.Certificate(
                alias: alias,
                x509SHA256: try ArtifactHasher.digest(
                    file: certificate).sha256Hex))
        }

        try DurableFile.writeJSON(
            AOSPSigningIdentity(
                schemaVersion: 1,
                purpose: "local-development",
                subject: preparation.subject,
                certificates: certificates),
            to: candidate.appending("signing-identity.json"))
        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: preparation.destination.string)
        try DurableFile.synchronizeDirectory(parent)
        try await validateAOSPSigningIdentity(
            preparation,
            stage: stage)
    }

    func buildAOSPProduct(
        _ build: AOSPProductBuild,
        stage: TaskID
    ) async throws {
        guard build.buildJobs > 0,
              build.minimumFreeBytes > 0,
              build.expectedPlatformSDK > 0,
              build.expectedVendorAPILevel > 0
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP product build limits and API levels must be positive")
        }
        let available = try aospProductAvailableBytes(
            at: build.buildRoot.removingLastComponent())
        guard available >= build.minimumFreeBytes else {
            throw RuntimeFailure.invalidOutput(
                "\(build.buildRoot.removingLastComponent()) has "
                    + "\(available / aospProductGiB) GiB free; "
                    + "\(build.minimumFreeBytes / aospProductGiB) GiB "
                    + "is required for the Android image build")
        }

        let sourceProvenance = try JSONDecoder().decode(
            AOSPBuildSourceProvenance.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: build.sourceProvenance.string)))
        guard sourceProvenance.status == "materialized" else {
            throw RuntimeFailure.invalidOutput(
                "AOSP source provenance is not materialized")
        }
        try await validateAOSPSigningIdentity(
            AOSPSigningIdentityPreparation(
                destination: build.signingIdentity,
                subject: try aospSigningIdentity(
                    at: build.signingIdentity).subject,
                environment: build.environment),
            stage: stage)
        let productDigest = try ArtifactHasher.digest(
            tree: build.productSource)
        try stageAOSPProduct(build, digest: productDigest)

        let output = build.buildRoot.appending("out")
        let distribution = build.buildRoot.appending("dist")
        let unsigned = build.buildRoot.appending("unsigned")
        let signed = build.buildRoot.appending("signed")
        for directory in [
            build.buildRoot,
            output,
            distribution,
            unsigned,
            signed,
        ] {
            try FileManager.default.createDirectory(
                atPath: directory.string,
                withIntermediateDirectories: true)
        }

        var environment = build.environment
        environment["TARGET_PRODUCT"] = build.product
        environment["TARGET_BUILD_VARIANT"] = build.variant
        environment["TARGET_RELEASE"] = build.release
        // Siso resolves --config_repo_dir relative to the AOSP execution root.
        // An absolute OUT_DIR makes its generated @config repository
        // unreachable even though Soong created it successfully.
        environment["OUT_DIR"] = aospProductRelativePath(
            output,
            from: build.source)
        environment["DIST_DIR"] = aospProductRelativePath(
            distribution,
            from: build.source)
        environment["BUILD_NUMBER"] = build.buildNumber
        environment["BUILD_DATETIME"] = String(build.buildTimestamp)
        environment["BUILD_USERNAME"] = "nucleus"
        environment["BUILD_HOSTNAME"] = "collider"
        environment["TZ"] = "UTC"
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"

        try await checkedAOSPProductCommand(
            .path(build.source.appending("build/soong/soong_ui.bash")),
            [
                "--make-mode",
                "-j\(build.buildJobs)",
                "target-files-package",
                "otatools",
            ],
            in: build.source,
            environment: environment,
            output: .logged,
            stage: stage)

        let builtTargetFiles = try locateAOSPTargetFiles(
            product: build.product,
            under: output)
        let unsignedTargetFiles = unsigned.appending(
            "\(build.product)-target_files.zip")
        try DurableFile.copy(
            from: builtTargetFiles,
            to: unsignedTargetFiles)

        let hostTools = output.appending("host/linux-x86/bin")
        let signingTool = hostTools.appending("sign_target_files_apks")
        let imageTool = hostTools.appending("img_from_target_files")
        for tool in [signingTool, imageTool] where
            !FileManager.default.isExecutableFile(atPath: tool.string)
        {
            throw RuntimeFailure.invalidOutput(
                "AOSP host signing tool is missing: \(tool)")
        }
        environment["PATH"] =
            hostTools.string + ":" + (environment["PATH"] ?? "/usr/bin:/bin")

        let releaseKey = build.signingIdentity.appending("releasekey")
        let releasePEM = FilePath(releaseKey.string + ".pem")
        let signedTargetCandidate = signed.appending(
            ".\(build.product)-target_files.candidate-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(
                atPath: signedTargetCandidate.string)
        }
        var signingArguments = [
            "-o",
            "-d", build.signingIdentity.string,
            "--override_apk_keys", releaseKey.string,
            "--override_apex_keys", releaseKey.string,
            "--avb_vbmeta_key", releasePEM.string,
            "--avb_vbmeta_algorithm", "SHA256_RSA4096",
            "--avb_vbmeta_system_key", releasePEM.string,
            "--avb_vbmeta_system_algorithm", "SHA256_RSA4096",
            "--avb_system_key", releasePEM.string,
            "--avb_system_algorithm", "SHA256_RSA4096",
            "--avb_vendor_key", releasePEM.string,
            "--avb_vendor_algorithm", "SHA256_RSA4096",
        ]
        for partition in ["product", "system_ext"] {
            signingArguments += [
                "--avb_extra_custom_image_key",
                "\(partition)=\(releasePEM.string)",
                "--avb_extra_custom_image_algorithm",
                "\(partition)=SHA256_RSA4096",
            ]
        }
        if build.variant != "user" {
            signingArguments.append("--allow_gsi_debug_sepolicy")
        }
        signingArguments += [
            unsignedTargetFiles.string,
            signedTargetCandidate.string,
        ]
        try await checkedAOSPProductCommand(
            .path(signingTool),
            signingArguments,
            in: build.source,
            environment: environment,
            output: .logged,
            stage: stage)

        let signedTargetFiles = signed.appending(
            "\(build.product)-target_files.zip")
        try replaceAOSPProductFile(
            signedTargetCandidate,
            with: signedTargetFiles)

        let imageArchiveCandidate = signed.appending(
            ".\(build.product)-images.candidate-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(
                atPath: imageArchiveCandidate.string)
        }
        try await checkedAOSPProductCommand(
            .path(imageTool),
            [signedTargetFiles.string, imageArchiveCandidate.string],
            in: build.source,
            environment: environment,
            output: .logged,
            stage: stage)
        let imageArchive = signed.appending(
            "\(build.product)-images.zip")
        try replaceAOSPProductFile(
            imageArchiveCandidate,
            with: imageArchive)

        let imageCandidate = build.buildRoot.appending(
            ".images.candidate-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(
                atPath: imageCandidate.string)
        }
        try FileManager.default.createDirectory(
            atPath: imageCandidate.string,
            withIntermediateDirectories: false)
        try await checkedAOSPProductCommand(
            .named("unzip"),
            ["-q", imageArchive.string, "-d", imageCandidate.string],
            in: build.buildRoot,
            environment: environment,
            stage: stage)

        let requiredImages = [
            "system.img",
            "system_ext.img",
            "product.img",
            "vendor.img",
            "vbmeta.img",
            "vbmeta_system.img",
        ]
        let avbTool = hostTools.appending("avbtool")
        guard FileManager.default.isExecutableFile(
            atPath: avbTool.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP avbtool is missing: \(avbTool)")
        }
        var images: [AOSPImageProvenance.Image] = []
        for name in requiredImages {
            let image = imageCandidate.appending(name)
            guard aospProductIsRegularFile(image) else {
                throw RuntimeFailure.invalidOutput(
                    "signed Android image is missing: \(name)")
            }
            try await checkedAOSPProductCommand(
                .path(avbTool),
                [
                    "verify_image",
                    "--image", image.string,
                    "--key", releasePEM.string,
                ],
                in: imageCandidate,
                environment: environment,
                stage: stage)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: image.string)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            images.append(AOSPImageProvenance.Image(
                name: name,
                size: size,
                sha256: try ArtifactHasher.digest(file: image).sha256Hex))
        }

        let buildProperties = try await capturedAOSPArchiveEntry(
            archive: signedTargetFiles,
            candidates: [
                "SYSTEM/build.prop",
                "SYSTEM/system/build.prop",
            ],
            environment: environment,
            stage: stage)
        let properties = aospProperties(buildProperties)
        guard properties["ro.build.version.sdk"]
            == String(build.expectedPlatformSDK)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product SDK is "
                    + "\(properties["ro.build.version.sdk"] ?? "missing"); "
                    + "expected \(build.expectedPlatformSDK)")
        }
        guard properties["ro.vendor.api_level"]
            == String(build.expectedVendorAPILevel)
            || properties["ro.board.api_level"]
                == String(build.expectedVendorAPILevel)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product does not declare vendor API level "
                    + "\(build.expectedVendorAPILevel)")
        }
        let fingerprint = properties["ro.build.fingerprint"] ?? ""
        guard fingerprint.contains("/\(build.product):"),
              fingerprint.hasSuffix("release-keys")
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product fingerprint is invalid: \(fingerprint)")
        }
        try await requireAOSPReleaseSigningMetadata(
            archive: signedTargetFiles,
            signingIdentity: build.signingIdentity,
            environment: environment,
            stage: stage)

        let finalImages = build.buildRoot.appending("images")
        if FileManager.default.fileExists(atPath: finalImages.string) {
            try FileManager.default.removeItem(atPath: finalImages.string)
        }
        try FileManager.default.moveItem(
            atPath: imageCandidate.string,
            toPath: finalImages.string)

        let signing = try aospSigningIdentity(
            at: build.signingIdentity)
        try DurableFile.writeJSON(
            AOSPImageProvenance(
                schemaVersion: 1,
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
                sourceManifestSHA256:
                    sourceProvenance.resolvedManifestSHA256,
                productTreeSHA256: productDigest.sha256Hex,
                signingPurpose: signing.purpose,
                signingCertificates: signing.certificates,
                targetFilesSHA256: try ArtifactHasher.digest(
                    file: signedTargetFiles).sha256Hex,
                imageArchiveSHA256: try ArtifactHasher.digest(
                    file: imageArchive).sha256Hex,
                images: images.sorted { $0.name < $1.name }),
            to: signed.appending("image-provenance.json"))
    }

    private func validateAOSPSigningIdentity(
        _ preparation: AOSPSigningIdentityPreparation,
        stage: TaskID
    ) async throws {
        let identity = try aospSigningIdentity(
            at: preparation.destination)
        guard identity.schemaVersion == 1,
              identity.purpose == "local-development",
              identity.subject == preparation.subject,
              identity.certificates.map(\.alias) == aospSigningAliases
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP signing identity metadata is invalid")
        }
        let validationDirectory = preparation.destination.appending(
            ".validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: validationDirectory.string,
            withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(
                atPath: validationDirectory.string)
        }
        for item in identity.certificates {
            let base = preparation.destination.appending(item.alias)
            let privateKey = FilePath(base.string + ".pem")
            let certificate = FilePath(base.string + ".x509.pem")
            let pkcs8 = FilePath(base.string + ".pk8")
            for path in [privateKey, certificate, pkcs8] where
                !aospProductIsRegularFile(path)
            {
                throw RuntimeFailure.invalidOutput(
                    "AOSP signing key material is missing: \(path)")
            }
            guard try ArtifactHasher.digest(file: certificate).sha256Hex
                == item.x509SHA256
            else {
                throw RuntimeFailure.invalidOutput(
                    "AOSP signing certificate digest changed: \(certificate)")
            }
            let certificatePEM = validationDirectory.appending(
                "\(item.alias)-certificate-public.pem")
            let certificateDER = validationDirectory.appending(
                "\(item.alias)-certificate-public.der")
            let privateDER = validationDirectory.appending(
                "\(item.alias)-private-public.der")
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "x509",
                    "-in", certificate.string,
                    "-pubkey",
                    "-noout",
                    "-out", certificatePEM.string,
                ],
                in: preparation.destination,
                environment: preparation.environment,
                stage: stage)
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "pkey",
                    "-pubin",
                    "-in", certificatePEM.string,
                    "-outform", "DER",
                    "-out", certificateDER.string,
                ],
                in: preparation.destination,
                environment: preparation.environment,
                stage: stage)
            try await checkedAOSPProductCommand(
                .named("openssl"),
                [
                    "pkey",
                    "-in", privateKey.string,
                    "-pubout",
                    "-outform", "DER",
                    "-out", privateDER.string,
                ],
                in: preparation.destination,
                environment: preparation.environment,
                stage: stage)
            guard try ArtifactHasher.digest(file: certificateDER)
                == ArtifactHasher.digest(file: privateDER)
            else {
                throw RuntimeFailure.invalidOutput(
                    "AOSP signing certificate does not match its private key: "
                        + item.alias)
            }
        }
    }

    private func stageAOSPProduct(
        _ build: AOSPProductBuild,
        digest: ArtifactDigest
    ) throws {
        let destination = build.source.appending(
            "device/nucleus/nucleus_x86_64")
        let parent = destination.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(
            atPath: destination.appending(".git").string)
        {
            throw RuntimeFailure.invalidOutput(
                "refusing to replace a Git checkout at \(destination)")
        }
        let candidate = parent.appending(
            ".nucleus_x86_64.candidate-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: candidate.string)
        }
        try FileManager.default.copyItem(
            atPath: build.productSource.string,
            toPath: candidate.string)
        try DurableFile.writeJSON(
            AOSPProductStage(
                schemaVersion: 1,
                source: build.productSource.string,
                sha256: digest.sha256Hex),
            to: candidate.appending(".nucleus-product-stage.json"))
        if FileManager.default.fileExists(atPath: destination.string) {
            try FileManager.default.removeItem(atPath: destination.string)
        }
        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: destination.string)
    }

    private func requireAOSPReleaseSigningMetadata(
        archive: FilePath,
        signingIdentity: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let metadata = try await capturedAOSPArchiveEntry(
            archive: archive,
            candidates: [
                "META/misc_info.txt",
                "META/apkcerts.txt",
                "META/apexkeys.txt",
            ],
            environment: environment,
            stage: stage)
        let forbidden = [
            "build/make/target/product/security/testkey",
            "build/make/target/product/security/platform",
            "build/make/target/product/security/shared",
            "build/make/target/product/security/media",
            "external/avb/test/data/",
        ]
        guard forbidden.allSatisfy({ !metadata.contains($0) }),
              metadata.contains(signingIdentity.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed target-files retain development signing identities")
        }
    }

    private func capturedAOSPArchiveEntry(
        archive: FilePath,
        candidates: [String],
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        var output = ""
        for candidate in candidates {
            let result = try await execute(
                CommandSpec(
                    executable: .named("unzip"),
                    arguments: ["-p", archive.string, candidate],
                    workingDirectory: archive.removingLastComponent(),
                    environment: environment,
                    output: .captured(limit: 32 * 1_024 * 1_024)),
                stage: stage)
            if result.status == 0, !result.standardOutput.isEmpty {
                output += result.standardOutput
                output += "\n"
            }
        }
        guard !output.isEmpty else {
            throw RuntimeFailure.invalidOutput(
                "required metadata is missing from \(archive)")
        }
        return output
    }

    private func checkedAOSPProductCommand(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        output: CommandSpec.Output = .captured(
            limit: 32 * 1_024 * 1_024),
        stage: TaskID
    ) async throws {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: output),
            stage: stage)
        guard result.status == 0 else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw RuntimeFailure.invalidOutput(
                "\(arguments.first ?? "command") failed"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    private func capturedAOSPProductCommand(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.invalidOutput(
                "\(arguments.first ?? "command") failed")
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}

private let aospSigningAliases = [
    "releasekey",
    "platform",
    "shared",
    "media",
    "networkstack",
]

private let aospProductGiB: UInt64 = 1_024 * 1_024 * 1_024

private func aospProductRelativePath(
    _ target: FilePath,
    from directory: FilePath
) -> String {
    let targetComponents = URL(
        fileURLWithPath: target.string).standardizedFileURL.pathComponents
    let directoryComponents = URL(
        fileURLWithPath: directory.string).standardizedFileURL.pathComponents
    var common = 0
    while common < targetComponents.count,
          common < directoryComponents.count,
          targetComponents[common] == directoryComponents[common]
    {
        common += 1
    }
    let parents = Array(
        repeating: "..",
        count: directoryComponents.count - common)
    let descendants = Array(targetComponents.dropFirst(common))
    let components = parents + descendants
    return components.isEmpty ? "." : components.joined(separator: "/")
}

private func aospProductAvailableBytes(at path: FilePath) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfFileSystem(
        forPath: path.string)
    guard let available = attributes[.systemFreeSize] as? NSNumber else {
        throw RuntimeFailure.invalidOutput(
            "could not determine free space for \(path)")
    }
    return available.uint64Value
}

private func aospProductIsRegularFile(_ path: FilePath) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &isDirectory) && !isDirectory.boolValue
}

private func locateAOSPTargetFiles(
    product: String,
    under root: FilePath
) throws -> FilePath {
    let rootURL = URL(fileURLWithPath: root.string, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "could not inspect AOSP build output at \(root)")
    }
    let expected = "\(product)-target_files.zip"
    let matches = enumerator.compactMap { item -> FilePath? in
        guard let url = item as? URL,
              url.lastPathComponent == expected,
              (try? url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            return nil
        }
        return FilePath(url.path)
    }.sorted { $0.string < $1.string }
    guard matches.count == 1 else {
        throw RuntimeFailure.invalidOutput(
            "expected one \(expected) under \(root); found "
                + (matches.isEmpty
                    ? "none"
                    : matches.map(\.string).joined(separator: ", ")))
    }
    return matches[0]
}

private func replaceAOSPProductFile(
    _ candidate: FilePath,
    with destination: FilePath
) throws {
    guard aospProductIsRegularFile(candidate) else {
        throw RuntimeFailure.invalidOutput(
            "AOSP build did not produce \(candidate)")
    }
    if FileManager.default.fileExists(atPath: destination.string) {
        try FileManager.default.removeItem(atPath: destination.string)
    }
    try FileManager.default.moveItem(
        atPath: candidate.string,
        toPath: destination.string)
}

private func aospSigningIdentity(
    at root: FilePath
) throws -> AOSPSigningIdentity {
    try JSONDecoder().decode(
        AOSPSigningIdentity.self,
        from: Data(contentsOf: URL(fileURLWithPath: root.appending(
            "signing-identity.json").string)))
}

private func aospProperties(_ contents: String) -> [String: String] {
    Dictionary(
        uniqueKeysWithValues: contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                guard !line.hasPrefix("#"),
                      let equals = line.firstIndex(of: "=")
                else {
                    return nil
                }
                return (
                    String(line[..<equals]),
                    String(line[line.index(after: equals)...]))
            })
}

private extension ArtifactDigest {
    var sha256Hex: String {
        let prefix = "sha256:"
        precondition(description.hasPrefix(prefix))
        return String(description.dropFirst(prefix.count))
    }
}

private struct AOSPSigningIdentity: Codable {
    struct Certificate: Codable {
        let alias: String
        let x509SHA256: String
    }

    let schemaVersion: UInt32
    let purpose: String
    let subject: String
    let certificates: [Certificate]
}

private struct AOSPBuildSourceProvenance: Decodable {
    let status: String
    let manifestCommit: String
    let resolvedManifestSHA256: String
}

private struct AOSPProductStage: Encodable {
    let schemaVersion: UInt32
    let source: String
    let sha256: String
}

private struct AOSPImageProvenance: Encodable {
    struct Image: Encodable {
        let name: String
        let size: UInt64
        let sha256: String
    }

    let schemaVersion: UInt32
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
    let sourceManifestSHA256: String
    let productTreeSHA256: String
    let signingPurpose: String
    let signingCertificates: [AOSPSigningIdentity.Certificate]
    let targetFilesSHA256: String
    let imageArchiveSHA256: String
    let images: [Image]
}
