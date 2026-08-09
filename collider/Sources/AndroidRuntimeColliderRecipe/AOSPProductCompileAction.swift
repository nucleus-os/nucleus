import ColliderCore
import Foundation
import SystemPackage

struct CompileAOSPProductAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let build: AOSPProductBuild

        func encode(into encoder: inout ActionIdentityEncoder) {
            for (tag, path) in [
                (1, build.productSource),
                (2, build.source),
                (4, build.sourceProvenance),
                (5, build.artifactRoot),
                (7, build.containerImageID),
            ] {
                encoder.append(tag: UInt64(tag), string: path.string)
            }
            encoder.append(tag: 8, string: build.product)
            encoder.append(tag: 9, string: build.release)
            encoder.append(tag: 10, string: build.variant)
            encoder.append(tag: 11, string: build.buildNumber)
            encoder.append(tag: 12, integer: build.buildTimestamp)
            encoder.append(tag: 13, integer: UInt64(build.expectedPlatformSDK))
            encoder.append(tag: 14, integer: UInt64(build.expectedVendorAPILevel))
            var overlays = CanonicalDigestEncoder(
                identityPathMap: encoder.identityPathMap)
            for overlay in build.sourceOverlays.sorted(by: {
                $0.relativeDestination < $1.relativeDestination
            }) {
                overlays.append(tag: 1, string: overlay.source.string)
                overlays.append(tag: 2, string: overlay.relativeDestination)
            }
            encoder.append(tag: 15, bytes: overlays.bytes)
            encoder.append(
                tag: 16,
                string: build.outputWorkspace.identity.key)
            encoder.append(
                tag: 17,
                integer: build.outputWorkspace.capacityBytes)
            encoder.append(
                tag: 18,
                string: build.compilerCacheWorkspace.identity.key)
            encoder.append(
                tag: 19,
                integer: build.compilerCacheWorkspace.capacityBytes)
        }
    }

    static let kind: ActionKind = "android-runtime.compile-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity { Identity(build: build) }

    var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .input(build.productSource)),
            ActionEffect(.read, scope: .input(build.source)),
            ActionEffect(.read, scope: .input(build.sourceProvenance)),
            ActionEffect(.read, scope: .input(build.containerImageID)),
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
                    access: .readWrite),
                ActionPersistentWorkspaceEffect(
                    workspace: build.compilerCacheWorkspace,
                    target: "/ccache",
                    access: .readWrite),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .androidX86_64(
                apiLevel: build.expectedPlatformSDK))
    }

    var environment: [String: String] { build.environment }

    func execute(in context: ActionContext) async throws {
        try await AOSPProductCompileWorkflow(
            build: build,
            context: context
        ).execute()
    }

    func validateOutputs(using files: ActionFileSystem) throws {
        let unsigned = build.artifactRoot.appending("unsigned")
        let name = "\(build.product)-target_files.zip"
        let archive = unsigned.appending(name)
        let checksum = unsigned.appending("\(name).sha256")
        guard try files.metadata(for: archive)?.type == .regular,
            try files.metadata(for: checksum)?.type == .regular
        else {
            throw AOSPProductCompileFailure.invalidOutput(
                "AOSP unsigned target-files output is missing")
        }
        let expected =
            "\(try files.digest(file: archive).hexadecimal)  \(name)\n"
        let recorded = String(decoding: try files.read(checksum), as: UTF8.self)
        guard recorded == expected else {
            throw AOSPProductCompileFailure.invalidOutput(
                "AOSP unsigned target-files checksum does not match")
        }
    }
}

private struct AOSPProductCompileWorkflow {
    let build: AOSPProductBuild
    let context: ActionContext

