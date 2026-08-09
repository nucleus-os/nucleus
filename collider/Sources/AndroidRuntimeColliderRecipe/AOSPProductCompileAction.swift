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
                (3, build.repoLauncher),
                (4, build.sourceProvenance),
                (5, build.buildRoot),
                (6, build.ccacheDirectory),
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
        }
    }

    static let kind: ActionKind = "android-runtime.compile-aosp-product"

    let build: AOSPProductBuild

    var identity: Identity { Identity(build: build) }

    var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .input(build.productSource)),
            ActionEffect(.readWrite, scope: .checkout(build.source)),
            ActionEffect(.read, scope: .input(build.repoLauncher)),
            ActionEffect(.read, scope: .input(build.sourceProvenance)),
            ActionEffect(.read, scope: .input(build.containerImageID)),
            ActionEffect(.readWrite, scope: .scratch(build.buildRoot)),
            ActionEffect(.readWrite, scope: .scratch(build.ccacheDirectory)),
        ]
        for overlay in build.sourceOverlays {
            let effect = ActionEffect(.read, scope: .input(overlay.source))
            if !effects.contains(effect) { effects.append(effect) }
        }
        return ActionRequirements(
            effects: effects,
            lane: .hostExclusive,
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
        let manifest =
            try await captured(
                [
                    "manifest",
                    "--revision-as-HEAD",
                ],
                in: build.source) + "\n"
        guard
            ArtifactDigest.sha256(Data(manifest.utf8)).hexadecimal
                == sourceProvenance.resolvedManifestSHA256
        else {
            throw failure(
                "current AOSP project revisions do not match signed-build "
                    + "source provenance")
        }

        let productDigest = try aospProductDefinitionDigest(
            productSource: build.productSource,
            sourceOverlays: build.sourceOverlays,
            files: context.files)
        try stageProduct(digest: productDigest)
        let output = build.buildRoot.appending("out")
        let distribution = build.buildRoot.appending("dist")
        let unsigned = build.buildRoot.appending("unsigned")
        let signed = build.buildRoot.appending("signed")
        for directory in [
            build.buildRoot, build.ccacheDirectory, output, distribution,
            unsigned, signed,
        ] {
            try context.files.createDirectory(directory)
        }
        for endpoint in [".path_interposer_log", ".ninja_fifo"] {
            try context.files.remove(output.appending(endpoint))
        }
        try context.files.write(
            Array("max_size = 50G\n".utf8),
            to: build.ccacheDirectory.appending("ccache.conf"))
        try ensureContainerMountpoint(build.source.appending("out/nucleus"))
        try ensureContainerMountpoint(build.source.appending("out/nucleus-dist"))

        let environment = buildEnvironment()
        let writableMounts = [
            (output, "/src/out/nucleus"),
            (distribution, "/src/out/nucleus-dist"),
        ]
        let allWritableMounts =
            writableMounts + [
                (build.ccacheDirectory, "/src/out/nucleus/.ccache")
            ]
        let cleanResult = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: allWritableMounts,
                readOnlyMounts: [(build.source, "/src")],
                command: [
                    "/src/build/soong/soong_ui.bash",
                    "--make-mode",
                    "installclean",
                ],
                containerEnvironment: environment,
                output: .combined(limit: 4 * 1_024 * 1_024)))
        try requireAOSPBuildSuccess(cleanResult.status)

        let result = try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: allWritableMounts,
                readOnlyMounts: [(build.source, "/src")],
                command: [
                    "/src/build/soong/soong_ui.bash",
                    "--make-mode",
                    "-j\(build.buildJobs)",
                    "target-files-package",
                    "otatools",
                ],
                containerEnvironment: environment,
                output: .combined(limit: 4 * 1_024 * 1_024)))
        try requireAOSPBuildSuccess(result.status)

        let builtTargetFiles = try locateTargetFiles(under: output)
        let destination = unsigned.appending(
            "\(build.product)-target_files.zip")
        try context.files.copy(from: builtTargetFiles, to: destination)
        let digest = try context.files.digest(file: destination).hexadecimal
        try context.files.write(
            Array("\(digest)  \(build.product)-target_files.zip\n".utf8),
            to: unsigned.appending(
                "\(build.product)-target_files.zip.sha256"))
    }

    private func stageProduct(digest: ArtifactDigest) throws {
        let destination = build.source.appending(
            "device/nucleus/nucleus_x86_64")
        try context.files.createDirectory(destination.removingLastComponent())
        if try context.files.metadataWithoutFollowingSymlinks(
            for: destination.appending(".git")) != nil
        {
            throw failure("refusing to replace a Git checkout at \(destination)")
        }
        try synchronizeAOSPProductTree(
            from: build.productSource,
            to: destination,
            preservingAtRoot: [".nucleus-product-stage.json"],
            files: context.files)
        for overlay in build.sourceOverlays {
            guard !overlay.relativeDestination.isEmpty,
                !overlay.relativeDestination.hasPrefix("/"),
                !overlay.relativeDestination.split(separator: "/").contains("..")
            else {
                throw failure(
                    "invalid AOSP product overlay destination "
                        + "'\(overlay.relativeDestination)'")
            }
            try synchronizeAOSPProductTree(
                from: overlay.source,
                to: destination.appending(overlay.relativeDestination),
                files: context.files)
        }
        let metadata = AOSPProductStage(
            source: build.productSource.string,
            sha256: digest.hexadecimal)
        try context.files.write(
            Array(try JSONEncoder().encode(metadata)),
            to: destination.appending(".nucleus-product-stage.json"))
    }

    private func ensureContainerMountpoint(_ path: FilePath) throws {
        if let metadata = try context.files.metadataWithoutFollowingSymlinks(for: path),
            metadata.type != .directory
        {
            try context.files.remove(path)
        }
        try context.files.createDirectory(path)
    }

    private func buildEnvironment() -> [String: String] {
        aospProductContainerToolEnvironment().merging(
            [
                "TARGET_PRODUCT": build.product,
                "TARGET_BUILD_VARIANT": build.variant,
                "TARGET_RELEASE": build.release,
                "OUT_DIR": "out/nucleus",
                "DIST_DIR": "out/nucleus-dist",
                "BUILD_NUMBER": build.buildNumber,
                "BUILD_DATETIME": String(build.buildTimestamp),
                "BUILD_USERNAME": "nucleus",
                "BUILD_HOSTNAME": "collider",
                "TZ": "UTC",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "USE_CCACHE": "1",
                "CCACHE_EXEC": "/usr/bin/ccache",
                "CCACHE_DIR": "/src/out/nucleus/.ccache",
                "CCACHE_COMPILERCHECK": "content",
            ],
            uniquingKeysWith: { _, requested in requested })
    }

    private func locateTargetFiles(under root: FilePath) throws -> FilePath {
        let expected = "\(build.product)-target_files.zip"
        let matches = try context.files.listRecursively(root)
            .filter {
                $0.metadata.type == .regular
                    && $0.path.lastComponent?.string == expected
            }
            .map(\.path)
            .sorted { $0.string < $1.string }
        guard matches.count == 1 else {
            throw failure(
                "expected one \(expected) under \(root); found "
                    + (matches.isEmpty
                        ? "none"
                        : matches.map(\.string).joined(separator: ", ")))
        }
        return matches[0]
    }

    private func captured(
        _ arguments: [String],
        in directory: FilePath
    ) async throws -> String {
        let result = try await command(
            arguments,
            in: directory,
            output: .captured(limit: 32 * 1_024 * 1_024))
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "\(arguments.first ?? "command") failed")
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func command(
        _ arguments: [String],
        in directory: FilePath,
        output: CommandSpec.Output
    ) async throws -> CommandResult {
        precondition(directory == build.source)
        guard let launcherName = build.repoLauncher.lastComponent?.string else {
            throw failure("Repo launcher path has no file name")
        }
        return try await context.containers.execute(
            aospProductOCIExecution(
                build: build,
                writableMounts: [],
                readOnlyMounts: [
                    (build.source, "/src"),
                    (build.repoLauncher.removingLastComponent(), "/repo"),
                ],
                command: ["/usr/bin/python3", "/repo/\(launcherName)"] + arguments,
                output: output))
    }

    private func failure(_ message: String) -> AOSPProductCompileFailure {
        .invalidOutput(message)
    }
}

