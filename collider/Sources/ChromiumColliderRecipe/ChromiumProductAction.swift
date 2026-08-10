import ColliderCore
import Foundation
import SystemPackage

package struct BuildChromiumProductAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let build: ChromiumProductBuild

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: build.product.rawValue)
            encoder.append(tag: 2, string: build.target.architecture.rawValue)
            encoder.append(tag: 3, string: build.sourceRoot.string)
            encoder.append(tag: 4, string: build.buildManifest.string)
            encoder.append(tag: 5, string: build.containerImageID.string)
            encoder.append(tag: 6, string: build.gnArguments ?? "")
            var targets = CanonicalDigestEncoder(
                identityPathMap: encoder.identityPathMap)
            for target in build.targets {
                targets.append(tag: 1, string: target)
            }
            encoder.append(tag: 7, bytes: targets.bytes)
            encoder.append(tag: 8, integer: UInt64(build.jobs))
            encoder.append(tag: 9, string: build.outputWorkspace.identity.key)
            encoder.append(tag: 10, integer: build.outputWorkspace.capacityBytes)
            encoder.append(
                tag: 11,
                string: build.compilerCacheWorkspace.identity.key)
            encoder.append(
                tag: 12,
                integer: build.compilerCacheWorkspace.capacityBytes)
            encoder.append(tag: 13, string: build.sourceWorkspace.identity.key)
            encoder.append(tag: 14, integer: build.sourceWorkspace.capacityBytes)
        }
    }

    package static let kind: ActionKind = "browser.build-product"

    let build: ChromiumProductBuild

    package init(build: ChromiumProductBuild) {
        self.build = build
    }

    package var identity: Identity { Identity(build: build) }
    package var environment: [String: String] { build.environment }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(build.sourceRoot)),
                ActionEffect(.read, scope: .input(build.containerImageID)),
                ActionEffect(.readWrite, scope: .scratch(build.inputRoot)),
                ActionEffect(.readWrite, scope: .scratch(build.buildManifest)),
            ],
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: build.sourceWorkspace,
                    target: "/source",
                    access: .readWrite),
                ActionPersistentWorkspaceEffect(
                    workspace: build.outputWorkspace,
                    target: "/build",
                    access: .readWrite),
                ActionPersistentWorkspaceEffect(
                    workspace: build.compilerCacheWorkspace,
                    target: "/ccache",
                    access: .readWrite),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: build.target.artifactTarget)
    }

    package func execute(in context: ActionContext) async throws {
        let sourceManifest = build.sourceRoot.appending(
            "source-provenance.json")
        guard try context.files.metadata(for: sourceManifest)?.type == .regular
        else {
            throw failure(
                "Chromium source manifest is missing: \(sourceManifest)")
        }
        let sourceID = try sourceID(
            in: sourceManifest,
            files: context.files)
        try await context.containers.run(
            sourceMaterializationExecution(sourceID: sourceID))
        let gnArguments = try stagedGNArguments(files: context.files)
        try await context.containers.run(
            containerExecution(command: ["configure", gnArguments]))

        let manifest = try await buildManifest(
            sourceManifest: sourceManifest,
            context: context)
        try await context.containers.run(
            containerExecution(
                command: ["build", String(build.jobs)] + build.targets))
        let verification = try await buildManifest(
            sourceManifest: sourceManifest,
            context: context)
        guard manifest == verification else {
            throw failure(
                "Chromium build metadata changed during the build")
        }
        try context.files.write(
            try encodedJSON(manifest),
            to: build.buildManifest)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        guard try files.metadata(for: build.buildManifest)?.type == .regular else {
            throw failure(
                "Chromium build manifest is missing: \(build.buildManifest)")
        }
        _ = try JSONDecoder().decode(
            ChromiumBuildManifest.self,
            from: Data(files.read(build.buildManifest)))
    }

    private var chromium: FilePath {
        build.sourceRoot.appending("chromium/src")
    }

    private var chromiumEnvironment: [String: String] {
        var value = build.environment
        value["CCACHE_DIR"] = "/ccache"
        value["CCACHE_MAXSIZE"] = "30G"
        value["CCACHE_COMPILERCHECK"] = "content"
        return value
    }

    private func stagedGNArguments(files: ActionFileSystem) throws -> String {
        try files.createDirectory(build.inputRoot)
        guard build.target.architecture == .x86_64 else {
            return build.gnArguments ?? ""
        }
        let descriptor = chromium.appending("chrome/build/linux.pgo.txt")
        guard try files.metadata(for: descriptor)?.type == .regular else {
            return build.gnArguments ?? ""
        }
        let name = try text(at: descriptor, files: files)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw failure("Chromium PGO descriptor is invalid: \(descriptor)")
        }
        let source = chromium.appending("chrome/build/pgo_profiles/\(name)")
        guard try files.metadata(for: source)?.type == .regular else {
            throw failure("Chromium PGO profile is missing: \(source)")
        }
        let destination = build.inputRoot.appending("chrome.profdata")
        let sourceDigest = try files.digest(file: source)
        let destinationDigest = try? files.digest(file: destination)
        if destinationDigest != sourceDigest {
            try files.copy(from: source, to: destination)
        }
        return (build.gnArguments ?? "")
            + #" pgo_data_path="/inputs/chrome.profdata""#
    }

    private func containerExecution(
        command: [String],
        output: CommandSpec.Output = .logged
    ) -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: build.target.artifactTarget,
            imageID: build.containerImageID,
            hostname: "chromium-build",
            workingDirectory: "/source/chromium/src",
            hostWorkingDirectory: chromium,
            mounts: [
                OCIMount(
                    source: build.inputRoot,
                    target: "/inputs",
                    access: .readOnly)
            ],
            persistentWorkspaceMounts: [
                build.sourceMount,
                build.outputMount,
                build.compilerCacheMount,
            ],
            temporaryDirectory: nil,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            intelBinaryTranslationPolicy: .required,
            resourceLimits: .parallelBuild,
            containerEnvironment: [
                "DEPOT_TOOLS_UPDATE": "0",
                "HOME": "/tmp/nucleus-home",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1",
                "TZ": "UTC",
            ],
            command: command,
            environment: chromiumEnvironment,
            output: output)
    }

    private func sourceMaterializationExecution(sourceID: String) -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: build.target.artifactTarget,
            imageID: build.containerImageID,
            hostname: "chromium-source-materialization",
            workingDirectory: "/",
            hostWorkingDirectory: build.sourceRoot,
            mounts: [
                OCIMount(
                    source: build.sourceRoot,
                    target: "/host-source",
                    access: .readOnly)
            ],
            persistentWorkspaceMounts: [build.writableSourceMount],
            temporaryDirectory: nil,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            intelBinaryTranslationPolicy: .disabled,
            resourceLimits: chromiumToolResourceLimits,
            containerEnvironment: [
                "HOME": "/tmp/nucleus-home",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "TZ": "UTC",
            ],
            command: ["materialize-source", sourceID],
            environment: build.environment,
            output: .logged)
    }

    private func buildManifest(
        sourceManifest: FilePath,
        context: ActionContext
    ) async throws -> ChromiumBuildManifest {
        let sourceID = try sourceID(in: sourceManifest, files: context.files)
        let clang = chromium.appending(
            "\(chromiumLinuxClangRoot)/bin/clang")
        guard try context.files.metadata(for: clang)?.type == .regular else {
            throw failure("Chromium clang is missing: \(clang)")
        }
        let versionResult = try await context.containers.execute(
            containerExecution(
                command: ["clang-version"],
                output: .captured(limit: 64 * 1_024)))
        guard versionResult.status == 0,
            let version = versionResult.standardOutput.split(
                separator: "\n"
            ).first
        else {
            throw failure("could not identify Chromium clang: \(clang)")
        }
        let argumentsResult = try await context.containers.execute(
            containerExecution(
                command: ["gn-args"],
                output: .captured(limit: 4 * 1_024 * 1_024)))
        guard argumentsResult.status == 0 else {
            throw failure("could not read resolved Chromium GN arguments")
        }
        let normalizedArguments = argumentsResult.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .sorted()
        let identity = ChromiumBuildIdentity(
            product: build.product.rawValue,
            architecture: build.target.architecture.rawValue,
            sourceID: sourceID,
            sourceManifestSHA256: try context.files.digest(
                file: sourceManifest
            ).description,
            gnArguments: normalizedArguments,
            clangVersion: String(version),
            clangSHA256: try context.files.digest(file: clang).description,
            pgo: try pgoProfile(files: context.files),
            v8BuiltinsPGO: try optionalProfile(
                chromium.appending(
                    "v8/tools/builtins-pgo/profiles/"
                        + chromiumV8BuiltinsPGOProfile),
                files: context.files))
        let digest = ArtifactDigest.sha256(try encodedJSON(identity))
        return ChromiumBuildManifest(
            identity: identity,
            buildID: String(digest.hexadecimal.prefix(24)))
    }

    private func sourceID(
        in manifest: FilePath,
        files: ActionFileSystem
    ) throws -> String {
        let sourceObject = try JSONSerialization.jsonObject(
            with: Data(files.read(manifest)))
        guard let source = sourceObject as? [String: Any],
            let sourceID = source["sourceID"] as? String
                ?? source["source_id"] as? String
        else {
            throw failure(
                "Chromium source manifest has no source identity: "
                    + manifest.string)
        }
        return sourceID
    }

    private func pgoProfile(
        files: ActionFileSystem
    ) throws -> ChromiumProfileIdentity? {
        guard build.target.architecture == .x86_64 else { return nil }
        let descriptor = chromium.appending("chrome/build/linux.pgo.txt")
        guard try files.metadata(for: descriptor)?.type == .regular else {
            return nil
        }
        let name = try text(at: descriptor, files: files)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return try optionalProfile(
            chromium.appending("chrome/build/pgo_profiles/\(name)"),
            files: files)
    }

    private func optionalProfile(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws -> ChromiumProfileIdentity? {
        guard try files.metadata(for: path)?.type == .regular else { return nil }
        return ChromiumProfileIdentity(
            name: path.lastComponent?.string ?? "",
            sha256: try files.digest(file: path).description)
    }

    private func text(
        at path: FilePath,
        files: ActionFileSystem
    ) throws -> String {
        guard let value = String(bytes: try files.read(path), encoding: .utf8)
        else {
            throw failure("file is not valid UTF-8: \(path)")
        }
        return value
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }

    private func failure(_ message: String) -> ChromiumProductActionFailure {
        .invalidOutput(message)
    }
}

private struct ChromiumProfileIdentity: Codable, Equatable {
    let name: String
    let sha256: String
}

private struct ChromiumBuildIdentity: Codable, Equatable {
    let product: String
    let architecture: String
    let sourceID: String
    let sourceManifestSHA256: String
    let gnArguments: [String]
    let clangVersion: String
    let clangSHA256: String
    let pgo: ChromiumProfileIdentity?
    let v8BuiltinsPGO: ChromiumProfileIdentity?
}

private struct ChromiumBuildManifest: Codable, Equatable {
    let identity: ChromiumBuildIdentity
    let buildID: String
}

private enum ChromiumProductActionFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
    }
}
