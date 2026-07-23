import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func buildChromiumProduct(
        _ build: ChromiumProductBuild,
        stage: TaskID
    ) async throws {
        let chromium = build.sourceRoot.appending("chromium/src")
        let sourceManifest = build.sourceRoot.appending(
            "nucleus-source-manifest.json")
        guard chromiumRegularFile(sourceManifest) else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source manifest is missing: \(sourceManifest)")
        }
        var environment = build.environment
        environment["PATH"] = build.depotTools.string + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["DEPOT_TOOLS_UPDATE"] = "0"
        let gn = chromium.appending("buildtools/linux64/gn")
        var gnArguments = ["gen", build.output.string]
        if let arguments = build.gnArguments {
            gnArguments.append("--args=\(arguments)")
        }
        try await checkedChromiumCommand(
            .path(gn),
            gnArguments,
            directory: chromium,
            environment: environment,
            stage: stage)
        let expected = build.output.appending(
            ".nucleus-expected-build.json")
        let built = build.output.appending(".nucleus-built-build.json")
        let manifest = try await chromiumBuildManifest(
            build,
            sourceManifest: sourceManifest,
            chromium: chromium,
            environment: environment,
            stage: stage)
        try DurableFile.writeJSON(manifest, to: expected)
        try await checkedChromiumCommand(
            .path(build.depotTools.appending("autoninja")),
            [
                "-j", String(build.jobs),
                "-C", build.output.string,
            ] + build.targets,
            directory: chromium,
            environment: environment,
            stage: stage)
        try DurableFile.copy(from: expected, to: built)
        let verification = try await chromiumBuildManifest(
            build,
            sourceManifest: sourceManifest,
            chromium: chromium,
            environment: environment,
            stage: stage)
        let recorded = try JSONDecoder().decode(
            ChromiumBuildManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: built.string)))
        guard recorded == verification else {
            throw RuntimeFailure.invalidOutput(
                "Chromium build metadata changed during the build: \(built)")
        }
    }

    private func chromiumBuildManifest(
        _ build: ChromiumProductBuild,
        sourceManifest: FilePath,
        chromium: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> ChromiumBuildManifest {
        let sourceObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(
                fileURLWithPath: sourceManifest.string)))
        guard let source = sourceObject as? [String: Any],
              let sourceID =
                source["sourceID"] as? String
                ?? source["source_id"] as? String
        else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source manifest has no source identity: "
                    + sourceManifest.string)
        }
        let clang = chromium.appending(
            "third_party/llvm-build/Release+Asserts/bin/clang")
        guard chromiumRegularFile(clang) else {
            throw RuntimeFailure.invalidOutput(
                "Chromium clang is missing: \(clang)")
        }
        let versionResult = try await execute(
            CommandSpec(
                executable: .path(clang),
                arguments: ["--version"],
                workingDirectory: chromium,
                environment: environment,
                output: .captured(limit: 64 * 1_024)),
            stage: stage)
        guard versionResult.status == 0,
              let version = versionResult.standardOutput.split(
                separator: "\n").first
        else {
            throw RuntimeFailure.invalidOutput(
                "could not identify Chromium clang: \(clang)")
        }
        let args = build.output.appending("args.gn")
        let normalizedArguments = try String(
            contentsOf: URL(fileURLWithPath: args.string),
            encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .sorted()
        let pgo = try chromiumPGOProfile(chromium)
        let v8 = try chromiumOptionalProfile(
            chromium.appending(
                "v8/tools/builtins-pgo/profiles/x64.profile"))
        let identity = ChromiumBuildIdentity(
            schema: 1,
            product: build.product.rawValue,
            sourceID: sourceID,
            sourceManifestSHA256:
                try ArtifactHasher.digest(file: sourceManifest).description,
            gnArguments: normalizedArguments,
            clangVersion: String(version),
            clangSHA256: try ArtifactHasher.digest(file: clang).description,
            pgo: pgo,
            v8BuiltinsPGO: v8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = ArtifactHasher.digest(bytes: try encoder.encode(identity))
        let buildID = digest.bytes.prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        return ChromiumBuildManifest(identity: identity, buildID: buildID)
    }

    private func chromiumPGOProfile(
        _ chromium: FilePath
    ) throws -> ChromiumProfileIdentity? {
        let descriptor = chromium.appending("chrome/build/linux.pgo.txt")
        guard chromiumRegularFile(descriptor) else { return nil }
        let name = try String(
            contentsOf: URL(fileURLWithPath: descriptor.string),
            encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return try chromiumOptionalProfile(
            chromium.appending("chrome/build/pgo_profiles/\(name)"))
    }

    private func chromiumOptionalProfile(
        _ path: FilePath
    ) throws -> ChromiumProfileIdentity? {
        guard chromiumRegularFile(path) else { return nil }
        return ChromiumProfileIdentity(
            name: path.lastComponent?.string ?? "",
            sha256: try ArtifactHasher.digest(file: path).description)
    }

    private func checkedChromiumCommand(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
    }
}

private struct ChromiumProfileIdentity: Codable, Equatable {
    let name: String
    let sha256: String
}

private struct ChromiumBuildIdentity: Codable, Equatable {
    let schema: UInt32
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

private func chromiumRegularFile(_ path: FilePath) -> Bool {
    guard let metadata = try? path.stat(followTargetSymlink: true) else {
        return false
    }
    return metadata.type == .regular
}
