import ColliderCore
import Foundation
import SystemPackage

package struct BuildChromiumProductAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let build: ChromiumProductBuild

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(build.product.rawValue)
            encoder.append(build.target.architecture.rawValue)
            encoder.append(path: build.sourceRoot)
            encoder.append(path: build.buildManifest)
            encoder.append(
                nested: OCIMountedEntrypointActionIdentity(build.entrypoint))
            encoder.appendOptional(build.gnArguments) { $0.append($1) }
            encoder.appendSequence(build.targets) { $0.append($1) }
            encoder.append(UInt64(build.jobs))
            encoder.append(build.outputWorkspace.identity.key)
            encoder.append(build.outputWorkspace.capacityBytes)
            encoder.append(build.compilerCacheWorkspace.identity.key)
            encoder.append(build.compilerCacheWorkspace.capacityBytes)
            encoder.append(build.sourceWorkspace.identity.key)
            encoder.append(build.sourceWorkspace.capacityBytes)
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
                ActionEffect(.read, scope: .input(build.entrypoint.image.path)),
                build.entrypoint.effect,
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
            containerExecution(
                command: [
                    "build", sourceID, gnArguments, String(build.jobs),
                ] + build.targets))
        let manifest = try buildManifest(
            sourceID: sourceID,
            gnArguments: gnArguments,
            sourceManifest: sourceManifest,
            context: context)
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
        build.environment.merging(chromiumCompilerCacheEnvironment) {
            _, required in required
        }
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
            imageID: build.entrypoint.image.path,
            hostname: "chromium-build",
            workingDirectory: "/source/chromium/src",
            hostWorkingDirectory: chromium,
            mounts: [
                build.entrypoint.mount,
                OCIMount(
                    source: build.inputRoot,
                    target: "/inputs",
                    access: .readOnly),
            ],
            persistentWorkspaceMounts: [
                build.sourceMount,
                build.outputMount,
                build.compilerCacheMount,
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            executableRequirements: chromiumBuildExecutableRequirements,
            resourceLimits: .parallelBuild,
            containerEnvironment: [
                "DEPOT_TOOLS_UPDATE": "0",
                "HOME": "/tmp/nucleus-home",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1",
                "TZ": "UTC",
            ],
            imageEntrypointOverride: build.entrypoint.containerPath,
            command: command,
            environment: chromiumEnvironment,
            output: output)
    }

    private func sourceMaterializationExecution(sourceID: String) -> OCIExecution {
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: build.target.artifactTarget,
            imageID: build.entrypoint.image.path,
            hostname: "chromium-source-materialization",
            workingDirectory: "/",
            hostWorkingDirectory: build.sourceRoot,
            mounts: [
                build.entrypoint.mount,
                OCIMount(
                    source: build.sourceRoot,
                    target: "/host-source",
                    access: .readOnly),
            ],
            persistentWorkspaceMounts: [build.writableSourceMount],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: chromiumToolResourceLimits,
            containerEnvironment: [
                "HOME": "/tmp/nucleus-home",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "TZ": "UTC",
            ],
            imageEntrypointOverride: build.entrypoint.containerPath,
            command: ["materialize-source", sourceID],
            environment: build.environment,
            output: .logged)
    }

    private func buildManifest(
        sourceID: String,
        gnArguments: String,
        sourceManifest: FilePath,
        context: ActionContext
    ) throws -> ChromiumBuildManifest {
        let clang = chromium.appending(
            "\(chromiumLinuxClangRoot)/bin/clang")
        guard try context.files.metadata(for: clang)?.type == .regular else {
            throw failure("Chromium clang is missing: \(clang)")
        }
        let identity = ChromiumBuildIdentity(
            product: build.product.rawValue,
            architecture: build.target.architecture.rawValue,
            sourceID: sourceID,
            sourceManifestSHA256: try context.files.digest(
                file: sourceManifest
            ).description,
            gnArguments: gnArguments,
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

private struct ChromiumProfileIdentity: Codable {
    let name: String
    let sha256: String
}

private struct ChromiumBuildIdentity: Codable {
    let product: String
    let architecture: String
    let sourceID: String
    let sourceManifestSHA256: String
    let gnArguments: String
    let clangSHA256: String
    let pgo: ChromiumProfileIdentity?
    let v8BuiltinsPGO: ChromiumProfileIdentity?
}

private struct ChromiumBuildManifest: Codable {
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
