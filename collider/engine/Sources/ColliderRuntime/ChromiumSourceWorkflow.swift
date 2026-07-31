import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareChromiumSource(
        _ preparation: ChromiumSourcePreparation,
        stage: TaskID
    ) async throws {
        let provenance = preparation.sourceRoot.appending(
            "source-provenance.json")
        if FileManager.default.fileExists(atPath: provenance.string) {
            try await validateChromiumSource(
                preparation,
                sourceRoot: preparation.sourceRoot,
                provenance: provenance,
                stage: stage)
            try DirectoryLifecycle.activate(
                target: preparation.sourceID,
                link: preparation.current)
            return
        }
        guard !FileManager.default.fileExists(
            atPath: preparation.sourceRoot.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source generation exists without provenance: "
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

        var environment = preparation.environment
        environment["PATH"] = preparation.depotTools.string + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["DEPOT_TOOLS_UPDATE"] = "0"
        let chromiumRepository = try lockedRepository(
            named: "chromium",
            in: preparation.sourceLock)
        let cefRepository = try lockedRepository(
            named: "cef",
            in: preparation.sourceLock)
        let chromiumRoot = candidate.appending("chromium")
        let chromium = candidate.appending(chromiumRepository.checkoutPath)
        let repositoryCache = preparation.sourceGenerations
            .removingLastComponent()
            .appending("repository-cache")

        try await checkoutLockedRepository(
            chromiumRepository,
            at: chromium,
            cache: repositoryCache.appending("chromium.git"),
            environment: environment,
            stage: stage)
        let dependencyOverrides = preparation.sourceLock.repositories
            .filter {
                $0.name != "chromium" && $0.name != "cef"
            }
            .sorted { $0.checkoutPath < $1.checkoutPath }
            .map {
                let path = String(
                    $0.checkoutPath.dropFirst("chromium/".count))
                return "    '\(path)': '\($0.remote)@\($0.commit)',"
            }
            .joined(separator: "\n")
        let gclientConfiguration =
            """
            solutions = [{
              'managed': False,
              'name': 'src',
              'url': '\(chromiumRepository.remote)',
              'custom_vars': {
                'checkout_pgo_profiles': True,
                'source_tarball': False,
                'siso_version': 'latest',
              },
              'custom_deps': {
            \(dependencyOverrides)
              },
              'deps_file': 'DEPS',
              'safesync_url': '',
            }]
            """
        try DurableFile.write(
            Data(gclientConfiguration.utf8),
            to: chromiumRoot.appending(".gclient"))
        try await checkedChromiumSourceCommand(
            .path(preparation.depotTools.appending("gclient")),
            [
                "sync",
                "--nohooks",
                "--no-history",
                "--revision", "src@\(chromiumRepository.commit)",
            ],
            in: chromiumRoot,
            environment: environment,
            stage: stage)
        try await checkoutLockedRepository(
            cefRepository,
            at: candidate.appending(cefRepository.checkoutPath),
            cache: repositoryCache.appending("cef.git"),
            environment: environment,
            stage: stage)
        try DurableFile.write(
            Data("cef/\n".utf8),
            to: chromium.appending(".git/info/exclude"))
        try await checkedChromiumSourceCommand(
            .path(preparation.depotTools.appending("gclient")),
            ["runhooks"],
            in: chromiumRoot,
            environment: environment,
            stage: stage)
        try await ensureChromiumProfiles(
            chromium: chromium,
            depotTools: preparation.depotTools,
            environment: environment,
            stage: stage)
        try await checkedChromiumSourceCommand(
            .named("python3"),
            ["cef/tools/translator.py", "--root-dir", "cef"],
            in: chromium,
            environment: environment,
            stage: stage)
        try await checkedChromiumSourceCommand(
            .named("python3"),
            ["tools/version_manager.py", "-c"],
            in: chromium.appending("cef"),
            environment: environment,
            stage: stage)

        let value = try await chromiumSourceProvenance(
            preparation,
            sourceRoot: candidate,
            environment: environment,
            stage: stage)
        let candidateProvenance = candidate.appending(
            "source-provenance.json")
        try DurableFile.writeJSON(value, to: candidateProvenance)
        try await validateChromiumSource(
            preparation,
            sourceRoot: candidate,
            provenance: candidateProvenance,
            stage: stage)

        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: preparation.sourceRoot.string)
        try DurableFile.synchronizeDirectory(preparation.sourceGenerations)
        try DirectoryLifecycle.activate(
            target: preparation.sourceID,
            link: preparation.current)
        succeeded = true
    }

    private func checkoutLockedRepository(
        _ repository: ChromiumSourceRepository,
        at destination: FilePath,
        cache: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let cacheExists = FileManager.default.fileExists(
            atPath: cache.string)
        try FileManager.default.createDirectory(
            atPath: cache.removingLastComponent().string,
            withIntermediateDirectories: true)
        if cacheExists {
            try await checkedChromiumSourceCommand(
                .named("git"),
                [
                    "-C", cache.string,
                    "remote", "set-url", "upstream",
                    repository.upstreamRemote,
                ],
                in: cache,
                environment: environment,
                stage: stage)
            try await checkedChromiumSourceCommand(
                .named("git"),
                [
                    "-C", cache.string,
                    "remote", "set-url", "origin", repository.remote,
                ],
                in: cache,
                environment: environment,
                stage: stage)
        } else {
            try await checkedChromiumSourceCommand(
                .named("git"),
                ["init", "--bare", cache.string],
                in: cache.removingLastComponent(),
                environment: environment,
                stage: stage)
            try await checkedChromiumSourceCommand(
                .named("git"),
                [
                    "-C", cache.string,
                    "remote", "add", "upstream",
                    repository.upstreamRemote,
                ],
                in: cache,
                environment: environment,
                stage: stage)
            try await checkedChromiumSourceCommand(
                .named("git"),
                [
                    "-C", cache.string,
                    "remote", "add", "origin", repository.remote,
                ],
                in: cache,
                environment: environment,
                stage: stage)
        }
        try await checkedChromiumSourceCommand(
            .named("git"),
            [
                "-C", cache.string,
                "fetch", "--depth=1", "upstream",
                repository.upstreamCommit
                    + ":refs/nucleus/upstream/\(repository.upstreamCommit)",
            ],
            in: cache,
            environment: environment,
            stage: stage)
        try await checkedChromiumSourceCommand(
            .named("git"),
            [
                "-C", cache.string,
                "fetch", "--depth=16", "origin",
                repository.commit
                    + ":refs/nucleus/selected/\(repository.commit)",
            ],
            in: cache,
            environment: environment,
            stage: stage)
        try FileManager.default.createDirectory(
            atPath: destination.removingLastComponent().string,
            withIntermediateDirectories: true)
        try await checkedChromiumSourceCommand(
            .named("git"),
            ["init", destination.string],
            in: destination.removingLastComponent(),
            environment: environment,
            stage: stage)
        try DurableFile.write(
            Data("\(cache.appending("objects"))\n".utf8),
            to: destination.appending(
                ".git/objects/info/alternates"))
        let cacheShallow = cache.appending("shallow")
        if FileManager.default.fileExists(atPath: cacheShallow.string) {
            try DurableFile.copy(
                from: cacheShallow,
                to: destination.appending(".git/shallow"))
        }
        try await checkedChromiumSourceCommand(
            .named("git"),
            [
                "-C", destination.string,
                "remote", "add", "origin", repository.remote,
            ],
            in: destination,
            environment: environment,
            stage: stage)
        try await checkedChromiumSourceCommand(
            .named("git"),
            [
                "-C", destination.string,
                "remote", "add", "upstream", repository.upstreamRemote,
            ],
            in: destination,
            environment: environment,
            stage: stage)
        try await checkedChromiumSourceCommand(
            .named("git"),
            [
                "-C", destination.string,
                "checkout", "--detach", repository.commit,
            ],
            in: destination,
            environment: environment,
            stage: stage)
    }

    private func validateChromiumSource(
        _ preparation: ChromiumSourcePreparation,
        sourceRoot: FilePath,
        provenance: FilePath,
        stage: TaskID
    ) async throws {
        let actual = try JSONDecoder().decode(
            ChromiumSourceProvenance.self,
            from: Data(contentsOf: URL(fileURLWithPath: provenance.string)))
        let expected = try await chromiumSourceProvenance(
            preparation,
            sourceRoot: sourceRoot,
            environment: preparation.environment,
            stage: stage)
        guard actual == expected else {
            throw RuntimeFailure.invalidOutput(
                "Chromium source provenance does not match its checkout: "
                    + provenance.string)
        }
    }

    private func chromiumSourceProvenance(
        _ preparation: ChromiumSourcePreparation,
        sourceRoot: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> ChromiumSourceProvenance {
        var repositories: [ChromiumRepositoryProvenance] = []
        for locked in preparation.sourceLock.repositories {
            let checkout = sourceRoot.appending(locked.checkoutPath)
            let commit = try await gitValue(
                ["rev-parse", "HEAD"],
                repository: checkout,
                environment: environment,
                stage: stage)
            let tree = try await gitValue(
                ["rev-parse", "HEAD^{tree}"],
                repository: checkout,
                environment: environment,
                stage: stage)
            guard commit == locked.commit, tree == locked.tree else {
                throw RuntimeFailure.invalidOutput(
                    "locked \(locked.name) commit or tree does not match")
            }
            let status = try await gitValue(
                ["status", "--porcelain"],
                repository: checkout,
                environment: environment,
                stage: stage)
            guard status.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "locked \(locked.name) checkout is dirty:\n\(status)")
            }
            repositories.append(
                ChromiumRepositoryProvenance(
                    name: locked.name,
                    commit: commit,
                    tree: tree))
        }
        let depotCommit = try await gitValue(
            ["rev-parse", "HEAD"],
            repository: preparation.depotTools,
            environment: environment,
            stage: stage)
        guard depotCommit == preparation.sourceLock.depotTools.commit else {
            throw RuntimeFailure.invalidOutput(
                "depot_tools does not match the browser source lock")
        }
        let chromium = sourceRoot.appending("chromium/src")
        return ChromiumSourceProvenance(
            sourceID: preparation.sourceID,
            sourceLockSHA256:
                try ArtifactHasher.digest(
                    file: preparation.sourceLockFile).description,
            repositories: repositories,
            depotToolsCommit: depotCommit,
            chromiumDEPSSHA256:
                try ArtifactHasher.digest(
                    file: chromium.appending("DEPS")).description,
            gclientGraphSHA256:
                try ArtifactHasher.digest(
                    file: sourceRoot.appending(
                        "chromium/.gclient_entries")).description,
            pgo: try chromiumProfileIdentity(
                chromium: chromium,
                descriptor: chromium.appending("chrome/build/linux.pgo.txt")),
            v8BuiltinsPGO: try chromiumFileIdentity(
                chromium.appending(
                    "v8/tools/builtins-pgo/profiles/x64.profile")))
    }

    private func gitValue(
        _ arguments: [String],
        repository: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["-C", repository.string] + arguments,
                workingDirectory: repository,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
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
        if !isNonEmptyChromiumFile(profile) {
            try await checkedChromiumSourceCommand(
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
        guard isNonEmptyChromiumFile(profile) else {
            throw RuntimeFailure.invalidOutput(
                "Chromium PGO profile is missing: \(profile)")
        }
        let v8Profile = chromium.appending(
            "v8/tools/builtins-pgo/profiles/x64.profile")
        if !isNonEmptyChromiumFile(v8Profile) {
            try await checkedChromiumSourceCommand(
                .named("python3"),
                [
                    "v8/tools/builtins-pgo/download_profiles.py",
                    "download",
                    "--depot-tools", depotTools.string,
                    "--check-v8-revision",
                ],
                in: chromium,
                environment: environment,
                stage: stage)
        }
        guard isNonEmptyChromiumFile(v8Profile) else {
            throw RuntimeFailure.invalidOutput(
                "V8 builtins PGO profile is missing: \(v8Profile)")
        }
    }

    private func checkedChromiumSourceCommand(
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

private struct ChromiumSourceProvenance: Codable, Equatable {
    let sourceID: String
    let sourceLockSHA256: String
    let repositories: [ChromiumRepositoryProvenance]
    let depotToolsCommit: String
    let chromiumDEPSSHA256: String
    let gclientGraphSHA256: String
    let pgo: ChromiumSourceFileIdentity
    let v8BuiltinsPGO: ChromiumSourceFileIdentity
}

private struct ChromiumRepositoryProvenance: Codable, Equatable {
    let name: String
    let commit: String
    let tree: String
}

private struct ChromiumSourceFileIdentity: Codable, Equatable {
    let name: String
    let sha256: String
}

private func lockedRepository(
    named name: String,
    in sourceLock: ChromiumSourceLock
) throws -> ChromiumSourceRepository {
    let matches = sourceLock.repositories.filter { $0.name == name }
    guard matches.count == 1, let repository = matches.first else {
        throw RuntimeFailure.invalidOutput(
            "browser source lock must contain exactly one \(name) repository")
    }
    return repository
}

private func chromiumProfileIdentity(
    chromium: FilePath,
    descriptor: FilePath
) throws -> ChromiumSourceFileIdentity {
    let name = try String(
        contentsOf: URL(fileURLWithPath: descriptor.string),
        encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("/") else {
        throw RuntimeFailure.invalidOutput(
            "invalid Chromium PGO profile descriptor: \(descriptor)")
    }
    return try chromiumFileIdentity(
        chromium.appending("chrome/build/pgo_profiles/\(name)"))
}

private func chromiumFileIdentity(
    _ path: FilePath
) throws -> ChromiumSourceFileIdentity {
    guard isNonEmptyChromiumFile(path) else {
        throw RuntimeFailure.invalidOutput(
            "browser source profile is missing: \(path)")
    }
    return ChromiumSourceFileIdentity(
        name: path.lastComponent?.string ?? "",
        sha256: try ArtifactHasher.digest(file: path).description)
}

private func isNonEmptyChromiumFile(_ path: FilePath) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(
        atPath: path.string),
          let size = attributes[.size] as? NSNumber
    else { return false }
    return size.int64Value > 0
}
