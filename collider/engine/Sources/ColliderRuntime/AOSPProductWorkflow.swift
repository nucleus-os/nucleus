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
            try DurableFile.writeJSON(
                try aospSigningIdentity(at: preparation.destination),
                to: preparation.destination.appending(
                    "signing-identity.json"))
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
              build.expectedPlatformSDK > 0,
              build.expectedVendorAPILevel > 0
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP product build concurrency and API levels must be positive")
        }
        let sourceProvenance = try JSONDecoder().decode(
            AOSPBuildSourceProvenance.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: build.sourceProvenance.string)))
        guard sourceProvenance.status == "materialized",
              !sourceProvenance.forwardPatches.isEmpty
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP source provenance is not a patched materialization")
        }
        let cleanCheck = try await execute(
            CommandSpec(
                executable: .named("python3"),
                arguments: [
                    build.repoLauncher.string,
                    "forall",
                    "-c",
                    "git update-index -q --refresh"
                        + " && git diff-files --quiet"
                        + " && git diff-index --cached --quiet HEAD --"
                        + " && test -z \"$(git ls-files --others"
                        + " --exclude-standard)\"",
                ],
                workingDirectory: build.source,
                environment: build.environment,
                output: .captured(limit: 32 * 1_024 * 1_024)),
            stage: stage)
        guard cleanCheck.status == 0 else {
            let detail = cleanCheck.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw RuntimeFailure.invalidOutput(
                "AOSP Repo project worktrees are not clean"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
        let resolvedManifest =
            try await capturedAOSPProductCommand(
                .named("python3"),
                [
                    build.repoLauncher.string,
                    "manifest",
                    "--revision-as-HEAD",
                ],
                in: build.source,
                environment: build.environment,
                stage: stage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let currentSourceDigest = ArtifactHasher.digest(
            bytes: Data(resolvedManifest.utf8)).sha256Hex
        guard currentSourceDigest
                == sourceProvenance.resolvedManifestSHA256
        else {
            throw RuntimeFailure.invalidOutput(
                "current AOSP project revisions do not match signed-build "
                    + "source provenance")
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
        let outputLink = build.source.appending("out/nucleus")
        let distributionLink = build.source.appending(
            "out/nucleus-dist")
        try ensureAOSPBuildLink(outputLink, pointsTo: output)
        try ensureAOSPBuildLink(distributionLink, pointsTo: distribution)

        var environment = build.environment
        environment["TARGET_PRODUCT"] = build.product
        environment["TARGET_BUILD_VARIANT"] = build.variant
        environment["TARGET_RELEASE"] = build.release
        // Siso requires its generated config repository to be relative to the
        // AOSP execution root, and Soong rejects lexical paths that escape that
        // root. Source-local links satisfy both contracts while keeping every
        // generated byte under android-runtime/.aosp-build.
        environment["OUT_DIR"] = aospProductRelativePath(
            outputLink,
            from: build.source)
        environment["DIST_DIR"] = aospProductRelativePath(
            distributionLink,
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
            "--override_apex_keys", releasePEM.string,
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

        let imageArchiveCandidate = signed.appending(
            ".\(build.product)-images.candidate-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(
                atPath: imageArchiveCandidate.string)
        }
        try await checkedAOSPProductCommand(
            .path(imageTool),
            [signedTargetCandidate.string, imageArchiveCandidate.string],
            in: build.source,
            environment: environment,
            output: .logged,
            stage: stage)

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
            ["-q", imageArchiveCandidate.string, "-d", imageCandidate.string],
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
        let sparseImageTool = hostTools.appending("simg2img")
        guard FileManager.default.isExecutableFile(
            atPath: avbTool.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP avbtool is missing: \(avbTool)")
        }
        var images: [AOSPImageProvenance.Image] = []
        for name in requiredImages {
            let image = imageCandidate.appending(name)
            guard image.isRegularFile else {
                throw RuntimeFailure.invalidOutput(
                    "signed Android image is missing: \(name)")
            }
            if try aospImageIsSparse(image) {
                guard FileManager.default.isExecutableFile(
                    atPath: sparseImageTool.string)
                else {
                    throw RuntimeFailure.invalidOutput(
                        "AOSP simg2img is missing: \(sparseImageTool)")
                }
                let rawImage = FilePath(image.string + ".raw")
                defer {
                    try? FileManager.default.removeItem(
                        atPath: rawImage.string)
                }
                try await checkedAOSPProductCommand(
                    .path(sparseImageTool),
                    [image.string, rawImage.string],
                    in: imageCandidate,
                    environment: environment,
                    stage: stage)
                try FileManager.default.removeItem(atPath: image.string)
                try FileManager.default.moveItem(
                    atPath: rawImage.string,
                    toPath: image.string)
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: image.string)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            images.append(AOSPImageProvenance.Image(
                name: name,
                size: size,
                storageFormat: "raw",
                sha256: try ArtifactHasher.digest(file: image).sha256Hex))
        }
        try await checkedAOSPProductCommand(
            .path(avbTool),
            [
                "verify_image",
                "--image", imageCandidate.appending("vbmeta.img").string,
                "--key", releasePEM.string,
                "--follow_chain_partitions",
            ],
            in: imageCandidate,
            environment: environment,
            stage: stage)

        let systemBuildProperties = try await capturedAOSPArchiveEntry(
            archive: signedTargetCandidate,
            candidates: ["SYSTEM/build.prop"],
            environment: environment,
            stage: stage)
        let vendorBuildProperties = try await capturedAOSPArchiveEntry(
            archive: signedTargetCandidate,
            candidates: ["VENDOR/build.prop"],
            environment: environment,
            stage: stage)
        let systemProperties = aospProperties(systemBuildProperties)
        let vendorProperties = aospProperties(vendorBuildProperties)
        guard systemProperties["ro.build.version.sdk"]
            == String(build.expectedPlatformSDK)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product SDK is "
                    + "\(systemProperties["ro.build.version.sdk"] ?? "missing"); "
                    + "expected \(build.expectedPlatformSDK)")
        }
        guard vendorProperties["ro.vendor.api_level"]
            == String(build.expectedVendorAPILevel)
            || vendorProperties["ro.board.api_level"]
                == String(build.expectedVendorAPILevel)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product does not declare vendor API level "
                    + "\(build.expectedVendorAPILevel)")
        }
        let fingerprint =
            systemProperties["ro.system.build.fingerprint"] ?? ""
        guard fingerprint.contains("/\(build.product):"),
              fingerprint.hasSuffix("release-keys")
        else {
            throw RuntimeFailure.invalidOutput(
                "signed product fingerprint is invalid: \(fingerprint)")
        }
        try await requireAOSPReleaseSigning(
            archive: signedTargetCandidate,
            signingIdentity: build.signingIdentity,
            hostTools: hostTools,
            platformSDK: build.expectedPlatformSDK,
            environment: environment,
            stage: stage)

        let targetFilesDigest = try ArtifactHasher.digest(
            file: signedTargetCandidate).sha256Hex
        let imageArchiveDigest = try ArtifactHasher.digest(
            file: imageArchiveCandidate).sha256Hex
        let signedTargetFiles = signed.appending(
            "\(build.product)-target_files.zip")
        let imageArchive = signed.appending(
            "\(build.product)-images.zip")
        let finalImages = build.buildRoot.appending("images")
        try replaceAOSPProductFile(
            signedTargetCandidate,
            with: signedTargetFiles)
        try replaceAOSPProductFile(
            imageArchiveCandidate,
            with: imageArchive)
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
                sourceBaseManifestSHA256:
                    sourceProvenance.baseResolvedManifestSHA256,
                sourceManifestSHA256:
                    sourceProvenance.resolvedManifestSHA256,
                sourceForwardPatches:
                    sourceProvenance.forwardPatches,
                productTreeSHA256: productDigest.sha256Hex,
                signingPurpose: signing.purpose,
                signingCertificates: signing.certificates,
                targetFilesSHA256: targetFilesDigest,
                imageArchiveSHA256: imageArchiveDigest,
                images: images.sorted { $0.name < $1.name }),
            to: signed.appending("image-provenance.json"))
    }

    private func validateAOSPSigningIdentity(
        _ preparation: AOSPSigningIdentityPreparation,
        stage: TaskID
    ) async throws {
        let identity = try aospSigningIdentity(
            at: preparation.destination)
        guard identity.purpose == "local-development",
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
                !path.isRegularFile
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
        let stageMetadata = destination.appending(
            ".nucleus-product-stage.json")
        if let staged = try? JSONDecoder().decode(
            AOSPProductStage.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: stageMetadata.string))),
            staged.source == build.productSource.string,
            staged.sha256 == digest.sha256Hex,
            try ArtifactHasher.digest(
                tree: destination,
                excluding: [".nucleus-product-stage.json"]) == digest
        {
            return
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

    private func requireAOSPReleaseSigning(
        archive: FilePath,
        signingIdentity: FilePath,
        hostTools: FilePath,
        platformSDK: UInt32,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let releaseKey = signingIdentity.appending("releasekey")
        let releasePEM = FilePath(releaseKey.string + ".pem")
        let releaseCertificate = FilePath(
            releaseKey.string + ".x509.pem")
        let metadata = try await capturedAOSPArchiveEntry(
            archive: archive,
            candidates: ["META/misc_info.txt"],
            environment: environment,
            stage: stage)
        let requiredMetadata = [
            "avb_vbmeta_key_path=\(releasePEM.string)",
            "avb_vbmeta_system_key_path=\(releasePEM.string)",
            "default_system_dev_certificate=\(releaseKey.string)",
        ]
        guard requiredMetadata.allSatisfy(metadata.contains)
        else {
            throw RuntimeFailure.invalidOutput(
                "signed target-files do not declare the Nucleus release keys")
        }

        let apksigner = hostTools.appending("apksigner")
        let avbTool = hostTools.appending("avbtool")
        for tool in [apksigner, avbTool] where
            !FileManager.default.isExecutableFile(atPath: tool.string)
        {
            throw RuntimeFailure.invalidOutput(
                "AOSP package verification tool is missing: \(tool)")
        }
        let certificateOutput = try await capturedAOSPProductCommand(
            .named("openssl"),
            [
                "x509",
                "-in", releaseCertificate.string,
                "-noout",
                "-fingerprint",
                "-sha256",
            ],
            in: signingIdentity,
            environment: environment,
            stage: stage)
        guard let separator = certificateOutput.firstIndex(of: "=") else {
            throw RuntimeFailure.invalidOutput(
                "could not read the Nucleus release certificate fingerprint")
        }
        let expectedCertificateDigest = certificateOutput[
            certificateOutput.index(after: separator)...
        ]
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        let validationDirectory = archive.removingLastComponent().appending(
            ".package-validation-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(
                atPath: validationDirectory.string)
        }
        try FileManager.default.createDirectory(
            atPath: validationDirectory.string,
            withIntermediateDirectories: false)
        let archiveEntries = try await capturedAOSPProductCommand(
            .named("unzip"),
            ["-Z1", archive.string],
            in: archive.removingLastComponent(),
            environment: environment,
            stage: stage)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let archiveExtensions = archiveEntries.map {
            URL(fileURLWithPath: $0).pathExtension.lowercased()
        }
        guard archiveExtensions.contains("apk"),
            archiveExtensions.contains("apex"),
            !archiveExtensions.contains("capex")
        else {
            throw RuntimeFailure.invalidOutput(
                "signed target-files must contain APKs and uncompressed "
                    + "APEXes and must not contain CAPEXes")
        }
        try await checkedAOSPProductCommand(
            .named("unzip"),
            [
                "-q",
                archive.string,
                "*.apk",
                "*.apex",
                "-d", validationDirectory.string,
            ],
            in: archive.removingLastComponent(),
            environment: environment,
            stage: stage)

        let packages = try aospProductPackages(
            under: validationDirectory)
        guard packages.contains(where: {
            $0.extension?.lowercased() == "apk"
        }),
            packages.contains(where: {
                $0.extension?.lowercased() == "apex"
            })
        else {
            throw RuntimeFailure.invalidOutput(
                "signed target-files do not contain APK and APEX packages")
        }
        for (index, package) in packages.enumerated() {
            try await requireAOSPPackageCertificate(
                package,
                expectedDigest: expectedCertificateDigest,
                apksigner: apksigner,
                platformSDK: platformSDK,
                environment: environment,
                stage: stage)
            switch package.extension?.lowercased() {
            case "apex":
                try await requireAOSPAPEXPayloadSignature(
                    package,
                    validationRoot: validationDirectory,
                    index: index,
                    releasePEM: releasePEM,
                    avbTool: avbTool,
                    environment: environment,
                    stage: stage)
            default:
                break
            }
        }
    }

    private func requireAOSPPackageCertificate(
        _ package: FilePath,
        expectedDigest: String,
        apksigner: FilePath,
        platformSDK: UInt32,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let result = try await execute(
            CommandSpec(
                executable: .path(apksigner),
                arguments: [
                    "verify",
                    "--print-certs",
                    "--min-sdk-version", String(platformSDK),
                    package.string,
                ],
                workingDirectory: package.removingLastComponent(),
                environment: environment,
                output: .captured(limit: 32 * 1_024 * 1_024)),
            stage: stage)
        let digests = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let marker = "certificate SHA-256 digest:"
                guard let range = line.range(of: marker) else {
                    return nil
                }
                return line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        guard result.status == 0, digests == [expectedDigest] else {
            throw RuntimeFailure.invalidOutput(
                "package does not carry exactly the Nucleus release "
                    + "certificate: \(package)")
        }
    }

    private func requireAOSPAPEXPayloadSignature(
        _ apex: FilePath,
        validationRoot: FilePath,
        index: Int,
        releasePEM: FilePath,
        avbTool: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let payloadDirectory = validationRoot.appending(
            ".apex-payload-\(index)")
        try FileManager.default.createDirectory(
            atPath: payloadDirectory.string,
            withIntermediateDirectories: false)
        try await checkedAOSPProductCommand(
            .named("unzip"),
            [
                "-q",
                apex.string,
                "apex_payload.img",
                "-d", payloadDirectory.string,
            ],
            in: payloadDirectory,
            environment: environment,
            stage: stage)
        try await checkedAOSPProductCommand(
            .path(avbTool),
            [
                "verify_image",
                "--image",
                payloadDirectory.appending("apex_payload.img").string,
                "--key", releasePEM.string,
            ],
            in: payloadDirectory,
            environment: environment,
            stage: stage)
    }

    private func aospProductPackages(
        under directory: FilePath
    ) throws -> [FilePath] {
        let root = URL(
            fileURLWithPath: directory.string,
            isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false })
        else {
            throw RuntimeFailure.invalidOutput(
                "could not enumerate signed Android packages")
        }
        return try enumerator.compactMap { item -> FilePath? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            switch url.pathExtension.lowercased() {
            case "apk", "apex":
                return FilePath(url.path)
            default:
                return nil
            }
        }
        .sorted { $0.string < $1.string }
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
                output: .captured(limit: 32 * 1_024 * 1_024)),
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