    func execute() async throws {
        guard build.buildJobs > 0,
            build.expectedPlatformSDK > 0,
            build.expectedVendorAPILevel > 0,
            build.variant == "user"
        else {
            throw failure(
                "AOSP production builds require positive concurrency/API "
                    + "levels and the user variant")
        }
        let sourceProvenance = try JSONDecoder().decode(
            AOSPCompileSourceProvenance.self,
            from: Data(try context.files.read(build.sourceProvenance)))
        guard sourceProvenance.status == "materialized" else {
            throw failure("AOSP source provenance is not materialized")
        }
        try context.files.createDirectory(build.artifactRoot)
        try assembleProductInput()

        let distribution = build.artifactRoot.appending("dist")
        let unsigned = build.artifactRoot.appending("unsigned")
        try context.files.remove(distribution)
        try context.files.remove(unsigned)
        for directory in [build.artifactRoot, distribution, unsigned] {
            try context.files.createDirectory(directory)
        }

        let environment = buildEnvironment()
        let result = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(build.artifactRoot, "/export")],
                readOnlyMounts: aospProductSourceMounts(build: build),
                persistentWorkspaceMounts: [
                    build.outputMount,
                    build.compilerCacheMount,
                ],
                command: [
                    "/src/build/soong/soong_ui.bash",
                    "--make-mode",
                    "-j\(build.buildJobs)",
                    "target-files-package",
                    "otatools",
                ],
                containerEnvironment: environment,
                output: .logged))
        try requireAOSPBuildSuccess(result.status)

        let destination = unsigned.appending(
            "\(build.product)-target_files.zip")
        let exportResult = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [(unsigned, "/export")],
                readOnlyMounts: [(build.source, "/src")],
                persistentWorkspaceMounts: [build.readOnlyOutputMount],
                command: [
                    "/bin/cp", "--preserve=timestamps",
                    "/src/out/target/product/\(build.product)/obj/PACKAGING/target_files_intermediates/\(build.product)-target_files.zip",
                    "/export/\(build.product)-target_files.zip",
                ],
                output: .combined(limit: 4 * 1_024 * 1_024)))
        try requireAOSPBuildSuccess(exportResult.status)
        let digest = try context.files.digest(file: destination).hexadecimal
        try context.files.write(
            Array("\(digest)  \(build.product)-target_files.zip\n".utf8),
            to: unsigned.appending(
                "\(build.product)-target_files.zip.sha256"))
    }

    private func buildEnvironment() -> [String: String] {
        aospProductContainerToolEnvironment().merging(
            [
                "TARGET_PRODUCT": build.product,
                "TARGET_BUILD_VARIANT": build.variant,
                "TARGET_RELEASE": build.release,
                "OUT_DIR": "out",
                "DIST_DIR": "/export/dist",
                "BUILD_NUMBER": build.buildNumber,
                "BUILD_DATETIME": String(build.buildTimestamp),
                "BUILD_USERNAME": "nucleus",
                "BUILD_HOSTNAME": "collider",
                "TZ": "UTC",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "USE_CCACHE": "1",
                "CCACHE_EXEC": "/usr/bin/ccache",
                "CCACHE_DIR": "/ccache",
                "CCACHE_MAXSIZE": "50G",
                "CCACHE_COMPILERCHECK": "content",
            ],
            uniquingKeysWith: { _, requested in requested })
    }

    private func assembleProductInput() throws {
        let candidate = build.artifactRoot.appending(".product-input-candidate")
        try context.files.remove(candidate)
        defer { try? context.files.remove(candidate) }
        try context.files.copyTree(from: build.productSource, to: candidate)
        for overlay in build.sourceOverlays {
            guard !overlay.relativeDestination.isEmpty,
                !overlay.relativeDestination.hasPrefix("/"),
                !overlay.relativeDestination.split(separator: "/").contains("..")
            else {
                throw failure(
                    "invalid AOSP product overlay destination "
                        + "'\(overlay.relativeDestination)'")
            }
            let destination = candidate.appending(overlay.relativeDestination)
            try context.files.createDirectory(destination.removingLastComponent())
            try context.files.copyTree(from: overlay.source, to: destination)
        }
        try context.files.remove(build.assembledProductSource)
        try context.files.move(from: candidate, to: build.assembledProductSource)
    }

    private func failure(_ message: String) -> AOSPProductCompileFailure {
        .invalidOutput(message)
    }
}

func requireAOSPBuildSuccess(_ status: Int32) throws {
    guard status == 0 else {
        throw AOSPProductCompileFailure.invalidOutput(
            "AOSP container build failed")
    }
}

private struct AOSPCompileSourceProvenance: Decodable {
    let status: String
}

private enum AOSPProductCompileFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
    }
}
