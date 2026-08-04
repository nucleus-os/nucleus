import ColliderCore
import Foundation
import SystemPackage

package struct PrepareChromiumSourceAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let preparation: ChromiumSourcePreparation

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: preparation.sourceID)
            encoder.append(tag: 2, string: preparation.sourceRoot.string)
            encoder.append(tag: 3, string: preparation.sourceGenerations.string)
            encoder.append(tag: 4, string: preparation.current.string)
            encoder.append(tag: 5, string: preparation.depotTools.string)
            encoder.append(tag: 6, string: preparation.sourceLockFile.string)
            encoder.append(tag: 7, string: preparation.sourceLock.cefBranch)
            encoder.append(tag: 8, string: preparation.sourceLock.chromiumVersion)
            encoder.append(
                tag: 9,
                string: preparation.sourceLock.depotTools.remote)
            encoder.append(
                tag: 10,
                string: preparation.sourceLock.depotTools.commit)

            var repositories = CanonicalDigestEncoder()
            for repository in preparation.sourceLock.repositories {
                repositories.append(tag: 1, string: repository.name)
                repositories.append(tag: 2, string: repository.checkoutPath)
                repositories.append(tag: 3, string: repository.remote)
                repositories.append(tag: 4, string: repository.upstreamRemote)
                repositories.append(tag: 5, string: repository.upstreamCommit)
                repositories.append(tag: 6, string: repository.commit)
                repositories.append(tag: 7, string: repository.tree)
            }
            encoder.append(tag: 11, bytes: repositories.bytes)
        }
    }

    package static let kind: ActionKind = "browser.prepare-source"

    let preparation: ChromiumSourcePreparation

    package init(preparation: ChromiumSourcePreparation) {
        self.preparation = preparation
    }

    package var identity: Identity { Identity(preparation: preparation) }
    package var environment: [String: String] { preparation.environment }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git",
                    executable: .named("git"),
                    role: .semantic),
                ActionToolRequirement(
                    "python3",
                    executable: .named("python3"),
                    role: .semantic),
                ActionToolRequirement(
                    "gclient",
                    executable: .taskOutput(preparation.depotTools.appending("gclient")),
                    role: .operational),
            ],
            effects: [
                ActionEffect(
                    .readWrite,
                    scope: .publication(preparation.sourceGenerations)),
                ActionEffect(
                    .read,
                    scope: .input(preparation.depotTools)),
                ActionEffect(
                    .read,
                    scope: .input(preparation.sourceLockFile)),
                ActionEffect(
                    .readWrite,
                    scope: .scratch(repositoryCache)),
            ],
            resources: ActionResourceRequest(
                cpuCount: 1,
                memoryBytes: 2 * 1_024 * 1_024 * 1_024,
                exclusive: false))
    }

    package func execute(in context: ActionContext) async throws {
        let provenance = preparation.sourceRoot.appending(
            "source-provenance.json")
        if try context.files.metadata(for: provenance) != nil {
            try await validateSource(
                sourceRoot: preparation.sourceRoot,
                provenance: provenance,
                context: context)
            try context.files.replaceSymlink(
                at: preparation.current,
                target: preparation.sourceID)
            return
        }
        guard try context.files.metadata(for: preparation.sourceRoot) == nil else {
            throw failure(
                "Chromium source generation exists without provenance: "
                    + preparation.sourceRoot.string)
        }

        try context.files.createDirectory(preparation.sourceGenerations)
        let candidate = preparation.sourceGenerations.appending(
            ".\(preparation.sourceID).preparing")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        var succeeded = false
        defer {
            if !succeeded { try? context.files.remove(candidate) }
        }

        let sourceEnvironment = actionEnvironment
        let chromiumRepository = try lockedRepository(named: "chromium")
        let cefRepository = try lockedRepository(named: "cef")
        let chromiumRoot = candidate.appending("chromium")
        let chromium = candidate.appending(chromiumRepository.checkoutPath)

        try await checkout(
            chromiumRepository,
            at: chromium,
            cache: repositoryCache.appending("chromium.git"),
            environment: sourceEnvironment,
            context: context)
        let dependencyOverrides = preparation.sourceLock.repositories
            .filter { $0.name != "chromium" && $0.name != "cef" }
            .sorted { $0.checkoutPath < $1.checkoutPath }
            .map {
                let path = String($0.checkoutPath.dropFirst("chromium/".count))
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
        try context.files.write(
            Array(gclientConfiguration.utf8),
            to: chromiumRoot.appending(".gclient"))
        try await requireSuccess(
            .taskOutput(preparation.depotTools.appending("gclient")),
            [
                "sync", "--nohooks", "--no-history",
                "--revision", "src@\(chromiumRepository.commit)",
            ],
            in: chromiumRoot,
            environment: sourceEnvironment,
            context: context)
        try await checkout(
            cefRepository,
            at: candidate.appending(cefRepository.checkoutPath),
            cache: repositoryCache.appending("cef.git"),
            environment: sourceEnvironment,
            context: context)
        try context.files.write(
            Array("cef/\n".utf8),
            to: chromium.appending(".git/info/exclude"))
        try await requireSuccess(
            .taskOutput(preparation.depotTools.appending("gclient")),
            ["runhooks"],
            in: chromiumRoot,
            environment: sourceEnvironment,
            context: context)
        try await ensureProfiles(
            chromium: chromium,
            environment: sourceEnvironment,
            context: context)
        try await requireSuccess(
            .named("python3"),
            ["cef/tools/translator.py", "--root-dir", "cef"],
            in: chromium,
            environment: sourceEnvironment,
            context: context)
        try await requireSuccess(
            .named("python3"),
            ["tools/version_manager.py", "-c"],
            in: chromium.appending("cef"),
            environment: sourceEnvironment,
            context: context)

        let value = try await sourceProvenance(
            sourceRoot: candidate,
            environment: sourceEnvironment,
            context: context)
        let candidateProvenance = candidate.appending(
            "source-provenance.json")
        try context.files.write(
            try encodedJSON(value),
            to: candidateProvenance)
        try await validateSource(
            sourceRoot: candidate,
            provenance: candidateProvenance,
            context: context)

        try context.files.publishGeneration(
            candidate: candidate,
            generation: preparation.sourceRoot,
            active: preparation.current)
        succeeded = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        let provenance = preparation.sourceRoot.appending(
            "source-provenance.json")
        guard try files.metadata(for: provenance)?.type == .regular else {
            throw failure("Chromium source provenance is missing: \(provenance)")
        }
        _ = try JSONDecoder().decode(
            ChromiumSourceProvenance.self,
            from: Data(files.read(provenance)))
        guard
            try files.metadataWithoutFollowingSymlinks(
                for: preparation.current)?.type == .symbolicLink,
            try files.readSymbolicLink(preparation.current) == preparation.sourceID
        else {
            throw failure(
                "Chromium source activation does not select "
                    + preparation.sourceID)
        }
    }

    private var repositoryCache: FilePath {
        preparation.sourceGenerations.removingLastComponent().appending(
            "repository-cache")
    }

    private var actionEnvironment: [String: String] {
        var value = preparation.environment
        value["PATH"] =
            preparation.depotTools.string + ":"
            + (value["PATH"] ?? "/usr/bin:/bin")
        value["DEPOT_TOOLS_UPDATE"] = "0"
        return value
    }

    private func checkout(
        _ repository: ChromiumSourceRepository,
        at destination: FilePath,
        cache: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws {
        let cacheExists = try context.files.metadata(for: cache) != nil
        try context.files.createDirectory(cache.removingLastComponent())
        if cacheExists {
            try await requireGitSuccess(
                [
                    "-C", cache.string, "remote", "set-url", "upstream",
                    repository.upstreamRemote,
                ],
                in: cache,
                environment: environment,
                context: context)
            try await requireGitSuccess(
                [
                    "-C", cache.string, "remote", "set-url", "origin",
                    repository.remote,
                ],
                in: cache,
                environment: environment,
                context: context)
        } else {
            try await requireGitSuccess(
                ["init", "--bare", cache.string],
                in: cache.removingLastComponent(),
                environment: environment,
                context: context)
            try await requireGitSuccess(
                [
                    "-C", cache.string, "remote", "add", "upstream",
                    repository.upstreamRemote,
                ],
                in: cache,
                environment: environment,
                context: context)
            try await requireGitSuccess(
                [
                    "-C", cache.string, "remote", "add", "origin",
                    repository.remote,
                ],
                in: cache,
                environment: environment,
                context: context)
        }
        try await requireGitSuccess(
            [
                "-C", cache.string, "fetch", "--depth=1", "upstream",
                repository.upstreamCommit
                    + ":refs/nucleus/upstream/\(repository.upstreamCommit)",
            ],
            in: cache,
            environment: environment,
            context: context)
        try await requireGitSuccess(
            [
                "-C", cache.string, "fetch", "--depth=16", "origin",
                repository.commit
                    + ":refs/nucleus/selected/\(repository.commit)",
            ],
            in: cache,
            environment: environment,
            context: context)

        try context.files.createDirectory(destination.removingLastComponent())
        try await requireGitSuccess(
            ["init", destination.string],
            in: destination.removingLastComponent(),
            environment: environment,
            context: context)
        try context.files.write(
            Array("\(cache.appending("objects"))\n".utf8),
            to: destination.appending(".git/objects/info/alternates"))
        let cacheShallow = cache.appending("shallow")
        if try context.files.metadata(for: cacheShallow) != nil {
            try context.files.copy(
                from: cacheShallow,
                to: destination.appending(".git/shallow"))
        }
        try await requireGitSuccess(
            [
                "-C", destination.string, "remote", "add", "origin",
                repository.remote,
            ],
            in: destination,
            environment: environment,
            context: context)
        try await requireGitSuccess(
            [
                "-C", destination.string, "remote", "add", "upstream",
                repository.upstreamRemote,
            ],
            in: destination,
            environment: environment,
            context: context)
        try await requireGitSuccess(
            [
                "-C", destination.string, "checkout", "--detach",
                repository.commit,
            ],
            in: destination,
            environment: environment,
            context: context)
    }

    private func validateSource(
        sourceRoot: FilePath,
        provenance: FilePath,
        context: ActionContext
    ) async throws {
        let actual = try JSONDecoder().decode(
            ChromiumSourceProvenance.self,
            from: Data(context.files.read(provenance)))
        let expected = try await sourceProvenance(
            sourceRoot: sourceRoot,
            environment: actionEnvironment,
            context: context)
        guard actual == expected else {
            throw failure(
                "Chromium source provenance does not match its checkout: "
                    + provenance.string)
        }
    }

    private func sourceProvenance(
        sourceRoot: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws -> ChromiumSourceProvenance {
        var repositories: [ChromiumRepositoryProvenance] = []
        for locked in preparation.sourceLock.repositories {
            let checkout = sourceRoot.appending(locked.checkoutPath)
            let commit = try await gitValue(
                ["rev-parse", "HEAD"],
                repository: checkout,
                environment: environment,
                context: context)
            let tree = try await gitValue(
                ["rev-parse", "HEAD^{tree}"],
                repository: checkout,
                environment: environment,
                context: context)
            guard commit == locked.commit, tree == locked.tree else {
                throw failure(
                    "locked \(locked.name) commit or tree does not match")
            }
            let status = try await gitValue(
                ["status", "--porcelain"],
                repository: checkout,
                environment: environment,
                context: context)
            guard status.isEmpty else {
                throw failure(
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
            context: context)
        guard depotCommit == preparation.sourceLock.depotTools.commit else {
            throw failure("depot_tools does not match the browser source lock")
        }
        let chromium = sourceRoot.appending("chromium/src")
        return ChromiumSourceProvenance(
            sourceID: preparation.sourceID,
            sourceLockSHA256: try context.files.digest(
                file: preparation.sourceLockFile
            ).description,
            repositories: repositories,
            depotToolsCommit: depotCommit,
            chromiumDEPSSHA256: try context.files.digest(
                file: chromium.appending("DEPS")
            ).description,
            gclientGraphSHA256: try context.files.digest(
                file: sourceRoot.appending("chromium/.gclient_entries")
            ).description,
            pgo: try profileIdentity(
                chromium: chromium,
                descriptor: chromium.appending("chrome/build/linux.pgo.txt"),
                files: context.files),
            v8BuiltinsPGO: try fileIdentity(
                chromium.appending(
                    "v8/tools/builtins-pgo/profiles/x64.profile"),
                files: context.files))
    }

    private func ensureProfiles(
        chromium: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws {
        let descriptor = chromium.appending("chrome/build/linux.pgo.txt")
        let profileName = try text(at: descriptor, files: context.files)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty, !profileName.contains("/") else {
            throw failure(
                "invalid Chromium PGO profile descriptor: \(descriptor)")
        }
        let profile = chromium.appending(
            "chrome/build/pgo_profiles/\(profileName)")
        if try !isNonEmptyFile(profile, files: context.files) {
            try await requireSuccess(
                .named("python3"),
                [
                    "tools/update_pgo_profiles.py", "--target=linux", "update",
                    "--gs-url-base=chromium-optimization-profiles/pgo_profiles",
                ],
                in: chromium,
                environment: environment,
                context: context)
        }
        guard try isNonEmptyFile(profile, files: context.files) else {
            throw failure("Chromium PGO profile is missing: \(profile)")
        }
        let v8Profile = chromium.appending(
            "v8/tools/builtins-pgo/profiles/x64.profile")
        if try !isNonEmptyFile(v8Profile, files: context.files) {
            try await requireSuccess(
                .named("python3"),
                [
                    "v8/tools/builtins-pgo/download_profiles.py", "download",
                    "--depot-tools", preparation.depotTools.string,
                    "--check-v8-revision",
                ],
                in: chromium,
                environment: environment,
                context: context)
        }
        guard try isNonEmptyFile(v8Profile, files: context.files) else {
            throw failure("V8 builtins PGO profile is missing: \(v8Profile)")
        }
    }

    private func gitValue(
        _ arguments: [String],
        repository: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws -> String {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["-C", repository.string] + arguments,
                workingDirectory: repository,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)))
        guard result.status == 0 else {
            throw ChromiumSourceActionFailure.commandFailed(
                executable: "git",
                arguments: arguments,
                status: result.status)
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func requireGitSuccess(
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws {
        try await requireSuccess(
            .named("git"),
            arguments,
            in: directory,
            environment: environment,
            context: context)
    }

    private func requireSuccess(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment))
        guard result.status == 0 else {
            throw ChromiumSourceActionFailure.commandFailed(
                executable: String(describing: executable),
                arguments: arguments,
                status: result.status)
        }
    }

    private func lockedRepository(
        named name: String
    ) throws -> ChromiumSourceRepository {
        let matches = preparation.sourceLock.repositories.filter {
            $0.name == name
        }
        guard matches.count == 1, let repository = matches.first else {
            throw failure(
                "browser source lock must contain exactly one \(name) repository")
        }
        return repository
    }

    private func profileIdentity(
        chromium: FilePath,
        descriptor: FilePath,
        files: ActionFileSystem
    ) throws -> ChromiumSourceFileIdentity {
        let name = try text(at: descriptor, files: files)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw failure(
                "invalid Chromium PGO profile descriptor: \(descriptor)")
        }
        return try fileIdentity(
            chromium.appending("chrome/build/pgo_profiles/\(name)"),
            files: files)
    }

    private func fileIdentity(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws -> ChromiumSourceFileIdentity {
        guard try isNonEmptyFile(path, files: files) else {
            throw failure("browser source profile is missing: \(path)")
        }
        return ChromiumSourceFileIdentity(
            name: path.lastComponent?.string ?? "",
            sha256: try files.digest(file: path).description)
    }

    private func isNonEmptyFile(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws -> Bool {
        guard let metadata = try files.metadata(for: path) else { return false }
        return metadata.type == .regular && metadata.size > 0
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
        encoder.outputFormatting = [.sortedKeys]
        return Array(try encoder.encode(value))
    }

    private func failure(_ message: String) -> ChromiumSourceActionFailure {
        .invalidOutput(message)
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

private enum ChromiumSourceActionFailure: Error, CustomStringConvertible {
    case commandFailed(
        executable: String,
        arguments: [String],
        status: Int32)
    case invalidOutput(String)

    var description: String {
        switch self {
        case .commandFailed(let executable, let arguments, let status):
            "\(executable) \(arguments.joined(separator: " ")) failed with status \(status)"
        case .invalidOutput(let message):
            message
        }
    }
}
