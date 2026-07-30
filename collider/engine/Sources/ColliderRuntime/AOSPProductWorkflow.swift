import ColliderCore
import Foundation
import FoundationXML
import SystemPackage

public func aospProductDefinitionDigest(
    productSource: FilePath,
    sourceOverlays: [AOSPProductSourceOverlay]
) throws -> ArtifactDigest {
    var framing = Data()
    framing.append(contentsOf: try ArtifactHasher.digest(
        tree: productSource).bytes)
    for overlay in sourceOverlays.sorted(by: {
        $0.relativeDestination < $1.relativeDestination
    }) {
        framing.append(contentsOf: overlay.relativeDestination.utf8)
        framing.append(0)
        framing.append(contentsOf: try ArtifactHasher.digest(
            tree: overlay.source).bytes)
    }
    return ArtifactHasher.digest(bytes: framing)
}

extension ColliderRuntime {
    func prepareAOSPBuildContainer(
        _ preparation: AOSPBuildContainerPreparation,
        stage: TaskID
    ) async throws {
        let containerFile = try String(
            contentsOfFile: preparation.containerFile.string,
            encoding: .utf8)
        guard containerFile.contains(
            "FROM docker.io/library/ubuntu:26.04@sha256:")
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP build Containerfile must pin its base image by digest")
        }
        let parent = preparation.imageID.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let candidate = parent.appending(
            ".image-id.candidate-\(UUID().uuidString)")
        let previousImageID = try? String(
            contentsOfFile: preparation.imageID.string,
            encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            try? FileManager.default.removeItem(atPath: candidate.string)
        }
        try await checkedAOSPProductCommand(
            .named("podman"),
            [
                "build",
                "--pull=always",
                "--tag", preparation.imageName,
                "--iidfile", candidate.string,
                "--file", preparation.containerFile.string,
                preparation.context.string,
            ],
            in: preparation.context,
            environment: preparation.environment,
            output: .logged,
            stage: stage)
        let imageID = try String(
            contentsOfFile: candidate.string,
            encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageID.hasPrefix("sha256:"), imageID.count == 71 else {
            throw RuntimeFailure.invalidOutput(
                "Podman did not produce a content-addressed AOSP image ID")
        }
        try replaceAOSPProductFile(candidate, with: preparation.imageID)
        if let previousImageID,
           previousImageID != imageID,
           previousImageID.hasPrefix("sha256:"),
           previousImageID.count == 71
        {
            // Remove only the exact image Collider previously recorded.
            // Podman refuses while a container still references it, preserving
            // active external use without broad image-prune semantics.
            _ = try await execute(
                CommandSpec(
                    executable: .named("podman"),
                    arguments: ["image", "rm", previousImageID],
                    workingDirectory: preparation.context,
                    environment: preparation.environment,
                    output: .logged),
                stage: stage)
        }
    }

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