func synchronizeAOSPProductTree(
    from source: FilePath,
    to destination: FilePath,
    preservingAtRoot preservedNames: Set<String> = [],
    files: ActionFileSystem
) throws {
    guard
        try files.metadataWithoutFollowingSymlinks(for: source)?.type
            == .directory
    else {
        throw AOSPProductCompileFailure.invalidOutput(
            "AOSP product source is not a directory: \(source)")
    }
    if let destinationMetadata = try files.metadataWithoutFollowingSymlinks(
        for: destination),
        destinationMetadata.type != .directory
    {
        try files.remove(destination)
    }
    try files.createDirectory(destination)

    let sourceEntries = Dictionary(
        uniqueKeysWithValues: try files.listRecursively(source).map {
            ($0.relativePath, $0)
        })
    let destinationEntries = Dictionary(
        uniqueKeysWithValues: try files.listRecursively(destination).map {
            ($0.relativePath, $0)
        })
    let stale = destinationEntries.keys.filter { relativePath in
        sourceEntries[relativePath] == nil
            && !(preservedNames.contains(relativePath)
                && !relativePath.contains("/"))
    }.sorted { pathDepth($0) > pathDepth($1) }
    for relativePath in stale {
        try files.remove(destination.appending(relativePath))
    }

    for relativePath in sourceEntries.keys.sorted(by: {
        pathDepth($0) < pathDepth($1)
            || (pathDepth($0) == pathDepth($1) && $0 < $1)
    }) {
        guard let sourceEntry = sourceEntries[relativePath] else { continue }
        let sourcePath = sourceEntry.path
        let destinationPath = destination.appending(relativePath)
        let destinationMetadata = try files.metadataWithoutFollowingSymlinks(
            for: destinationPath)
        switch sourceEntry.metadata.type {
        case .directory:
            if let destinationMetadata, destinationMetadata.type != .directory {
                try files.remove(destinationPath)
            }
            try files.createDirectory(destinationPath)
        case .regular:
            var unchanged = false
            if destinationMetadata?.type == .regular,
                destinationMetadata?.ownerExecutable
                    == sourceEntry.metadata.ownerExecutable
            {
                unchanged = try files.contentsEqual(
                    at: sourcePath,
                    and: destinationPath)
            }
            if !unchanged {
                if let destinationMetadata, destinationMetadata.type != .regular {
                    try files.remove(destinationPath)
                }
                try files.copy(from: sourcePath, to: destinationPath)
            }
        case .symbolicLink:
            let sourceTarget = try files.readSymbolicLink(sourcePath)
            let destinationTarget =
                destinationMetadata?.type == .symbolicLink
                ? try files.readSymbolicLink(destinationPath)
                : nil
            if sourceTarget != destinationTarget {
                if destinationMetadata != nil { try files.remove(destinationPath) }
                try files.replaceSymlink(at: destinationPath, target: sourceTarget)
            }
        case .other:
            throw AOSPProductCompileFailure.invalidOutput(
                "AOSP product source contains an unsupported entry: \(sourcePath)")
        }
    }
}

func requireAOSPBuildSuccess(_ status: Int32) throws {
    guard status == 0 else {
        throw AOSPProductCompileFailure.invalidOutput(
            "AOSP container build failed")
    }
}

private func pathDepth(_ path: String) -> Int {
    path.split(separator: "/").count
}

private struct AOSPCompileSourceProvenance: Decodable {
    let status: String
    let resolvedManifestSHA256: String
}

private struct AOSPProductStage: Codable {
    let source: String
    let sha256: String
}

private enum AOSPProductCompileFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
    }
}
