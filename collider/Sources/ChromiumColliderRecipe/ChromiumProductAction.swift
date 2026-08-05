import ColliderCore
import Foundation
import SystemPackage

package struct BuildChromiumProductAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let build: ChromiumProductBuild

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: build.product.rawValue)
            encoder.append(tag: 2, string: build.sourceRoot.string)
            encoder.append(tag: 3, string: build.output.string)
            encoder.append(tag: 4, string: build.depotTools.string)
            encoder.append(tag: 5, string: build.containerImageID.string)
            encoder.append(tag: 6, string: build.gnArguments ?? "")
            var targets = CanonicalDigestEncoder(
                identityPathMap: encoder.identityPathMap)
            for target in build.targets {
                targets.append(tag: 1, string: target)
            }
            encoder.append(tag: 7, bytes: targets.bytes)
            encoder.append(tag: 8, integer: UInt64(build.jobs))
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
                ActionEffect(.read, scope: .input(build.depotTools)),
                ActionEffect(.read, scope: .input(build.containerImageID)),
                ActionEffect(.readWrite, scope: .scratch(inputRoot)),
                ActionEffect(.readWrite, scope: .scratch(build.output)),
                ActionEffect(.readWrite, scope: .scratch(temporaryDirectory)),
            ],
            resources: ActionResourceRequest(
                cpuCount: OCIResourceLimits.build.cpuCount,
                memoryBytes: OCIResourceLimits.build.memoryBytes,
                exclusive: true),
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxX86_64)
    }

    package func execute(in context: ActionContext) async throws {
        let sourceManifest = build.sourceRoot.appending(
            "source-provenance.json")
        guard try context.files.metadata(for: sourceManifest)?.type == .regular
        else {
            throw failure(
                "Chromium source manifest is missing: \(sourceManifest)")
        }
        let commandEnvironment = chromiumEnvironment
        let gnArguments = try stagedGNArguments(files: context.files)
        try await context.containers.run(
            containerExecution(command: ["configure", gnArguments]))

        let expected = build.output.appending(
            ".nucleus-expected-build.json")
        let built = build.output.appending(".nucleus-built-build.json")
        let manifest = try await buildManifest(
            sourceManifest: sourceManifest,
            environment: commandEnvironment,
            context: context)
        try context.files.write(try encodedJSON(manifest), to: expected)
        try await context.containers.run(
            containerExecution(
                command: ["build", String(build.jobs)] + build.targets))
        try context.files.copy(from: expected, to: built)

        let verification = try await buildManifest(
            sourceManifest: sourceManifest,
            environment: commandEnvironment,
            context: context)
        let recorded = try JSONDecoder().decode(
            ChromiumBuildManifest.self,
            from: Data(context.files.read(built)))
        guard recorded == verification else {
            throw failure(
                "Chromium build metadata changed during the build: \(built)")
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        let built = build.output.appending(".nucleus-built-build.json")
        guard try files.metadata(for: built)?.type == .regular else {
            throw failure("Chromium build manifest is missing: \(built)")
        }
        _ = try JSONDecoder().decode(
            ChromiumBuildManifest.self,
            from: Data(files.read(built)))
    }

    private var chromium: FilePath {
        build.sourceRoot.appending("chromium/src")
    }

    private var inputRoot: FilePath {
        build.output.removingLastComponent().appending(".inputs")
    }

    private var temporaryDirectory: FilePath {
        build.output.removingLastComponent().appending(".temporary")
    }

    private var chromiumEnvironment: [String: String] {
        var value = build.environment
        value["PATH"] =
            build.depotTools.string + ":"
            + (value["PATH"] ?? "/usr/bin:/bin")
        value["DEPOT_TOOLS_UPDATE"] = "0"
        return value
    }

    private func stagedGNArguments(files: ActionFileSystem) throws -> String {
        try files.createDirectory(inputRoot)
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
        let destination = inputRoot.appending("chrome.profdata")
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
            artifactTarget: .linuxX86_64,
            imageID: build.containerImageID,
            hostname: "chromium-build",
            workingDirectory: "/source/chromium/src",
            hostWorkingDirectory: chromium,
            mounts: [
                OCIMount(
                    source: build.sourceRoot,
                    target: "/source",
                    access: .readOnly),
                OCIMount(
                    source: build.depotTools,
                    target: "/depot_tools",
                    access: .readOnly),
                OCIMount(
                    source: inputRoot,
                    target: "/inputs",
                    access: .readOnly),
                OCIMount(
                    source: build.output,
                    target: "/build",
                    access: .readWrite),
            ],
            temporaryDirectory: temporaryDirectory,
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            intelBinaryTranslationPolicy: .required,
            resourceLimits: .build,
            containerEnvironment: [
                "DEPOT_TOOLS_UPDATE": "0",
                "HOME": "/tmp/nucleus-home",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PYTHONDONTWRITEBYTECODE": "1",
                "TZ": "UTC",
            ],
            command: command,
            environment: build.environment,
            output: output)
    }

    private func buildManifest(
        sourceManifest: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws -> ChromiumBuildManifest {
        let sourceObject = try JSONSerialization.jsonObject(
            with: Data(context.files.read(sourceManifest)))
        guard let source = sourceObject as? [String: Any],
            let sourceID = source["sourceID"] as? String
                ?? source["source_id"] as? String
        else {
            throw failure(
                "Chromium source manifest has no source identity: "
                    + sourceManifest.string)
        }
        let clang = chromium.appending(
            "third_party/llvm-build/Release+Asserts/bin/clang")
        guard try context.files.metadata(for: clang)?.type == .regular else {
            throw failure("Chromium clang is missing: \(clang)")
        }
        let versionResult = try await context.containers.run(
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
        let args = build.output.appending("args.gn")
        let normalizedArguments = try text(at: args, files: context.files)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .sorted()
        let identity = ChromiumBuildIdentity(
            product: build.product.rawValue,
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
                    "v8/tools/builtins-pgo/profiles/x64.profile"),
                files: context.files))
        let digest = ArtifactDigest.sha256(try encodedJSON(identity))
        return ChromiumBuildManifest(
            identity: identity,
            buildID: String(digest.hexadecimal.prefix(24)))
    }

    private func pgoProfile(
        files: ActionFileSystem
    ) throws -> ChromiumProfileIdentity? {
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