    func compileAOSPProduct(
        _ build: AOSPProductBuild,
        stage: TaskID
    ) async throws {
        guard build.buildJobs > 0,
              build.expectedPlatformSDK > 0,
              build.expectedVendorAPILevel > 0,
              build.variant == "user"
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP production builds require positive concurrency/API "
                    + "levels and the user variant")
        }
        let sourceProvenance = try JSONDecoder().decode(
            AOSPBuildSourceProvenance.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: build.sourceProvenance.string)))
        guard sourceProvenance.status == "materialized" else {
            throw RuntimeFailure.invalidOutput(
                "AOSP source provenance is not materialized")
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
                output: .logged),
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
        let productDigest = try aospProductDefinitionDigest(
            productSource: build.productSource,
            sourceOverlays: build.sourceOverlays)
        try stageAOSPProduct(build, digest: productDigest)

        let output = build.buildRoot.appending("out")
        let distribution = build.buildRoot.appending("dist")
        let unsigned = build.buildRoot.appending("unsigned")
        let signed = build.buildRoot.appending("signed")
        for directory in [
            build.buildRoot,
            build.ccacheDirectory,
            output,
            distribution,
            unsigned,
            signed,
        ] {
            try FileManager.default.createDirectory(
                atPath: directory.string,
                withIntermediateDirectories: true)
        }
        try DurableFile.write(
            Data("max_size = 50G\n".utf8),
            to: build.ccacheDirectory.appending("ccache.conf"))
        let outputMount = build.source.appending("out/nucleus")
        let distributionMount = build.source.appending(
            "out/nucleus-dist")
        try ensureAOSPContainerMountpoint(outputMount)
        try ensureAOSPContainerMountpoint(distributionMount)

        var environment: [String: String] = [:]
        environment["TARGET_PRODUCT"] = build.product
        environment["TARGET_BUILD_VARIANT"] = build.variant
        environment["TARGET_RELEASE"] = build.release
        // Siso requires its generated config repository to be relative to the
        // AOSP execution root, and Soong rejects lexical paths that escape that
        // root. Source-local links satisfy both contracts while keeping every
        // generated byte under android-runtime/.aosp-build.
        environment["OUT_DIR"] = "out/nucleus"
        environment["DIST_DIR"] = "out/nucleus-dist"
        environment["BUILD_NUMBER"] = build.buildNumber
        environment["BUILD_DATETIME"] = String(build.buildTimestamp)
        environment["BUILD_USERNAME"] = "nucleus"
        environment["BUILD_HOSTNAME"] = "collider"
        environment["TZ"] = "UTC"
        environment["LANG"] = "C.UTF-8"
        environment["LC_ALL"] = "C.UTF-8"
        environment["USE_CCACHE"] = "1"
        environment["CCACHE_EXEC"] = "/usr/bin/ccache"
        environment["CCACHE_DIR"] = "/src/out/nucleus/.ccache"
        environment["CCACHE_COMPILERCHECK"] = "content"

        try await validateAOSPBuildSandbox(
            build,
            writableMounts: [
                (output, "/src/out/nucleus"),
                (distribution, "/src/out/nucleus-dist"),
            ],
            environment: environment,
            stage: stage)

        let cleanResult = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: try aospContainerArguments(
                    build: build,
                    writableMounts: [
                        (output, "/src/out/nucleus"),
                        (distribution, "/src/out/nucleus-dist"),
                        (
                            build.ccacheDirectory,
                            "/src/out/nucleus/.ccache"
                        ),
                    ],
                    readOnlyMounts: [
                        (build.source, "/src"),
                    ],
                    environment: environment,
                    command: [
                        "/src/build/soong/soong_ui.bash",
                        "--make-mode",
                        "installclean",
                    ]),
                workingDirectory: build.source,
                environment: build.environment,
                output: .logged),
            stage: stage)
        try rejectAOSPSandboxDegradation(
            cleanResult.standardOutput,
            status: cleanResult.status)

        let result = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: try aospContainerArguments(
                    build: build,
                    writableMounts: [
                        (output, "/src/out/nucleus"),
                        (distribution, "/src/out/nucleus-dist"),
                        (
                            build.ccacheDirectory,
                            "/src/out/nucleus/.ccache"
                        ),
                    ],
                    readOnlyMounts: [
                        (build.source, "/src"),
                    ],
                    environment: environment,
                    command: [
                        "/src/build/soong/soong_ui.bash",
                        "--make-mode",
                        "-j\(build.buildJobs)",
                        "target-files-package",
                        "otatools",
                    ]),
                workingDirectory: build.source,
                environment: build.environment,
                output: .logged),
            stage: stage)
        try rejectAOSPSandboxDegradation(
            result.standardOutput,
            status: result.status)

        let builtTargetFiles = try locateAOSPTargetFiles(
            product: build.product,
            under: output)
        let unsignedTargetFiles = unsigned.appending(
            "\(build.product)-target_files.zip")
        try DurableFile.copy(
            from: builtTargetFiles,
            to: unsignedTargetFiles)
        let unsignedDigest = try ArtifactHasher.digest(
            file: unsignedTargetFiles).sha256Hex
        try DurableFile.write(
            Data(
                "\(unsignedDigest)  \(build.product)-target_files.zip\n".utf8),
            to: unsigned.appending(
                "\(build.product)-target_files.zip.sha256"))
    }

    func signAOSPProduct(
        _ build: AOSPProductBuild,
        stage: TaskID
    ) async throws {
        try await validateAOSPSigningIdentity(
            AOSPSigningIdentityPreparation(
                destination: build.signingIdentity,
                subject: try aospSigningIdentity(
                    at: build.signingIdentity).subject,
                environment: build.environment),
            stage: stage)
        let output = build.buildRoot.appending("out")
        let unsigned = build.buildRoot.appending("unsigned")
        let staged = build.buildRoot.appending("staged")
        try FileManager.default.createDirectory(
            atPath: staged.string,
            withIntermediateDirectories: true)
        let hostTools = output.appending("host/linux-x86/bin")
        let signingTool = hostTools.appending("sign_target_files_apks")
        for tool in [signingTool] where
            !FileManager.default.isExecutableFile(atPath: tool.string)
        {
            throw RuntimeFailure.invalidOutput(
                "AOSP host signing tool is missing: \(tool)")
        }
        let environment = aospContainerToolEnvironment()
        let signedTargetCandidate = staged.appending(
            ".\(build.product)-target_files.candidate-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(
                atPath: signedTargetCandidate.string)
        }
        var signingArguments = [
            "-o",
            "-d", "/keys",
            "--override_apk_keys", aospContainerReleaseKey,
            "--override_apex_keys", aospContainerReleasePEM,
            "--avb_vbmeta_key", aospContainerReleasePEM,
            "--avb_vbmeta_algorithm", "SHA256_RSA4096",
            "--avb_vbmeta_system_key", aospContainerReleasePEM,
            "--avb_vbmeta_system_algorithm", "SHA256_RSA4096",
            "--avb_system_key", aospContainerReleasePEM,
            "--avb_system_algorithm", "SHA256_RSA4096",
            "--avb_vendor_key", aospContainerReleasePEM,
            "--avb_vendor_algorithm", "SHA256_RSA4096",
        ]
        for partition in ["product", "system_ext"] {
            signingArguments += [
                "--avb_extra_custom_image_key",
                "\(partition)=\(aospContainerReleasePEM)",
                "--avb_extra_custom_image_algorithm",
                "\(partition)=SHA256_RSA4096",
            ]
        }
        if build.variant != "user" {
            signingArguments.append("--allow_gsi_debug_sepolicy")
        }
        signingArguments += [
            "/unsigned/\(build.product)-target_files.zip",
            "/staged/\(signedTargetCandidate.lastComponent?.string ?? "")",
        ]
        try await checkedAOSPProductCommand(
            .named("podman"),
            try aospContainerArguments(
                build: build,
                writableMounts: [(staged, "/staged")],
                readOnlyMounts: [
                    (build.source, "/src"),
                    (output, "/src/out/nucleus"),
                    (unsigned, "/unsigned"),
                    (build.signingIdentity, "/keys"),
                ],
                environment: environment,
                command: [
                    "/src/out/nucleus/host/linux-x86/bin/"
                        + "sign_target_files_apks",
                ] + signingArguments),
            in: build.buildRoot,
            environment: build.environment,
            output: .logged,
            stage: stage)
        try replaceAOSPProductFile(
            signedTargetCandidate,
            with: staged.appending(
                "\(build.product)-target_files.zip"))
    }

    func assembleAOSPProductImages(
        _ build: AOSPProductBuild,
        stage: TaskID
    ) async throws {
        let output = build.buildRoot.appending("out")
        let staged = build.buildRoot.appending("staged")
        try FileManager.default.createDirectory(
            atPath: staged.string,
            withIntermediateDirectories: true)
        let hostTools = output.appending("host/linux-x86/bin")
        let imageTool = hostTools.appending("img_from_target_files")
        guard FileManager.default.isExecutableFile(atPath: imageTool.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP host image tool is missing: \(imageTool)")
        }
        let environment = aospContainerToolEnvironment()
        let signedTargetCandidate = staged.appending(
            "\(build.product)-target_files.zip")
        let imageArchiveCandidate = staged.appending(
            ".\(build.product)-images.candidate-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(
                atPath: imageArchiveCandidate.string)
        }
        try await checkedAOSPProductCommand(
            .named("podman"),
            try aospContainerArguments(
                build: build,
                writableMounts: [(staged, "/staged")],
                readOnlyMounts: [
                    (build.source, "/src"),
                    (output, "/src/out/nucleus"),
                ],
                environment: environment,
                command: [
                    "/src/out/nucleus/host/linux-x86/bin/"
                        + "img_from_target_files",
                    "/staged/\(signedTargetCandidate.lastComponent?.string ?? "")",
                    "/staged/\(imageArchiveCandidate.lastComponent?.string ?? "")",
                ]),
            in: build.buildRoot,
            environment: build.environment,
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
            environment: build.environment,
            stage: stage)

        let requiredImages = [
            "system.img",
            "system_ext.img",
            "product.img",
            "vendor.img",
            "vbmeta.img",
            "vbmeta_system.img",
        ]
        let sparseImageTool = hostTools.appending("simg2img")
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
                    .named("podman"),
                    try aospContainerArguments(
                        build: build,
                        writableMounts: [(imageCandidate, "/images")],
                        readOnlyMounts: [
                            (build.source, "/src"),
                            (output, "/src/out/nucleus"),
                        ],
                        environment: environment,
                        command: [
                            "/src/out/nucleus/host/linux-x86/bin/simg2img",
                            "/images/\(name)",
                            "/images/\(name).raw",
                        ]),
                    in: build.buildRoot,
                    environment: build.environment,
                    stage: stage)
                try FileManager.default.removeItem(atPath: image.string)
                try FileManager.default.moveItem(
                    atPath: rawImage.string,
                    toPath: image.string)
            }
        }
        try replaceAOSPProductFile(
            imageArchiveCandidate,
            with: staged.appending("\(build.product)-images.zip"))
        let stagedImages = staged.appending("images")
        if FileManager.default.fileExists(atPath: stagedImages.string) {
            try FileManager.default.removeItem(atPath: stagedImages.string)
        }
        try FileManager.default.moveItem(
            atPath: imageCandidate.string,
            toPath: stagedImages.string)
    }

    func validateAOSPProduct(
        _ build: AOSPProductBuild,
        stage: TaskID
    ) async throws {
        let sourceProvenance = try JSONDecoder().decode(
            AOSPBuildSourceProvenance.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: build.sourceProvenance.string)))
        let productDigest = try aospProductDefinitionDigest(
            productSource: build.productSource,
            sourceOverlays: build.sourceOverlays)
        let output = build.buildRoot.appending("out")
        let staged = build.buildRoot.appending("staged")
        let hostTools = output.appending("host/linux-x86/bin")
        let signedTargetCandidate = staged.appending(
            "\(build.product)-target_files.zip")
        let imageArchiveCandidate = staged.appending(
            "\(build.product)-images.zip")
        let imageCandidate = staged.appending("images")
        let environment = aospProductEnvironment(
            build,
            hostTools: hostTools)
        let releasePEM = build.signingIdentity.appending("releasekey.pem")
        let avbTool = hostTools.appending("avbtool")
        guard FileManager.default.isExecutableFile(atPath: avbTool.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP avbtool is missing: \(avbTool)")
        }
        let requiredImages = [
            "system.img",
            "system_ext.img",
            "product.img",
            "vendor.img",
            "vbmeta.img",
            "vbmeta_system.img",
        ]
        var images: [AOSPImageProvenance.Image] = []
        for name in requiredImages {
            let image = imageCandidate.appending(name)
            guard image.isRegularFile else {
                throw RuntimeFailure.invalidOutput(
                    "validated Android image is missing: \(name)")
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: image.string)
            images.append(AOSPImageProvenance.Image(
                name: name,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
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
        try await requireAOSPFontContract(
            archive: signedTargetCandidate,
            environment: environment,
            stage: stage)
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
              fingerprint.hasSuffix(":user/release-keys"),
              build.variant == "user"
        else {
            throw RuntimeFailure.invalidOutput(
                "signed production product fingerprint is invalid: "
                    + fingerprint)
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
                sourceSuperprojectCommit:
                    sourceProvenance.superprojectCommit,
                sourceManifestSHA256:
                    sourceProvenance.resolvedManifestSHA256,
                productTreeSHA256: productDigest.sha256Hex,
                signingPurpose: signing.purpose,
                signingCertificates: signing.certificates,
                targetFilesSHA256: targetFilesDigest,
                imageArchiveSHA256: imageArchiveDigest,
                images: images.sorted { $0.name < $1.name }),
            to: staged.appending("image-provenance.json"))
    }

    func publishAOSPProduct(
        _ build: AOSPProductBuild,
        stage _: TaskID
    ) async throws {
        let staged = build.buildRoot.appending("staged")
        let signed = build.buildRoot.appending("signed")
        let finalImages = build.buildRoot.appending("images")
        try FileManager.default.createDirectory(
            atPath: signed.string,
            withIntermediateDirectories: true)

        try publishAOSPProductFile(
            staged.appending("\(build.product)-target_files.zip"),
            to: signed.appending("\(build.product)-target_files.zip"))
        try publishAOSPProductFile(
            staged.appending("\(build.product)-images.zip"),
            to: signed.appending("\(build.product)-images.zip"))

        let imageCandidate = build.buildRoot.appending(
            ".images.publish-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(
                atPath: imageCandidate.string)
        }
        try linkAOSPProductTree(
            staged.appending("images"),
            to: imageCandidate)
        if FileManager.default.fileExists(atPath: finalImages.string) {
            try FileManager.default.removeItem(atPath: finalImages.string)
        }
        try FileManager.default.moveItem(
            atPath: imageCandidate.string,
            toPath: finalImages.string)

        // Provenance is the publication commit marker. Framework boot rejects
        // any artifact set whose digests do not match this file.
        try publishAOSPProductFile(
            staged.appending("image-provenance.json"),
            to: signed.appending("image-provenance.json"))

        let generations = build.buildRoot.removingLastComponent()
        let aospBuildRoot = generations.removingLastComponent()
        let active = aospBuildRoot.appending("current")
        let generationName = build.buildRoot.lastComponent?.string ?? ""
        try DirectoryLifecycle.activate(
            target: "generations/\(generationName)",
            link: active)
        try DirectoryLifecycle.prune(DirectoryRetentionPlan(
            safetyRoot: aospBuildRoot,
            rules: [
                DirectoryRetentionRule(
                    root: generations,
                    current: active,
                    retain: 2,
                    naming: .aospProduct),
            ]))
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
        try synchronizeAOSPProductTree(
            from: build.productSource,
            to: destination,
            preservingAtRoot: [".nucleus-product-stage.json"])
        for overlay in build.sourceOverlays {
            guard !overlay.relativeDestination.isEmpty,
                !overlay.relativeDestination.hasPrefix("/"),
                !overlay.relativeDestination.split(separator: "/")
                    .contains("..")
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid AOSP product overlay destination "
                        + "'\(overlay.relativeDestination)'")
            }
            try synchronizeAOSPProductTree(
                from: overlay.source,
                to: destination.appending(overlay.relativeDestination),
                preservingAtRoot: [])
        }
        try DurableFile.writeJSON(
            AOSPProductStage(
                source: build.productSource.string,
                sha256: digest.sha256Hex),
            to: stageMetadata)
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
        guard aospReleaseSigningMetadataUsesContainerKeys(metadata) else {
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

    private func requireAOSPFontContract(
        archive: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let entries = try await capturedAOSPProductCommand(
            .named("unzip"),
            ["-Z1", archive.string],
            in: archive.removingLastComponent(),
            environment: environment,
            stage: stage)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let requiredConfigurations = [
            "SYSTEM/etc/fonts.xml",
            "SYSTEM/etc/font_fallback.xml",
        ]
        for path in requiredConfigurations where !entries.contains(path) {
            throw RuntimeFailure.invalidOutput(
                "signed Android font contract is missing \(path)")
        }
        var configurations: [String: String] = [:]
        for path in requiredConfigurations {
            configurations[path] = try await capturedAOSPArchiveEntry(
                archive: archive,
                candidates: [path],
                environment: environment,
                stage: stage)
        }
        try validateAOSPFontContract(
            archiveEntries: entries,
            configurations: configurations)
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

private let aospContainerReleaseKey = "/keys/releasekey"
private let aospContainerReleasePEM = "\(aospContainerReleaseKey).pem"

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
        if elementName == "font" {
            fontText = ""
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if fontText != nil {
            fontText?.append(string)
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard elementName == "font", let fontText else { return }
        let reference = fontText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !reference.isEmpty {
            references.insert(reference)
        }
        self.fontText = nil
    }
}

func validateAOSPFontContract(
    archiveEntries: [String],
    configurations: [String: String]
) throws {
    let requiredConfigurations = [
        "SYSTEM/etc/fonts.xml",
        "SYSTEM/etc/font_fallback.xml",
    ]
    let entries = Set(archiveEntries)
    var referencesByConfiguration: [String: Set<String>] = [:]
    for path in requiredConfigurations {
        guard entries.contains(path), let contents = configurations[path] else {
            throw RuntimeFailure.invalidOutput(
                "signed Android font contract is missing \(path)")
        }
        let parser = XMLParser(data: Data(contents.utf8))
        let delegate = AOSPFontReferenceParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw RuntimeFailure.invalidOutput(
                "signed Android font configuration \(path) is invalid: "
                    + (parser.parserError?.localizedDescription
                        ?? "XML parsing failed"))
        }
        referencesByConfiguration[path] = delegate.references
    }
    guard referencesByConfiguration["SYSTEM/etc/fonts.xml"]?
        .contains("Roboto-Regular.ttf") == true
    else {
        throw RuntimeFailure.invalidOutput(
            "signed Android font contract has no Roboto default family")
    }

    // fonts.xml is Android's deprecated compatibility view and can retain
    // names removed or renamed by release flags. font_fallback.xml is generated
    // for the selected release and is the authoritative runtime font map.
    let references =
        referencesByConfiguration["SYSTEM/etc/font_fallback.xml"] ?? []
    let fontRoots = ["SYSTEM", "PRODUCT", "SYSTEM_EXT", "VENDOR"]
    let missing = references.filter { reference in
        guard !reference.contains("..") else { return true }
        if reference.hasPrefix("/") {
            let components = reference.dropFirst().split(
                separator: "/",
                omittingEmptySubsequences: true)
            guard let partition = components.first else { return true }
            let archivePath = ([partition.uppercased()]
                + components.dropFirst().map(String.init))
                .joined(separator: "/")
            return !entries.contains(archivePath)
        }
        return !fontRoots.contains { root in
            entries.contains("\(root)/fonts/\(reference)")
        }
    }
    guard missing.isEmpty else {
        throw RuntimeFailure.invalidOutput(
            "signed Android font configurations reference missing fonts: "
                + missing.sorted().joined(separator: ", "))
    }
}

func aospReleaseSigningMetadataUsesContainerKeys(
    _ metadata: String
) -> Bool {
    let properties = aospProperties(metadata)
    return properties["avb_vbmeta_key_path"] == aospContainerReleasePEM
        && properties["avb_vbmeta_system_key_path"]
            == aospContainerReleasePEM
        && properties["default_system_dev_certificate"]
            == aospContainerReleaseKey
}

private let aospSigningAliases = [
    "releasekey",
    "platform",
    "shared",
    "media",
    "networkstack",
]

func aospContainerArguments(
    build: AOSPProductBuild,
    writableMounts: [(FilePath, String)],
    readOnlyMounts: [(FilePath, String)],
    environment: [String: String],
    command: [String]
) throws -> [String] {
    let imageID = try String(
        contentsOfFile: build.containerImageID.string,
        encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard imageID.hasPrefix("sha256:"), imageID.count == 71 else {
        throw RuntimeFailure.invalidOutput(
            "AOSP build container image ID is missing or invalid")
    }
    var arguments = [
        "run",
        "--rm",
        "--network=none",
        "--userns=keep-id:uid=1000,gid=1000",
        "--cap-drop=all",
        "--security-opt=no-new-privileges",
        "--security-opt=unmask=/proc/*",
        "--hostname=android-build",
        "--read-only",
        "--pids-limit=32768",
        "--tmpfs=/tmp:rw,nosuid,nodev,size=8g",
        "--tmpfs=/home/nucleus-build:rw,nosuid,nodev,noexec,size=1g",
        "--workdir=/src",
    ]
    for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
        arguments += ["--env", "\(name)=\(value)"]
    }
    for (source, target) in readOnlyMounts {
        arguments += [
            "--mount",
            "type=bind,src=\(source.string),target=\(target),ro=true",
        ]
    }
    for (source, target) in writableMounts {
        arguments += [
            "--mount",
            "type=bind,src=\(source.string),target=\(target),rw=true",
        ]
    }
    arguments.append(imageID)
    arguments += command
    return arguments
}

private extension ColliderRuntime {
    func validateAOSPBuildSandbox(
        _ build: AOSPProductBuild,
        writableMounts: [(FilePath, String)],
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let validation = build.buildRoot.appending(
            ".sandbox-validation-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(
                atPath: validation.string)
        }
        try FileManager.default.createDirectory(
            atPath: validation.string,
            withIntermediateDirectories: false)
        try DurableFile.write(
            Data("host-visible\n".utf8),
            to: validation.appending("host-canary"))
        let brokenNSJail = validation.appending("broken-nsjail")
        try DurableFile.write(
            Data("#!/bin/sh\nexit 1\n".utf8),
            to: brokenNSJail)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: brokenNSJail.string)

        let isolationValidation = """
            import socket
            import subprocess
            import sys

            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            child = f'''
            import os
            import socket
            import sys

            if os.path.exists("/validation/host-canary"):
                sys.exit(41)
            print("NUCLEUS_NSJAIL_FILE_HIDDEN")
            connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            connection.settimeout(0.5)
            try:
                connection.connect(("127.0.0.1", {port}))
            except OSError:
                print("NUCLEUS_NSJAIL_NETWORK_ISOLATED")
                sys.exit(0)
            sys.exit(42)
            '''
            result = subprocess.run(
                [
                    "/src/prebuilts/build-tools/linux-x86/bin/nsjail",
                    "-H", "android-build",
                    "--disable_clone_newuts",
                    "-e",
                    "-u", "1000",
                    "-g", "1000",
                    "-R", "/",
                    "-B", "/tmp",
                    "-T", "/validation",
                    "--disable_clone_newcgroup",
                    "--",
                    "/usr/bin/python3", "-c", child,
                ],
                capture_output=True,
                text=True,
            )
            listener.close()
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            if result.returncode != 0:
                sys.exit(result.returncode)
            print("NUCLEUS_NSJAIL_ISOLATION_OK")
            """
        let containerEnvironment = aospContainerToolEnvironment().merging(
            environment,
            uniquingKeysWith: { _, requested in requested })
        let isolation = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: try aospContainerArguments(
                    build: build,
                    writableMounts: writableMounts + [
                        (validation, "/validation"),
                    ],
                    readOnlyMounts: [
                        (build.source, "/src"),
                    ],
                    environment: containerEnvironment,
                    command: [
                        "/usr/bin/python3",
                        "-c",
                        isolationValidation,
                    ]),
                workingDirectory: build.source,
                environment: build.environment,
                output: .combined(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        try validateAOSPSandboxIsolation(
            isolation.standardOutput,
            status: isolation.status)

        let broken = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: try aospContainerArguments(
                    build: build,
                    writableMounts: writableMounts,
                    readOnlyMounts: [
                        (build.source, "/src"),
                        (
                            brokenNSJail,
                            "/src/prebuilts/build-tools/linux-x86/bin/nsjail"
                        ),
                    ],
                    environment: containerEnvironment,
                    command: [
                        "/src/build/soong/soong_ui.bash",
                        "--dumpvars-mode",
                        "--vars=TARGET_PRODUCT",
                    ]),
                workingDirectory: build.source,
                environment: build.environment,
                output: .combined(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        try validateAOSPBrokenSandboxBehavior(
            broken.standardOutput,
            status: broken.status)
    }
}

func validateAOSPSandboxIsolation(
    _ output: String,
    status: Int32
) throws {
    guard status == 0,
          output.contains("NUCLEUS_NSJAIL_FILE_HIDDEN"),
          output.contains("NUCLEUS_NSJAIL_NETWORK_ISOLATED"),
          output.contains("NUCLEUS_NSJAIL_ISOLATION_OK")
    else {
        throw RuntimeFailure.invalidOutput(
            "nsjail did not prove file and network isolation")
    }
}

func validateAOSPBrokenSandboxBehavior(
    _ output: String,
    status: Int32
) throws {
    let lowercased = output.lowercased()
    guard status != 0,
          lowercased.contains("nsjail sandbox probe failed"),
          !lowercased.contains(
            "build sandboxing disabled due to nsjail error")
    else {
        throw RuntimeFailure.invalidOutput(
            "Soong did not fail closed for a broken nsjail executable")
    }
}

func rejectAOSPSandboxDegradation(
    _ output: String,
    status: Int32
) throws {
    guard status == 0 else {
        throw RuntimeFailure.invalidOutput(
            "rootless AOSP container build failed")
    }
    let lowercased = output.lowercased()
    guard !lowercased.contains(
        "build sandboxing disabled due to nsjail error"),
          !lowercased.contains("sandboxing disabled")
    else {
        throw RuntimeFailure.invalidOutput(
            "Soong disabled nsjail; AOSP builds must remain fail-closed")
    }
}

func aospContainerToolEnvironment() -> [String: String] {
    let javaHome = "/src/prebuilts/jdk/jdk21/linux-x86"
    return [
        "ANDROID_JAVA_HOME": javaHome,
        "HOME": "/home/nucleus-build",
        "JAVA_HOME": javaHome,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "\(javaHome)/bin:"
            + "/src/out/nucleus/host/linux-x86/bin:"
            + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TZ": "UTC",
    ]
}

private func ensureAOSPContainerMountpoint(_ path: FilePath) throws {
    let manager = FileManager.default
    if let attributes = try? manager.attributesOfItem(atPath: path.string),
       attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
        try manager.removeItem(atPath: path.string)
    }
    try manager.createDirectory(
        atPath: path.string,
        withIntermediateDirectories: true)
}

