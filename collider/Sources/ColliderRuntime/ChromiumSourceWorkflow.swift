import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareChromiumSource(
        _ preparation: ChromiumSourcePreparation,
        stage: TaskID
    ) async throws {
        let manifest = preparation.sourceRoot.appending(
            "nucleus-source-manifest.json")
        if FileManager.default.fileExists(atPath: manifest.string) {
            try await validateChromiumSource(preparation, manifest: manifest)
            try DirectoryLifecycle.activate(
                target: preparation.sourceID,
                link: preparation.current)
            return
        }
        guard !FileManager.default.fileExists(
            atPath: preparation.sourceRoot.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source generation exists without metadata: "
                    + preparation.sourceRoot.string)
        }
        try FileManager.default.createDirectory(
            atPath: preparation.sourceGenerations.string,
            withIntermediateDirectories: true)
        let candidate = preparation.sourceGenerations.appending(
            ".\(preparation.sourceID).\(UUID().uuidString).preparing")
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(atPath: candidate.string)
            }
        }
        let automate = candidate.appending("automate-git.py")
        try FileManager.default.copyItem(
            atPath: preparation.automateScript.string,
            toPath: automate.string)
        var environment = preparation.environment
        environment["PATH"] = preparation.depotTools.string + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["DEPOT_TOOLS_UPDATE"] = "0"
        environment["CEF_USE_GN"] = "1"

        try await checked(
            .path(automate),
            [
                "--download-dir=\(candidate)",
                "--depot-tools-dir=\(preparation.depotTools)",
                "--branch=\(preparation.cefBranch)",
                "--checkout=\(preparation.cefCheckout)",
                "--x64-build",
                "--no-debug-build",
                "--no-chromium-history",
                "--with-pgo-profiles",
                "--build-target=cefsimple",
                "--force-config",
                "--no-build",
                "--no-distrib",
            ],
            in: candidate,
            environment: environment,
            stage: stage)
        let chromium = candidate.appending("chromium/src")
        try await ensureChromiumProfiles(
            chromium: chromium,
            depotTools: preparation.depotTools,
            environment: environment,
            stage: stage)
        try await checked(
            .named("python3"),
            ["tools/gclient_hook.py"],
            in: chromium.appending("cef"),
            environment: environment,
            stage: stage)

        for stack in preparation.patchStacks {
            let repository = remap(
                stack.repository,
                from: preparation.sourceRoot,
                to: candidate)
            let patchNames = try FileManager.default.contentsOfDirectory(
                atPath: stack.directory.string)
                .filter { $0.hasSuffix(".patch") }
                .sorted()
            guard !patchNames.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "Chromium patch stack is empty: \(stack.directory)")
            }
            for name in patchNames {
                try await applyChromiumPatch(
                    repository: repository,
                    patch: stack.directory.appending(name),
                    environment: environment,
                    stage: stage)
            }
        }
        try await checked(
            .named("python3"),
            ["cef/tools/translator.py", "--root-dir", "cef"],
            in: chromium,
            environment: environment,
            stage: stage)
        try await checked(
            .named("python3"),
            ["tools/version_manager.py", "-c", "--force-update"],
            in: chromium.appending("cef"),
            environment: environment,
            stage: stage)
        try await checked(
            .named("python3"),
            ["tools/version_manager.py", "-c"],
            in: chromium.appending("cef"),
            environment: environment,
            stage: stage)
        for repository in [
            chromium,
            chromium.appending("cef"),
            chromium.appending("third_party/dawn"),
        ] {
            try await checked(
                .named("git"),
                ["-C", repository.string, "diff", "--check"],
                in: repository,
                environment: environment,
                stage: stage)
        }

        let candidatePreparation = ChromiumSourcePreparation(
            workspace: preparation.workspace,
            sourceID: preparation.sourceID,
            sourceRoot: candidate,
            sourceGenerations: preparation.sourceGenerations,
            current: preparation.current,
            depotTools: preparation.depotTools,
            automateScript: preparation.automateScript,
            cefBranch: preparation.cefBranch,
            cefCheckout: preparation.cefCheckout,
            chromiumCheckout: preparation.chromiumCheckout,
            depotToolsRevision: preparation.depotToolsRevision,
            patchStacks: preparation.patchStacks,
            environment: environment)
        let value = try await chromiumSourceManifest(
            candidatePreparation, stage: stage)
        try DurableFile.writeJSON(
            value,
            to: candidate.appending("nucleus-source-manifest.json"))
        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: preparation.sourceRoot.string)
        try DurableFile.synchronizeDirectory(preparation.sourceGenerations)
        try await validateChromiumSource(preparation, manifest: manifest)
        try DirectoryLifecycle.activate(
            target: preparation.sourceID,
            link: preparation.current)
        succeeded = true
    }

    private func validateChromiumSource(
        _ preparation: ChromiumSourcePreparation,
        manifest: FilePath
    ) async throws {
        let actual = try JSONDecoder().decode(
            ChromiumSourceManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifest.string)))
        let expected = try await chromiumSourceManifest(
            preparation, stage: TaskID(rawValue: "browser.source"))
        guard actual == expected else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source manifest does not match current inputs: "
                    + manifest.string)
        }
    }

    private func chromiumSourceManifest(
        _ preparation: ChromiumSourcePreparation,
        stage: TaskID
    ) async throws -> ChromiumSourceManifest {
        let chromium = preparation.sourceRoot.appending("chromium/src")
        let revisions = [
            "chromium": try await revision(
                chromium,
                environment: preparation.environment,
                stage: stage),
            "cef": try await revision(
                chromium.appending("cef"),
                environment: preparation.environment,
                stage: stage),
            "dawn": try await revision(
                chromium.appending("third_party/dawn"),
                environment: preparation.environment,
                stage: stage),
            "depot_tools": try await revision(
                preparation.depotTools,
                environment: preparation.environment,
                stage: stage),
        ]
        guard revisions["chromium"] == preparation.chromiumCheckout,
              revisions["cef"] == preparation.cefCheckout,
              revisions["depot_tools"] == preparation.depotToolsRevision
        else {
            throw RuntimeFailure.invalidOutput(
                "prepared Chromium source revisions do not match the pins")
        }
        return ChromiumSourceManifest(
            schema: 1,
            sourceID: preparation.sourceID,
            cefBranch: preparation.cefBranch,
            cefCheckout: preparation.cefCheckout,
            chromiumCheckout: preparation.chromiumCheckout,
            depotToolsRevision: preparation.depotToolsRevision,
            revisions: revisions,
            automateGitSHA256:
                try ArtifactHasher.digest(
                    file: preparation.automateScript).description)
    }

    private func revision(
        _ repository: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["-C", repository.string, "rev-parse", "HEAD"],
                workingDirectory: repository,
                environment: environment,
                output: .captured(limit: 4_096)),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func ensureChromiumProfiles(
        chromium: FilePath,
        depotTools: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let descriptor = chromium.appending("chrome/build/linux.pgo.txt")
        let profileName = try String(
            contentsOf: URL(fileURLWithPath: descriptor.string),
            encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty, !profileName.contains("/") else {
            throw RuntimeFailure.invalidOutput(
                "invalid Chromium PGO profile descriptor: \(descriptor)")
        }
        let profile = chromium.appending(
            "chrome/build/pgo_profiles/\(profileName)")
        if !isNonEmptyFile(profile) {
            try await checked(
                .named("python3"),
                [
                    "tools/update_pgo_profiles.py",
                    "--target=linux", "update",
                    "--gs-url-base=chromium-optimization-profiles/pgo_profiles",
                ],
                in: chromium,
                environment: environment,
                stage: stage)
        }
        guard isNonEmptyFile(profile) else {
            throw RuntimeFailure.invalidOutput(
                "Chromium PGO profile is missing: \(profile)")
        }
        let v8Profile = chromium.appending(
            "v8/tools/builtins-pgo/profiles/x64.profile")
        if !isNonEmptyFile(v8Profile) {
            try await checked(
                .named("python3"),
                [
                    "v8/tools/builtins-pgo/download_profiles.py",
                    "download",
                    "--depot-tools", "third_party/depot_tools",
                    "--check-v8-revision",
                ],
                in: chromium,
                environment: environment,
                stage: stage)
        }
        guard isNonEmptyFile(v8Profile) else {
            throw RuntimeFailure.invalidOutput(
                "V8 builtins PGO profile is missing: \(v8Profile)")
        }
    }

    private func applyChromiumPatch(
        repository: FilePath,
        patch: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        func git(_ arguments: [String]) async throws -> CommandResult {
            try await execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: ["-C", repository.string, "apply"]
                        + arguments + [patch.string],
                    workingDirectory: repository,
                    environment: environment,
                    output: .captured(limit: 4 * 1_024 * 1_024)),
                stage: stage)
        }
        let forward = try await git(["--check"])
        if forward.status == 0 {
            let result = try await git([])
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            return
        }
        let reverse = try await git(["--reverse", "--check"])
        guard reverse.status == 0 else {
            throw RuntimeFailure.invalidOutput(
                "Chromium patch is neither applicable nor already applied: "
                    + patch.string)
        }
    }

    private func checked(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
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

private struct ChromiumSourceManifest: Codable, Equatable {
    let schema: UInt32
    let sourceID: String
    let cefBranch: String
    let cefCheckout: String
    let chromiumCheckout: String
    let depotToolsRevision: String
    let revisions: [String: String]
    let automateGitSHA256: String
}

private func remap(
    _ path: FilePath,
    from source: FilePath,
    to destination: FilePath
) -> FilePath {
    let prefix = source.string.hasSuffix("/")
        ? source.string : source.string + "/"
    guard path.string.hasPrefix(prefix) else { return path }
    return destination.appending(
        String(path.string.dropFirst(prefix.count)))
}

private func isNonEmptyFile(_ path: FilePath) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(
        atPath: path.string),
          let size = attributes[.size] as? NSNumber
    else { return false }
    return size.int64Value > 0
}
