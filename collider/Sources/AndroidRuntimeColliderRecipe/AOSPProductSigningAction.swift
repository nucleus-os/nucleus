import ColliderCore
import Foundation
import SystemPackage

struct SignAOSPProductAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sourceWorkspace: PersistentWorkspaceDeclaration
        let buildRoot: FilePath
        let containerImageID: FilePath
        let signingIdentity: FilePath
        let product: String
        let variant: String
        let expectedPlatformSDK: UInt32

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(sourceWorkspace.identity.key)
            encoder.append(sourceWorkspace.capacityBytes)
            encoder.append(path: buildRoot)
            encoder.append(path: containerImageID)
            encoder.append(path: signingIdentity)
            encoder.append(product)
            encoder.append(variant)
            encoder.append(UInt64(expectedPlatformSDK))
        }
    }

    static let kind: ActionKind = "android-runtime.sign-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity {
        Identity(
            sourceWorkspace: build.sourceWorkspace,
            buildRoot: build.artifactRoot,
            containerImageID: build.artifactImageID,
            signingIdentity: build.signingIdentity,
            product: build.product,
            variant: build.variant,
            expectedPlatformSDK: build.expectedPlatformSDK)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(build.artifactImageID)),
                ActionEffect(.read, scope: .input(build.signingIdentity)),
                ActionEffect(.readWrite, scope: .scratch(build.artifactRoot)),
            ],
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: build.sourceWorkspace,
                    target: "/src",
                    access: .readOnly),
                ActionPersistentWorkspaceEffect(
                    workspace: build.outputWorkspace,
                    target: "/out",
                    access: .readOnly),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .androidX86_64(
                apiLevel: build.expectedPlatformSDK))
    }

    var environment: [String: String] { build.environment }

    func execute(in context: ActionContext) async throws {
        try validateSigningIdentityMetadata(files: context.files)
        let unsigned = build.artifactRoot.appending("unsigned")
        let staged = build.artifactRoot.appending("staged")
        try context.files.createDirectory(staged)
        let unsignedTarget = unsigned.appending(
            "\(build.product)-target_files.zip")
        guard try context.files.metadata(for: unsignedTarget)?.type == .regular else {
            throw AOSPProductSigningFailure.missingInput(unsignedTarget)
        }

        let candidate = staged.appending(
            ".\(build.product)-target_files.candidate.zip")
        try context.files.remove(candidate)
        defer { try? context.files.remove(candidate) }
        var arguments = [
            "-o",
            "-d", "/keys",
            "--threads", String(min(build.buildJobs, 8)),
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
            arguments += [
                "--avb_extra_custom_image_key",
                "\(partition)=\(aospContainerReleasePEM)",
                "--avb_extra_custom_image_algorithm",
                "\(partition)=SHA256_RSA4096",
            ]
        }
        if build.variant != "user" {
            arguments.append("--allow_gsi_debug_sepolicy")
        }
        arguments += [
            "/unsigned/\(build.product)-target_files.zip",
            "/staged/\(candidate.lastComponent?.string ?? "")",
        ]
        try await context.containers.run(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(staged, "/staged")],
                readOnlyMounts: [
                    (unsigned, "/unsigned"),
                    (build.signingIdentity, "/keys"),
                ],
                persistentWorkspaceMounts: [build.readOnlyOutputMount],
                command: [
                    "/out/host/linux-x86/bin/sign_target_files_apks"
                ] + arguments))
        guard try context.files.metadata(for: candidate)?.type == .regular else {
            throw AOSPProductSigningFailure.missingOutput(candidate)
        }
        let destination = staged.appending(
            "\(build.product)-target_files.zip")
        try context.files.remove(destination)
        try context.files.move(from: candidate, to: destination)
    }

    private func validateSigningIdentityMetadata(files: ActionFileSystem) throws {
        let identity = try JSONDecoder().decode(
            AOSPSigningIdentity.self,
            from: Data(
                try files.read(
                    build.signingIdentity.appending("signing-identity.json"))))
        guard identity.purpose == "local-development",
            identity.certificates.map(\.alias) == aospSigningAliases
        else {
            throw AOSPProductSigningFailure.invalidSigningIdentity
        }
        for certificate in identity.certificates {
            let base = build.signingIdentity.appending(certificate.alias)
            let certificatePath = FilePath(base.string + ".x509.pem")
            for path in [
                FilePath(base.string + ".pem"),
                certificatePath,
                FilePath(base.string + ".pk8"),
            ] {
                guard try files.metadata(for: path)?.type == .regular else {
                    throw AOSPProductSigningFailure.missingInput(path)
                }
            }
            guard
                try files.digest(file: certificatePath).hexadecimal
                    == certificate.x509SHA256
            else {
                throw AOSPProductSigningFailure.invalidSigningIdentity
            }
        }
    }
}

let aospContainerReleaseKey = "/keys/releasekey"
let aospContainerReleasePEM = "\(aospContainerReleaseKey).pem"

private enum AOSPProductSigningFailure: Error, CustomStringConvertible {
    case invalidSigningIdentity
    case missingInput(FilePath)
    case missingOutput(FilePath)

    var description: String {
        switch self {
        case .invalidSigningIdentity:
            "AOSP signing identity metadata or certificate digest is invalid"
        case .missingInput(let path):
            "AOSP unsigned target-files archive is missing: \(path)"
        case .missingOutput(let path):
            "AOSP signing did not produce its candidate archive: \(path)"
        }
    }
}