private func ensureAOSPBuildLink(
    _ link: FilePath,
    pointsTo destination: FilePath
) throws {
    try FileManager.default.createDirectory(
        atPath: link.removingLastComponent().string,
        withIntermediateDirectories: true)
    let target = aospProductRelativePath(
        destination,
        from: link.removingLastComponent())
    if let existing = try? FileManager.default.destinationOfSymbolicLink(
        atPath: link.string)
    {
        guard existing == target else {
            throw RuntimeFailure.invalidOutput(
                "\(link) points to \(existing), expected \(target)")
        }
        return
    }
    guard !FileManager.default.fileExists(atPath: link.string) else {
        throw RuntimeFailure.invalidOutput(
            "\(link) must be absent or a symbolic link to \(target)")
    }
    let candidate = FilePath(
        link.string + ".candidate-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(atPath: candidate.string)
    }
    try FileManager.default.createSymbolicLink(
        atPath: candidate.string,
        withDestinationPath: target)
    try FileManager.default.moveItem(
        atPath: candidate.string,
        toPath: link.string)
    try DurableFile.synchronizeDirectory(link.removingLastComponent())
}

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


private func aospImageIsSparse(_ path: FilePath) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: URL(
        fileURLWithPath: path.string))
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: 4) ?? Data()
    guard prefix.count == 4 else {
        throw RuntimeFailure.invalidOutput(
            "Android image is too short: \(path)")
    }
    return prefix.elementsEqual([0x3a, 0xff, 0x26, 0xed])
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
    guard candidate.isRegularFile else {
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

    let purpose: String
    let subject: String
    let certificates: [Certificate]
}

private struct AOSPForwardPatch: Codable {
    let path: String
    let sha256: String
}

private struct AOSPForwardPatchStack: Codable {
    let repositoryPath: String
    let baseCommit: String
    let patchedCommit: String
    let patchedTree: String
    let patches: [AOSPForwardPatch]
}

private struct AOSPBuildSourceProvenance: Decodable {
    let status: String
    let manifestCommit: String
    let baseResolvedManifestSHA256: String
    let resolvedManifestSHA256: String
    let forwardPatches: [AOSPForwardPatchStack]
}

private struct AOSPProductStage: Codable {
    let source: String
    let sha256: String
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
    let sourceBaseManifestSHA256: String
    let sourceManifestSHA256: String
    let sourceForwardPatches: [AOSPForwardPatchStack]
    let productTreeSHA256: String
    let signingPurpose: String
    let signingCertificates: [AOSPSigningIdentity.Certificate]
    let targetFilesSHA256: String
    let imageArchiveSHA256: String
    let images: [Image]
}
