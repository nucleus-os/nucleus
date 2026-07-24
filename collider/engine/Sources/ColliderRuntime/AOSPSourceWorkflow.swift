import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func verifyAOSPSourceLock(
        _ verification: AOSPSourceLockVerification,
        stage: TaskID
    ) async throws {
        let specification = verification.specification
        let platform = specification.platform
        let repo = specification.repo

        let manifestRefs = try await aospRemoteRefs(
            url: platform.manifestURL,
            revisions: [
                platform.revision,
                platform.revision + "^{}",
            ],
            environment: verification.environment,
            stage: stage)
        try requireAOSPRemoteRef(
            manifestRefs,
            revision: platform.revision,
            expected: platform.manifestTagObject,
            description: "manifest tag")
        try requireAOSPRemoteRef(
            manifestRefs,
            revision: platform.revision + "^{}",
            expected: platform.manifestCommit,
            description: "manifest tag commit")

        let temporary = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "nucleus-aosp-manifest-\(UUID().uuidString)"
                )
                .path)
        defer {
            try? FileManager.default.removeItem(atPath: temporary.string)
        }
        let checkout = temporary.appending("manifest")
        let tagPrefix = "refs/tags/"
        guard platform.revision.hasPrefix(tagPrefix) else {
            throw RuntimeFailure.invalidOutput(
                "AOSP manifest revision is not a tag: \(platform.revision)")
        }
        try FileManager.default.createDirectory(
            atPath: temporary.string,
            withIntermediateDirectories: true)
        try await aospChecked(
            .named("git"),
            [
                "clone",
                "--quiet",
                "--filter=blob:none",
                "--depth=1",
                "--single-branch",
                "--branch",
                String(platform.revision.dropFirst(tagPrefix.count)),
                platform.manifestURL,
                checkout.string,
            ],
            in: temporary,
            environment: verification.environment,
            stage: stage)
        let manifestCommit = try await aospGitRevision(
            repository: checkout,
            revision: "HEAD",
            environment: verification.environment,
            stage: stage)
        guard manifestCommit == platform.manifestCommit else {
            throw RuntimeFailure.invalidOutput(
                "manifest checkout is \(manifestCommit); expected "
                    + platform.manifestCommit)
        }
        let manifest = checkout.appending("default.xml")
        let manifestDigest = try ArtifactHasher.digest(file: manifest)
        guard manifestDigest == platform.defaultManifestDigest else {
            throw RuntimeFailure.invalidOutput(
                "default.xml digest is \(manifestDigest); expected "
                    + platform.defaultManifestDigest.description)
        }

        let superprojectRefs = try await aospRemoteRefs(
            url: platform.superprojectURL,
            revisions: [platform.superprojectRevision],
            environment: verification.environment,
            stage: stage)
        try requireAOSPRemoteRef(
            superprojectRefs,
            revision: platform.superprojectRevision,
            expected: platform.superprojectCommit,
            description: "superproject revision")

        let repoRefs = try await aospRemoteRefs(
            url: repo.repositoryURL,
            revisions: [repo.revision, repo.revision + "^{}"],
            environment: verification.environment,
            stage: stage)
        try requireAOSPRemoteRef(
            repoRefs,
            revision: repo.revision,
            expected: repo.tagObject,
            description: "Repo tag")
        try requireAOSPRemoteRef(
            repoRefs,
            revision: repo.revision + "^{}",
            expected: repo.commit,
            description: "Repo tag commit")

        let launcherAttributes = try FileManager.default.attributesOfItem(
            atPath: verification.launcher.string)
        guard let launcherSize = launcherAttributes[.size] as? NSNumber,
            launcherSize.int64Value <= 2 * 1_024 * 1_024
        else {
            throw RuntimeFailure.invalidOutput(
                "Repo launcher exceeds the maximum response size")
        }
        let launcherDigest = try ArtifactHasher.digest(
            file: verification.launcher)
        guard launcherDigest == repo.launcherDigest else {
            throw RuntimeFailure.invalidOutput(
                "Repo launcher digest is \(launcherDigest); expected "
                    + repo.launcherDigest.description)
        }
        let launcherData = try Data(
            contentsOf: URL(
                fileURLWithPath: verification.launcher.string))
        let launcherVersion = try aospRepoLauncherVersion(launcherData)
        guard launcherVersion == repo.launcherVersion else {
            throw RuntimeFailure.invalidOutput(
                "Repo launcher version is \(launcherVersion); expected "
                    + repo.launcherVersion)
        }

        try DurableFile.writeJSON(
            AOSPSourceLockReport(
                status: "verified",
                platform: AOSPSourceLockReport.Platform(
                    release: platform.release,
                    revision: platform.revision,
                    manifestTagObject: platform.manifestTagObject,
                    manifestCommit: platform.manifestCommit,
                    defaultManifestSHA256:
                        platform.defaultManifestDigest.sha256Hex,
                    superprojectCommit: platform.superprojectCommit),
                repo: AOSPSourceLockReport.Repo(
                    version: repo.launcherVersion,
                    tagObject: repo.tagObject,
                    commit: repo.commit,
                    launcherSHA256: repo.launcherDigest.sha256Hex)),
            to: verification.report)
    }

    func prepareAOSPSource(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        guard preparation.syncJobs > 0,
            preparation.retryFetches > 0
        else {
            throw RuntimeFailure.invalidOutput(
                "AOSP source concurrency and retry counts must be positive")
        }
        let source = preparation.source
        let parent = source.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let launcherDigest = try ArtifactHasher.digest(
            file: preparation.launcher)
        guard launcherDigest == preparation.specification.repo.launcherDigest
        else {
            throw RuntimeFailure.invalidOutput(
                "Repo launcher digest is \(launcherDigest); expected "
                    + preparation.specification.repo.launcherDigest.description)
        }

        try requireEmptyOrRepo(source)
        try await requireCleanAOSPSource(preparation, stage: stage)
        try await validateExistingAOSPSourceIdentity(
            preparation,
            stage: stage)
        let platform = preparation.specification.platform
        let repo = preparation.specification.repo
        _ = try await aospRepo(
            preparation,
            arguments: [
                "init",
                "--quiet",
                "--partial-clone",
                "--clone-filter=blob:limit=10M",
                "--use-superproject",
                "--no-clone-bundle",
                "--repo-url=\(repo.repositoryURL)",
                "--repo-rev=\(repo.revision)",
                "-u",
                platform.manifestURL,
                "-b",
                platform.revision,
            ],
            output: .logged,
            stage: stage)
        let initialized = try await validateInitializedAOSPSource(
            preparation,
            stage: stage)
        try await requireCleanAOSPSource(preparation, stage: stage)

        _ = try await aospRepo(
            preparation,
            arguments: [
                "sync",
                "--current-branch",
                "--detach",
                "--fail-fast",
                "--no-clone-bundle",
                "--no-tags",
                "--optimized-fetch",
                "--prune",
                "--jobs=\(preparation.syncJobs)",
                "--retry-fetches=\(preparation.retryFetches)",
            ],
            output: .logged,
            stage: stage)
        try await requireCleanAOSPSource(preparation, stage: stage)
        let baseResolvedData = try await aospResolvedManifest(
            preparation,
            stage: stage)
        let baseResolvedDigest = ArtifactHasher.digest(
            bytes: baseResolvedData)
        let metadata = source.appending(".nucleus")
        try DurableFile.write(
            baseResolvedData,
            to: metadata.appending("base-resolved-manifest.xml"))
        let appliedPatches = try await applyAOSPForwardPatches(
            preparation,
            stage: stage)
        try await requireCleanAOSPSource(preparation, stage: stage)
        let patchedResolvedData = try await aospResolvedManifest(
            preparation,
            stage: stage)
        let patchedResolvedDigest = ArtifactHasher.digest(
            bytes: patchedResolvedData)
        try DurableFile.write(
            patchedResolvedData,
            to: metadata.appending("patched-resolved-manifest.xml"))
        let replacedManifest = metadata.appending("resolved-manifest.xml")
        if FileManager.default.fileExists(atPath: replacedManifest.string) {
            try FileManager.default.removeItem(
                atPath: replacedManifest.string)
        }
        try DurableFile.writeJSON(
            AOSPSourceProvenance(
                status: "materialized",
                release: platform.release,
                revision: platform.revision,
                manifestCommit: initialized.manifestCommit,
                superprojectCommit: initialized.superprojectCommit,
                repoCommit: initialized.repoCommit,
                baseResolvedManifestSHA256:
                    baseResolvedDigest.sha256Hex,
                resolvedManifestSHA256:
                    patchedResolvedDigest.sha256Hex,
                forwardPatches: appliedPatches),
            to: metadata.appending("source-provenance.json"))
    }

    private func validateExistingAOSPSourceIdentity(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        let manifest = preparation.source.appending(".repo/manifest.xml")
        guard FileManager.default.fileExists(atPath: manifest.string) else {
            return
        }
        let provenancePath = preparation.source.appending(
            ".nucleus/source-provenance.json")
        guard FileManager.default.fileExists(atPath: provenancePath.string)
        else {
            throw RuntimeFailure.invalidOutput(
                "existing AOSP source has no Nucleus provenance; "
                    + "refusing to move its clean project revisions")
        }
        let provenance = try JSONDecoder().decode(
            AOSPExistingSourceProvenance.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: provenancePath.string)))
        guard provenance.status == "materialized" else {
            throw RuntimeFailure.invalidOutput(
                "existing AOSP source provenance is not materialized")
        }
        let current = try await aospResolvedManifest(
            preparation,
            stage: stage)
        let digest = ArtifactHasher.digest(bytes: current)
        guard digest.sha256Hex == provenance.resolvedManifestSHA256 else {
            throw RuntimeFailure.invalidOutput(
                "existing AOSP project revisions do not match their "
                    + "recorded provenance; refusing to run Repo sync")
        }
    }

    private func aospResolvedManifest(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws -> Data {
        let resolvedManifest =
            try await aospRepo(
                preparation,
                arguments: ["manifest", "--revision-as-HEAD"],
                output: .captured(limit: 32 * 1_024 * 1_024),
                stage: stage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return Data(resolvedManifest.utf8)
    }

    private func applyAOSPForwardPatches(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws -> [AOSPSourceProvenance.ForwardPatchStack] {
        var result: [AOSPSourceProvenance.ForwardPatchStack] = []
        for stack in preparation.patchStacks {
            let repository = preparation.source.appending(
                stack.repositoryPath)
            let topLevel = try await aospCaptured(
                .named("git"),
                ["-C", repository.string, "rev-parse", "--show-toplevel"],
                in: preparation.source,
                environment: preparation.environment,
                stage: stage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(fileURLWithPath: topLevel).standardizedFileURL.path
                    == URL(fileURLWithPath: repository.string)
                        .standardizedFileURL.path
            else {
                throw RuntimeFailure.invalidOutput(
                    "forward-patch repository does not resolve to its "
                        + "declared Repo project: \(stack.repositoryPath)")
            }
            let baseCommit = try await aospGitRevision(
                repository: repository,
                revision: "HEAD",
                environment: preparation.environment,
                stage: stage)
            var patches: [AOSPSourceProvenance.ForwardPatch] = []
            for patch in stack.patches {
                let digest = try ArtifactHasher.digest(file: patch.file)
                try await aospChecked(
                    .named("git"),
                    [
                        "-C", repository.string,
                        "apply", "--index", "--whitespace=error-all",
                        patch.file.string,
                    ],
                    in: preparation.source,
                    environment: preparation.environment,
                    stage: stage)
                patches.append(AOSPSourceProvenance.ForwardPatch(
                    path: patch.path,
                    sha256: digest.sha256Hex))
            }
            let stagedFiles = try await aospCaptured(
                .named("git"),
                [
                    "-C", repository.string,
                    "diff", "--cached", "--name-only",
                ],
                in: preparation.source,
                environment: preparation.environment,
                stage: stage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stagedFiles.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "forward-patch stack produced no changes: "
                        + stack.repositoryPath)
            }
            let commitEnvironment = preparation.environment.merging([
                "GIT_AUTHOR_NAME": "Nucleus Source Lock",
                "GIT_AUTHOR_EMAIL": "source-lock@nucleus.invalid",
                "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
                "GIT_COMMITTER_NAME": "Nucleus Source Lock",
                "GIT_COMMITTER_EMAIL": "source-lock@nucleus.invalid",
                "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
                "LC_ALL": "C",
                "TZ": "UTC",
            ]) { _, required in required }
            try await aospChecked(
                .named("git"),
                [
                    "-C", repository.string,
                    "commit", "--quiet", "--no-gpg-sign", "--no-verify",
                    "--message",
                    "Nucleus forward patches: \(stack.repositoryPath)",
                ],
                in: preparation.source,
                environment: commitEnvironment,
                stage: stage)
            let patchedCommit = try await aospGitRevision(
                repository: repository,
                revision: "HEAD",
                environment: preparation.environment,
                stage: stage)
            let patchedTree = try await aospGitRevision(
                repository: repository,
                revision: "HEAD^{tree}",
                environment: preparation.environment,
                stage: stage)
            result.append(AOSPSourceProvenance.ForwardPatchStack(
                repositoryPath: stack.repositoryPath,
                baseCommit: baseCommit,
                patchedCommit: patchedCommit,
                patchedTree: patchedTree,
                patches: patches))
        }
        return result
    }

    private func aospRemoteRefs(
        url: String,
        revisions: [String],
        environment: [String: String],
        stage: TaskID
    ) async throws -> [String: String] {
        let output = try await aospCaptured(
            .named("git"),
            ["ls-remote", url] + revisions,
            in: FilePath("/"),
            environment: environment,
            stage: stage)
        var refs: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "\t", maxSplits: 1)
            guard pieces.count == 2 else {
                throw RuntimeFailure.invalidOutput(
                    "git ls-remote returned a malformed record for \(url)")
            }
            refs[String(pieces[1])] = String(pieces[0])
        }
        return refs
    }

    private func aospGitRevision(
        repository: FilePath,
        revision: String,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        try await aospCaptured(
            .named("git"),
            ["-C", repository.string, "rev-parse", revision],
            in: repository,
            environment: environment,
            stage: stage
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func aospRepo(
        _ preparation: AOSPSourcePreparation,
        arguments: [String],
        output: CommandSpec.Output,
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: .named("python3"),
                arguments: [preparation.launcher.string] + arguments,
                workingDirectory: preparation.source,
                environment: preparation.environment,
                output: output),
            stage: stage)
        guard result.status == 0 else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw RuntimeFailure.invalidOutput(
                "Repo \(arguments.first ?? "command") failed"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result.standardOutput
    }

    private func requireCleanAOSPSource(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        let manifest = preparation.source.appending(".repo/manifest.xml")
        guard FileManager.default.fileExists(atPath: manifest.string) else {
            return
        }
        let command =
            #"if test ! -e .git; then exit 0; fi; "#
            + #"dirty="$(git status --porcelain=v1 --untracked-files=normal)"; "#
            + #"if test -n "$dirty"; then "#
            + #"printf "%s\n%s\n" "$REPO_PATH" "$dirty" >&2; exit 1; fi"#
        _ = try await aospRepo(
            preparation,
            arguments: [
                "forall",
                "--ignore-missing",
                "--jobs=1",
                "--verbose",
                "-c",
                command,
            ],
            output: .captured(limit: 16 * 1_024 * 1_024),
            stage: stage)
    }

    private func validateInitializedAOSPSource(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws -> AOSPInitializedSource {
        let platform = preparation.specification.platform
        let repo = preparation.specification.repo
        let manifestRepository = preparation.source.appending(
            ".repo/manifests")
        let manifestCommit = try await aospGitRevision(
            repository: manifestRepository,
            revision: "HEAD",
            environment: preparation.environment,
            stage: stage)
        guard manifestCommit == platform.manifestCommit else {
            throw RuntimeFailure.invalidOutput(
                "manifest checkout is \(manifestCommit); expected "
                    + platform.manifestCommit)
        }
        let repoCommit = try await aospGitRevision(
            repository: preparation.source.appending(".repo/repo"),
            revision: "HEAD",
            environment: preparation.environment,
            stage: stage)
        guard repoCommit == repo.commit else {
            throw RuntimeFailure.invalidOutput(
                "Repo checkout is \(repoCommit); expected \(repo.commit)")
        }
        let manifest = manifestRepository.appending("default.xml")
        let manifestDigest = try ArtifactHasher.digest(file: manifest)
        guard manifestDigest == platform.defaultManifestDigest else {
            throw RuntimeFailure.invalidOutput(
                "default manifest digest is \(manifestDigest); expected "
                    + platform.defaultManifestDigest.description)
        }
        let superprojectRoot = preparation.source.appending(
            ".repo/exp-superproject")
        let superprojects = try FileManager.default.contentsOfDirectory(
            atPath: superprojectRoot.string
        )
        .filter { $0.hasSuffix("-superproject.git") }
        .sorted()
        guard superprojects.count == 1 else {
            throw RuntimeFailure.invalidOutput(
                "Repo must materialize exactly one pinned experimental "
                    + "superproject checkout")
        }
        let superprojectCommit = try await aospGitRevision(
            repository: superprojectRoot.appending(superprojects[0]),
            revision: platform.superprojectRevision,
            environment: preparation.environment,
            stage: stage)
        guard superprojectCommit == platform.superprojectCommit else {
            throw RuntimeFailure.invalidOutput(
                "superproject revision \(platform.superprojectRevision) is "
                    + "\(superprojectCommit); expected "
                    + platform.superprojectCommit)
        }
        return AOSPInitializedSource(
            manifestCommit: manifestCommit,
            repoCommit: repoCommit,
            superprojectCommit: superprojectCommit)
    }

    private func aospCaptured(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: .captured(limit: 32 * 1_024 * 1_024)),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.invalidOutput(
                "\(arguments.first ?? "command") failed: "
                    + result.standardOutput.trimmingCharacters(
                        in: .whitespacesAndNewlines))
        }
        return result.standardOutput
    }

    private func aospChecked(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        _ = try await aospCaptured(
            executable,
            arguments,
            in: directory,
            environment: environment,
            stage: stage)
    }
}