private func aospProductEnvironment(
    _ build: AOSPProductBuild,
    hostTools: FilePath
) -> [String: String] {
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

private func publishAOSPProductFile(
    _ source: FilePath,
    to destination: FilePath
) throws {
    guard source.isRegularFile else {
        throw RuntimeFailure.invalidOutput(
            "AOSP publication input is missing: \(source)")
    }
    let candidate = FilePath(
        destination.string + ".candidate-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(atPath: candidate.string)
    }
    try FileManager.default.linkItem(
        atPath: source.string,
        toPath: candidate.string)
    try replaceAOSPProductFile(candidate, with: destination)
}

private func linkAOSPProductTree(
    _ source: FilePath,
    to destination: FilePath
) throws {
    let sourceURL = URL(fileURLWithPath: source.string)
    let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values?.isDirectory == true
    else {
        throw RuntimeFailure.invalidOutput(
            "AOSP image publication tree is missing: \(source)")
    }
    try FileManager.default.createDirectory(
        atPath: destination.string,
        withIntermediateDirectories: false)
    for name in try FileManager.default.contentsOfDirectory(
        atPath: source.string)
    {
        let child = source.appending(name)
        let published = destination.appending(name)
        let childValues = try? URL(
            fileURLWithPath: child.string
        ).resourceValues(forKeys: [.isDirectoryKey])
        guard let childIsDirectory = childValues?.isDirectory else {
            throw RuntimeFailure.invalidOutput(
                "AOSP image publication entry disappeared: \(child)")
        }
        if childIsDirectory {
            try linkAOSPProductTree(child, to: published)
        } else {
            try FileManager.default.linkItem(
                atPath: child.string,
                toPath: published.string)
        }
    }
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

func synchronizeAOSPProductTree(
    from source: FilePath,
    to destination: FilePath,
    preservingAtRoot preservedNames: Set<String> = []
) throws {
    let manager = FileManager.default
    let sourceMetadata = try source.stat(followTargetSymlink: false)
    guard sourceMetadata.type == .directory else {
        throw RuntimeFailure.invalidOutput(
            "AOSP product source is not a directory: \(source)")
    }
    if let destinationMetadata = try? destination.stat(
        followTargetSymlink: false),
        destinationMetadata.type != .directory
    {
        try manager.removeItem(atPath: destination.string)
    }
    try manager.createDirectory(
        atPath: destination.string,
        withIntermediateDirectories: true)

    let sourceNames = Set(try manager.contentsOfDirectory(
        atPath: source.string))
    let destinationNames = Set(try manager.contentsOfDirectory(
        atPath: destination.string))
    for name in destinationNames
        .subtracting(sourceNames)
        .subtracting(preservedNames)
        .sorted()
    {
        try manager.removeItem(
            atPath: destination.appending(name).string)
    }

    for name in sourceNames.sorted() {
        let sourceEntry = source.appending(name)
        let destinationEntry = destination.appending(name)
        let sourceEntryMetadata = try sourceEntry.stat(
            followTargetSymlink: false)
        let destinationEntryMetadata = try? destinationEntry.stat(
            followTargetSymlink: false)
        switch sourceEntryMetadata.type {
        case .directory:
            if let destinationEntryMetadata,
                destinationEntryMetadata.type != .directory
            {
                try manager.removeItem(atPath: destinationEntry.string)
            }
            try synchronizeAOSPProductTree(
                from: sourceEntry,
                to: destinationEntry)
        case .regular:
            var sameFile = false
            if destinationEntryMetadata?.type == .regular,
                destinationEntryMetadata?.permissions
                    .contains(.ownerExecute)
                    == sourceEntryMetadata.permissions
                        .contains(.ownerExecute)
            {
                sameFile =
                    try ArtifactHasher.digest(file: destinationEntry)
                    == ArtifactHasher.digest(file: sourceEntry)
            }
            if !sameFile {
                if destinationEntryMetadata?.type != .regular,
                    destinationEntryMetadata != nil
                {
                    try manager.removeItem(atPath: destinationEntry.string)
                }
                try DurableFile.copy(
                    from: sourceEntry,
                    to: destinationEntry)
            }
        case .symbolicLink:
            let sourceTarget = try manager.destinationOfSymbolicLink(
                atPath: sourceEntry.string)
            let destinationTarget =
                destinationEntryMetadata?.type == .symbolicLink
                ? try manager.destinationOfSymbolicLink(
                    atPath: destinationEntry.string)
                : nil
            if sourceTarget != destinationTarget {
                if destinationEntryMetadata != nil {
                    try manager.removeItem(atPath: destinationEntry.string)
                }
                try manager.createSymbolicLink(
                    atPath: destinationEntry.string,
                    withDestinationPath: sourceTarget)
            }
        default:
            throw RuntimeFailure.invalidOutput(
                "AOSP product source contains an unsupported entry: "
                    + sourceEntry.string)
        }
    }
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

private struct AOSPBuildSourceProvenance: Decodable {
    let status: String
    let manifestCommit: String
    let superprojectCommit: String
    let resolvedManifestSHA256: String
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
    let sourceSuperprojectCommit: String
    let sourceManifestSHA256: String
    let productTreeSHA256: String
    let signingPurpose: String
    let signingCertificates: [AOSPSigningIdentity.Certificate]
    let targetFilesSHA256: String
    let imageArchiveSHA256: String
    let images: [Image]
}
