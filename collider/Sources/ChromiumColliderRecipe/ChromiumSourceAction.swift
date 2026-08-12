import ColliderCore
import Foundation
import SystemPackage

package struct PrepareChromiumSourceAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let preparation: ChromiumSourcePreparation

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(preparation.sourceID)
            encoder.append(path: preparation.sourceRoot)
            encoder.append(path: preparation.sourceGenerations)
            encoder.append(path: preparation.current)
            encoder.append(path: preparation.depotTools)
            encoder.append(path: preparation.sourceLockFile)
            encoder.append(preparation.sourceLock.cefBranch)
            encoder.append(preparation.sourceLock.chromiumVersion)
            encoder.append(preparation.sourceLock.buildHostPlatform)
            encoder.append(path: preparation.linuxHostCIPDAdapter)
            encoder.append(preparation.sourceLock.devtoolsRollupPlatform)
            encoder.append(preparation.sourceLock.depotTools.remote)
            encoder.append(preparation.sourceLock.depotTools.commit)

            encoder.appendSequence(preparation.sourceLock.repositories) {
                repositoryEncoder, repository in
                repositoryEncoder.append(repository.name)
                repositoryEncoder.append(repository.checkoutPath)
                repositoryEncoder.append(repository.remote)
                repositoryEncoder.append(repository.upstreamRemote)
                repositoryEncoder.append(repository.upstreamCommit)
                repositoryEncoder.append(repository.commit)
                repositoryEncoder.append(repository.tree)
            }
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
                ActionToolRequirement(
                    "linux-host-cipd-adapter",
                    executable: .path(preparation.linuxHostCIPDAdapter),
                    role: .semantic),
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
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let provenance = preparation.sourceRoot.appending(
            "source-provenance.json")
        if try context.files.metadata(for: provenance) != nil {
            try await prepareCEFCheckoutForDistribution(
                sourceRoot: preparation.sourceRoot,
                context: context)
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
        try context.files.createDirectory(candidate)

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
        let gclientConfiguration = makeGclientConfiguration(
            chromiumRepository: chromiumRepository,
            dependencyOverrides: dependencyOverrides,
            linuxX8664HostTools: false)
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
        try await ensureMacOSHostClang(
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
        let linuxHostGclientConfiguration = makeGclientConfiguration(
            chromiumRepository: chromiumRepository,
            dependencyOverrides: dependencyOverrides,
            linuxX8664HostTools: true)
        try context.files.write(
            Array(linuxHostGclientConfiguration.utf8),
            to: chromiumRoot.appending(".gclient"))
        var linuxHostEnvironment = sourceEnvironment
        linuxHostEnvironment["PATH"] =
            preparation.linuxHostCIPDAdapter.removingLastComponent().string
            + ":" + (sourceEnvironment["PATH"] ?? "/usr/bin:/bin")
        linuxHostEnvironment["NUCLEUS_REAL_CIPD"] =
            preparation.depotTools.appending("cipd").string
        try await requireSuccess(
            .taskOutput(preparation.depotTools.appending("gclient")),
            [
                "sync", "--nohooks", "--no-history",
                "--revision", "src@\(chromiumRepository.commit)",
            ],
            in: chromiumRoot,
            environment: linuxHostEnvironment,
            context: context)
        try await requireSuccess(
            .named("python3"),
            ["scripts/deps/sync_rollup_libs.py"],
            in: chromium.appending("third_party/devtools-frontend/src"),
            environment: sourceEnvironment,
            context: context)
        try await requireSuccess(
            .named("python3"),
            [
                "tools/clang/scripts/update.py",
                "--host-os=linux",
                "--output-dir=\(chromiumLinuxClangRoot)",
            ],
            in: chromium,
            environment: sourceEnvironment,
            context: context)
        for architecture in ["amd64", "arm64"] {
            try await ensureSysrootArchive(
                architecture: architecture,
                chromium: chromium,
                context: context)
        }
        try await ensureProfiles(
            chromium: chromium,
            environment: sourceEnvironment,
            context: context)
        try await prepareCEFCheckoutForDistribution(
            sourceRoot: candidate,
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
        let rollup = preparation.sourceRoot.appending(
            "chromium/src/third_party/devtools-frontend/src/node_modules/@rollup/"
                + "rollup-\(preparation.sourceLock.devtoolsRollupPlatform)/"
                + "rollup-\(preparation.sourceLock.devtoolsRollupPlatform).node")
        guard try isNonEmptyFile(rollup, files: files) else {
            throw failure("Chromium Linux Rollup host module is missing: \(rollup)")
        }
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

    private func makeGclientConfiguration(
        chromiumRepository: ChromiumSourceRepository,
        dependencyOverrides: String,
        linuxX8664HostTools: Bool
    ) -> String {
        var lines = [
            "target_os = ['linux']",
            "target_os_only = True",
            "solutions = [{",
            "  'managed': False,",
            "  'name': 'src',",
            "  'url': '\(chromiumRepository.remote)',",
            "  'custom_vars': {",
            "    'checkout_pgo_profiles': True,",
        ]
        if linuxX8664HostTools {
            lines.append("    'host_os': 'linux',")
            lines.append("    'host_cpu': 'x64',")
        }
        lines.append(contentsOf: [
            "    'source_tarball': False,",
            "    'siso_version': 'latest',",
            "  },",
            "  'custom_deps': {",
            dependencyOverrides,
            "  },",
            "  'deps_file': 'DEPS',",
            "  'safesync_url': '',",
            "}]",
        ])
        return lines.joined(separator: "\n") + "\n"
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

        let checkoutExists =
            try context.files.metadata(for: destination.appending(".git")) != nil
        try context.files.createDirectory(destination.removingLastComponent())
        if !checkoutExists {
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
        }
        for (name, remote) in [
            ("origin", repository.remote),
            ("upstream", repository.upstreamRemote),
        ] {
            try await requireGitSuccess(
                ["-C", destination.string, "config", "remote.\(name).url", remote],
                in: destination,
                environment: environment,
                context: context)
        }
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
        let chromium = sourceRoot.appending("chromium/src")
        for executable in [
            chromium.appending("buildtools/linux64/gn"),
            chromium.appending("third_party/ninja/ninja"),
            chromium.appending("third_party/siso/cipd/siso"),
            chromium.appending(
                "third_party/devtools-frontend/src/node_modules/@rollup/"
                    + "rollup-\(preparation.sourceLock.devtoolsRollupPlatform)/"
                    + "rollup-\(preparation.sourceLock.devtoolsRollupPlatform).node"),
        ] {
            guard try isNonEmptyFile(executable, files: context.files) else {
                throw failure(
                    "Chromium Linux host tool is missing: " + executable.string)
            }
        }
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

    private func prepareCEFCheckoutForDistribution(
        sourceRoot: FilePath,
        context: ActionContext
    ) async throws {
        let repository = try lockedRepository(named: "cef")
        let checkout = sourceRoot.appending(repository.checkoutPath)
        try await requireGitSuccess(
            [
                "-C", checkout.string, "update-ref",
                "refs/heads/\(preparation.sourceLock.cefBranch)",
                repository.commit,
            ],
            in: checkout,
            environment: actionEnvironment,
            context: context)
        try await requireGitSuccess(
            [
                "-C", checkout.string, "update-ref",
                "refs/remotes/origin/master", repository.upstreamCommit,
            ],
            in: checkout,
            environment: actionEnvironment,
            context: context)
        let alternates = checkout.appending(".git/objects/info/alternates")
        guard try context.files.metadata(for: alternates) != nil else {
            return
        }
        try await requireGitSuccess(
            ["-C", checkout.string, "repack", "-a", "-d"],
            in: checkout,
            environment: actionEnvironment,
            context: context)
        try context.files.remove(alternates)
        try await requireGitSuccess(
            ["-C", checkout.string, "fsck", "--connectivity-only"],
            in: checkout,
            environment: actionEnvironment,
            context: context)
    }

    private func ensureMacOSHostClang(
        chromium: FilePath,
        environment: [String: String],
        context: ActionContext
    ) async throws {
        let root = chromium.appending("third_party/llvm-build/Release+Asserts")
        let clang = root.appending("bin/clang")
        let magic =
            try context.files.metadata(for: clang) == nil
            ? [] : context.files.readPrefix(clang, count: 4)
        let isMachO =
            magic == [0xcf, 0xfa, 0xed, 0xfe]
            || magic == [0xca, 0xfe, 0xba, 0xbe]
            || magic == [0xca, 0xfe, 0xba, 0xbf]
            || magic == [0xbe, 0xba, 0xfe, 0xca]
        guard !isMachO else { return }
        try context.files.remove(root)
        try await requireSuccess(
            .named("python3"),
            ["tools/clang/scripts/update.py", "--host-os=mac-arm64"],
            in: chromium,
            environment: environment,
            context: context)
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
                    "v8/tools/builtins-pgo/profiles/"
                        + chromiumV8BuiltinsPGOProfile),
                files: context.files),
            linuxClang: try fileIdentity(
                chromium.appending(
                    "\(chromiumLinuxClangRoot)/bin/clang"),
                files: context.files),
            linuxSysroots: try ["amd64", "arm64"].map {
                try sysrootIdentity(
                    architecture: $0,
                    chromium: chromium,
                    files: context.files)
            })
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
            "v8/tools/builtins-pgo/profiles/"
                + chromiumV8BuiltinsPGOProfile)
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

    private func sysrootIdentity(
        architecture: String,
        chromium: FilePath,
        files: ActionFileSystem
    ) throws -> ChromiumSourceFileIdentity {
        let stamp = try sysrootStamp(
            architecture: architecture,
            chromium: chromium,
            files: files)
        return ChromiumSourceFileIdentity(
            name: architecture,
            sha256: try files.digest(file: stamp).description)
    }

    private func ensureSysrootArchive(
        architecture: String,
        chromium: FilePath,
        context: ActionContext
    ) async throws {
        let descriptor = try sysrootDescriptor(
            architecture: architecture,
            chromium: chromium,
            files: context.files)
        guard
            let url = URL(
                string: descriptor.url + "/" + descriptor.sha256),
            let digest = ArtifactDigest(sha256Hex: descriptor.sha256)
        else {
            throw failure("invalid Chromium Linux sysroot descriptor")
        }
        let archiveRoot = chromium.removingLastComponent()
            .removingLastComponent().appending("linux-sysroot-archives")
        try context.files.createDirectory(archiveRoot)
        let archive = archiveRoot.appending(descriptor.directory + ".tar.xz")
        try await context.downloads.download(
            try DownloadSpec(
                url: url,
                permittedRedirectOrigins: [
                    "https://commondatastorage.googleapis.com"
                ],
                expectedDigest: digest,
                maximumResponseSize: 2 * 1_024 * 1_024 * 1_024,
                acceptedMediaTypes: [
                    "application/octet-stream",
                    "application/x-tar",
                    "application/x-xz",
                ],
                requestTimeoutSeconds: 600,
                inactivityTimeoutSeconds: 60,
                maximumRetries: 2,
                resumption: .validatorRequired),
            to: archive)
        try context.files.write(
            Array((url.absoluteString + "\n").utf8),
            to: archiveRoot.appending(descriptor.directory + ".stamp"))
    }

    private func sysrootStamp(
        architecture: String,
        chromium: FilePath,
        files: ActionFileSystem
    ) throws -> FilePath {
        let descriptor = try sysrootDescriptor(
            architecture: architecture,
            chromium: chromium,
            files: files)
        return chromium.removingLastComponent().removingLastComponent()
            .appending(
                "linux-sysroot-archives/"
                    + descriptor.directory + ".tar.xz")
    }

    private func sysrootDescriptor(
        architecture: String,
        chromium: FilePath,
        files: ActionFileSystem
    ) throws -> ChromiumSysrootDescriptor {
        let linux = chromium.appending("build/linux")
        let configuration = linux.appending("sysroot_scripts/sysroots.json")
        let descriptors = try JSONDecoder().decode(
            [String: ChromiumSysrootDescriptor].self,
            from: Data(files.read(configuration)))
        let suffix = "_\(architecture)-sysroot"
        let matches = descriptors.values.filter {
            $0.directory.hasSuffix(suffix)
        }
        guard matches.count == 1, let match = matches.first else {
            throw failure(
                "expected one Chromium Linux \(architecture) sysroot descriptor")
        }
        return match
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "git command failed")
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Chromium source command failed")
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
    let linuxClang: ChromiumSourceFileIdentity
    let linuxSysroots: [ChromiumSourceFileIdentity]
}

private struct ChromiumSysrootDescriptor: Decodable {
    let directory: String
    let sha256: String
    let url: String

    private enum CodingKeys: String, CodingKey {
        case directory = "SysrootDir"
        case sha256 = "Sha256Sum"
        case url = "URL"
    }
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
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message):
            message
        }
    }
}