private func requireAOSPRemoteRef(
    _ refs: [String: String],
    revision: String,
    expected: String,
    description: String
) throws {
    guard refs[revision] == expected else {
        throw RuntimeFailure.invalidOutput(
            "\(description) resolved to \(refs[revision] ?? "nothing"); "
                + "expected \(expected)")
    }
}

private func requireEmptyOrRepo(_ source: FilePath) throws {
    let manager = FileManager.default
    if !manager.fileExists(atPath: source.string) {
        try manager.createDirectory(
            atPath: source.string,
            withIntermediateDirectories: true)
        return
    }
    var isDirectory = ObjCBool(false)
    if manager.fileExists(
        atPath: source.appending(".repo").string,
        isDirectory: &isDirectory),
        isDirectory.boolValue
    {
        return
    }
    let entries = try manager.contentsOfDirectory(atPath: source.string)
    guard entries.isEmpty else {
        throw RuntimeFailure.invalidOutput(
            "\(source) exists without Repo metadata and is not empty; "
                + "refusing to overwrite it")
    }
}

private func aospRepoLauncherVersion(_ data: Data) throws -> String {
    let contents = String(decoding: data, as: UTF8.self)
    let prefix = "VERSION = ("
    guard
        let line = contents.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(")") })
    else {
        throw RuntimeFailure.invalidOutput(
            "Repo launcher does not declare a recognizable version")
    }
    let components =
        line
        .dropFirst(prefix.count)
        .dropLast()
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard components.count == 2,
        components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    else {
        throw RuntimeFailure.invalidOutput(
            "Repo launcher does not declare a recognizable version")
    }
    return components.joined(separator: ".")
}

private extension ArtifactDigest {
    var sha256Hex: String {
        let prefix = "sha256:"
        precondition(description.hasPrefix(prefix))
        return String(description.dropFirst(prefix.count))
    }
}

private struct AOSPInitializedSource {
    let manifestCommit: String
    let repoCommit: String
    let superprojectCommit: String
}

private struct AOSPSourceLockReport: Encodable {
    struct Platform: Encodable {
        let release: String
        let revision: String
        let manifestTagObject: String
        let manifestCommit: String
        let defaultManifestSHA256: String
        let superprojectCommit: String
    }

    struct Repo: Encodable {
        let version: String
        let tagObject: String
        let commit: String
        let launcherSHA256: String
    }

    let status: String
    let platform: Platform
    let repo: Repo
}

private struct AOSPSourceProvenance: Encodable {
    struct ForwardPatch: Encodable {
        let path: String
        let sha256: String
    }

    struct ForwardPatchStack: Encodable {
        let repositoryPath: String
        let baseCommit: String
        let patchedCommit: String
        let patchedTree: String
        let patches: [ForwardPatch]
    }

    let status: String
    let release: String
    let revision: String
    let manifestCommit: String
    let superprojectCommit: String
    let repoCommit: String
    let baseResolvedManifestSHA256: String
    let resolvedManifestSHA256: String
    let forwardPatches: [ForwardPatchStack]
}

private struct AOSPExistingSourceProvenance: Decodable {
    let status: String
    let resolvedManifestSHA256: String
}
