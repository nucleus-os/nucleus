import ColliderCore
import Foundation
import SystemPackage

struct AOSPPlatformSource: Hashable, Sendable {
    let release: String
    let revision: String
    let manifestURL: String
    let manifestRevision: String
    let manifestCommit: String
    let defaultManifestDigest: ArtifactDigest
    let superprojectURL: String
    let superprojectRevision: String
    let superprojectCommit: String
}

struct AOSPRepoSource: Hashable, Sendable {
    let launcherVersion: String
    let launcherDigest: ArtifactDigest
    let repositoryURL: String
    let revision: String
    let tagObject: String
    let commit: String
}

struct AOSPSourceSpecification: Hashable, Sendable {
    let platform: AOSPPlatformSource
    let repo: AOSPRepoSource
}

struct AOSPSourceLockVerification: Hashable, Sendable {
    let specification: AOSPSourceSpecification
    let launcher: FilePath
    let report: FilePath
    let environment: [String: String]
}

struct AOSPSourcePreparation: Hashable, Sendable {
    let specification: AOSPSourceSpecification
    let launcher: FilePath
    let source: FilePath
    let syncJobs: UInt32
    let retryFetches: UInt32
    let environment: [String: String]
}

struct VerifyAOSPSourceLockAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let specification: AOSPSourceSpecification
        let launcher: FilePath
        let report: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encodeAOSPSourceSpecification(specification, into: &encoder)
            encoder.append(tag: 20, string: launcher.string)
            encoder.append(tag: 21, string: report.string)
        }
    }

    static let kind: ActionKind = "android-runtime.verify-aosp-source-lock"

    let verification: AOSPSourceLockVerification

    var identity: Identity {
        Identity(
            specification: verification.specification,
            launcher: verification.launcher,
            report: verification.report)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git",
                    executable: .named("git"),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(verification.launcher)),
                ActionEffect(.readWrite, scope: .scratch(scratch)),
                ActionEffect(.write, scope: .output(verification.report)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    var environment: [String: String] { verification.environment }

    private var scratch: FilePath {
        verification.report.removingLastComponent().appending(
            "source-lock-scratch")
    }

    func execute(in context: ActionContext) async throws {
        try await AOSPSourceWorkflow(context: context).verifyAOSPSourceLock(
            verification,
            scratch: scratch,
            stage: TaskID(rawValue: "android-runtime.verify-aosp-source-lock"))
    }
}

struct PrepareAOSPSourceAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let specification: AOSPSourceSpecification
        let launcher: FilePath
        let source: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encodeAOSPSourceSpecification(specification, into: &encoder)
            encoder.append(tag: 20, string: launcher.string)
            encoder.append(tag: 21, string: source.string)
        }
    }

    static let kind: ActionKind = "android-runtime.prepare-aosp-source"

    let preparation: AOSPSourcePreparation

    var identity: Identity {
        Identity(
            specification: preparation.specification,
            launcher: preparation.launcher,
            source: preparation.source)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git",
                    executable: .named("git"),
                    role: .operational),
                ActionToolRequirement(
                    "python3",
                    executable: .named("python3"),
                    role: .operational),
            ],
            effects: [
                ActionEffect(.read, scope: .input(preparation.launcher)),
                ActionEffect(.readWrite, scope: .checkout(preparation.source)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    var environment: [String: String] { preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await AOSPSourceWorkflow(context: context).prepareAOSPSource(
            preparation,
            stage: TaskID(rawValue: "android-runtime.prepare-aosp-source"))
    }
}

private func encodeAOSPSourceSpecification(
    _ specification: AOSPSourceSpecification,
    into encoder: inout ActionIdentityEncoder
) {
    let platform = specification.platform
    encoder.append(tag: 1, string: platform.release)
    encoder.append(tag: 2, string: platform.revision)
    encoder.append(tag: 3, string: platform.manifestURL)
    encoder.append(tag: 4, string: platform.manifestRevision)
    encoder.append(tag: 5, string: platform.manifestCommit)
    encoder.append(tag: 6, bytes: platform.defaultManifestDigest.bytes)
    encoder.append(tag: 7, string: platform.superprojectURL)
    encoder.append(tag: 8, string: platform.superprojectRevision)
    encoder.append(tag: 9, string: platform.superprojectCommit)
    let repo = specification.repo
    encoder.append(tag: 10, string: repo.launcherVersion)
    encoder.append(tag: 11, bytes: repo.launcherDigest.bytes)
    encoder.append(tag: 12, string: repo.repositoryURL)
    encoder.append(tag: 13, string: repo.revision)
    encoder.append(tag: 14, string: repo.tagObject)
    encoder.append(tag: 15, string: repo.commit)
}

private struct AOSPSourceWorkflow {
    let context: ActionContext

    func verifyAOSPSourceLock(
        _ verification: AOSPSourceLockVerification,
        scratch: FilePath,
        stage: TaskID
    ) async throws {
        let specification = verification.specification
        let platform = specification.platform
        let repo = specification.repo
        try context.files.remove(scratch)
        try context.files.createDirectory(scratch)
        defer {
            try? context.files.remove(scratch)
        }

        let manifestRefs = try await aospRemoteRefs(
            url: platform.manifestURL,
            revisions: [platform.manifestRevision],
            in: scratch,
            environment: verification.environment,
            stage: stage)
        try requireAOSPRemoteRef(
            manifestRefs,
            revision: platform.manifestRevision,
            expected: platform.manifestCommit,
            description: "manifest revision")

        let temporary = scratch.appending("manifest-checkout")
        let checkout = temporary.appending("manifest")
        try context.files.remove(temporary)
        try context.files.createDirectory(temporary)
        try await aospChecked(
            .named("git"),
            [
                "init",
                "--quiet",
                checkout.string,
            ],
            in: temporary,
            environment: verification.environment,
            stage: stage)
        try await aospChecked(
            .named("git"),
            [
                "-C", checkout.string,
                "fetch",
                "--quiet",
                "--depth=1",
                platform.manifestURL,
                platform.manifestRevision,
            ],
            in: temporary,
            environment: verification.environment,
            stage: stage)
        try await aospChecked(
            .named("git"),
            [
                "-C", checkout.string,
                "checkout",
                "--quiet",
                "--detach",
                platform.manifestCommit,
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
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "manifest checkout is \(manifestCommit); expected "
                    + platform.manifestCommit)
        }
        let manifest = checkout.appending("default.xml")
        let manifestDigest = try context.files.digest(file: manifest)
        guard manifestDigest == platform.defaultManifestDigest else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "default.xml digest is \(manifestDigest); expected "
                    + platform.defaultManifestDigest.description)
        }

        let superprojectRefs = try await aospRemoteRefs(
            url: platform.superprojectURL,
            revisions: [platform.superprojectRevision],
            in: scratch,
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
            in: scratch,
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

        guard
            let launcherMetadata = try context.files.metadata(
                for: verification.launcher),
            launcherMetadata.size <= 2 * 1_024 * 1_024
        else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo launcher exceeds the maximum response size")
        }
        let launcherDigest = try context.files.digest(
            file:
                verification.launcher)
        guard launcherDigest == repo.launcherDigest else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo launcher digest is \(launcherDigest); expected "
                    + repo.launcherDigest.description)
        }
        let launcherData = Data(try context.files.read(verification.launcher))
        let launcherVersion = try aospRepoLauncherVersion(launcherData)
        guard launcherVersion == repo.launcherVersion else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo launcher version is \(launcherVersion); expected "
                    + repo.launcherVersion)
        }

        let report = AOSPSourceLockReport(
            status: "verified",
            platform: AOSPSourceLockReport.Platform(
                release: platform.release,
                revision: platform.revision,
                manifestCommit: platform.manifestCommit,
                defaultManifestSHA256:
                    platform.defaultManifestDigest.sha256Hex,
                superprojectCommit: platform.superprojectCommit),
            repo: AOSPSourceLockReport.Repo(
                version: repo.launcherVersion,
                tagObject: repo.tagObject,
                commit: repo.commit,
                launcherSHA256: repo.launcherDigest.sha256Hex))
        try context.files.write(
            Array(try JSONEncoder().encode(report)),
            to: verification.report)
    }

    func prepareAOSPSource(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        guard preparation.syncJobs > 0,
            preparation.retryFetches > 0
        else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "AOSP source concurrency and retry counts must be positive")
        }
        let source = preparation.source
        let launcherDigest = try context.files.digest(file: preparation.launcher)
        guard launcherDigest == preparation.specification.repo.launcherDigest
        else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo launcher digest is \(launcherDigest); expected "
                    + preparation.specification.repo.launcherDigest.description)
        }

        try requireEmptyOrRepo(source, files: context.files)
        for obsolete in [
            "base-resolved-manifest.xml",
            "patched-resolved-manifest.xml",
        ] {
            let path = source.appending(".nucleus").appending(obsolete)
            if try context.files.metadataWithoutFollowingSymlinks(for: path) != nil {
                try context.files.remove(path)
            }
        }
        let platform = preparation.specification.platform
        let repo = preparation.specification.repo
        if let existing = try await validateExistingAOSPSourceIdentity(
            preparation,
            stage: stage),
            existing.release == platform.release,
            existing.revision == platform.revision,
            existing.manifestCommit == platform.manifestCommit,
            existing.superprojectCommit == platform.superprojectCommit,
            existing.repoCommit == repo.commit
        {
            try await requireCleanAOSPSource(preparation, stage: stage)
            return
        }
        let superprojectRoot = source.appending(".repo/exp-superproject")
        if try context.files.metadataWithoutFollowingSymlinks(for: superprojectRoot) != nil {
            try context.files.remove(superprojectRoot)
        }

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
                platform.manifestRevision,
            ],
            output: .logged,
            stage: stage)
        let initialized = try await validateInitializedAOSPSource(
            preparation,
            stage: stage)

        _ = try await aospRepo(
            preparation,
            arguments: [
                "sync",
                "--current-branch",
                "--detach",
                "--fail-fast",
                "--force-checkout",
                "--force-sync",
                "--no-clone-bundle",
                "--no-interleaved",
                "--no-tags",
                "--optimized-fetch",
                "--prune",
                "--jobs-network=\(preparation.syncJobs)",
                "--jobs-checkout=1",
                "--retry-fetches=\(preparation.retryFetches)",
            ],
            output: .logged,
            stage: stage)
        try await requireCleanAOSPSource(preparation, stage: stage)
        let superprojectCommit = try await validateAOSPSuperproject(
            preparation,
            stage: stage)
        let resolvedData = try await aospResolvedManifest(
            preparation,
            stage: stage)
        try await verifyAOSPResolvedManifest(
            resolvedData,
            againstSuperproject: superprojectCommit,
            preparation: preparation,
            stage: stage)
        let metadata = source.appending(".nucleus")
        for obsolete in [
            "base-resolved-manifest.xml",
            "patched-resolved-manifest.xml",
        ] {
            let path = metadata.appending(obsolete)
            if try context.files.metadataWithoutFollowingSymlinks(for: path) != nil {
                try context.files.remove(path)
            }
        }
        try context.cancellation.check()
        let resolvedManifest = metadata.appending("resolved-manifest.xml")
        try context.files.write(
            Array(resolvedData),
            to: resolvedManifest)
        let resolvedDigest = try context.files.digest(file: resolvedManifest)
        let provenance = AOSPSourceProvenance(
            status: "materialized",
            release: platform.release,
            revision: platform.revision,
            manifestCommit: initialized.manifestCommit,
            superprojectCommit: superprojectCommit,
            repoCommit: initialized.repoCommit,
            resolvedManifestSHA256: resolvedDigest.sha256Hex)
        try context.files.write(
            Array(try JSONEncoder().encode(provenance)),
            to: metadata.appending("source-provenance.json"))
    }

    private func validateExistingAOSPSourceIdentity(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws -> AOSPSourceProvenance? {
        let manifest = preparation.source.appending(".repo/manifest.xml")
        guard try context.files.metadata(for: manifest) != nil else {
            return nil
        }
        let provenancePath = preparation.source.appending(
            ".nucleus/source-provenance.json")
        guard try context.files.metadata(for: provenancePath) != nil
        else {
            return nil
        }
        let provenance = try JSONDecoder().decode(
            AOSPSourceProvenance.self,
            from: Data(try context.files.read(provenancePath)))
        guard provenance.status == "materialized" else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "existing AOSP source provenance is not materialized")
        }
        let platform = preparation.specification.platform
        let repo = preparation.specification.repo
        guard provenance.release == platform.release,
            provenance.revision == platform.revision,
            provenance.manifestCommit == platform.manifestCommit,
            provenance.superprojectCommit == platform.superprojectCommit,
            provenance.repoCommit == repo.commit
        else {
            return nil
        }
        let current = try await aospResolvedManifest(
            preparation,
            stage: stage)
        let resolvedManifest = preparation.source.appending(
            ".nucleus/resolved-manifest.xml")
        guard Data(try context.files.read(resolvedManifest)) == current else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "existing AOSP project revisions do not match their "
                    + "recorded resolved manifest; refusing to run Repo sync")
        }
        let digest = try context.files.digest(file: resolvedManifest)
        guard digest.sha256Hex == provenance.resolvedManifestSHA256 else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "existing AOSP project revisions do not match their "
                    + "recorded provenance; refusing to run Repo sync")
        }
        return provenance
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

    private func verifyAOSPResolvedManifest(
        _ manifest: Data,
        againstSuperproject superprojectCommit: String,
        preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        let superprojectRoot = preparation.source.appending(
            ".repo/exp-superproject")
        let superprojects = try directoryNames(
            in: superprojectRoot,
            suffix: "-superproject.git")
        guard superprojects.count == 1 else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo must materialize exactly one pinned superproject")
        }
        let tree = try await aospCaptured(
            .named("git"),
            [
                "--git-dir",
                superprojectRoot.appending(superprojects[0]).string,
                "ls-tree", "-r", "--full-tree", superprojectCommit,
            ],
            in: preparation.source,
            environment: preparation.environment,
            stage: stage)
        var expected: [String: String] = [:]
        for line in tree.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            let identity = fields[0].split(separator: " ")
            guard fields.count == 2, identity.count == 3,
                identity[0] == "160000", identity[1] == "commit"
            else {
                continue
            }
            expected[String(fields[1])] = String(identity[2])
        }

        var resolved: [String: String] = [:]
        for line in String(decoding: manifest, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        where line.contains("<project ") {
            let record = String(line)
            guard
                let revision = aospManifestAttribute(
                    "revision", in: record),
                let path = aospManifestAttribute("path", in: record)
                    ?? aospManifestAttribute("name", in: record),
                resolved.updateValue(revision, forKey: path) == nil
            else {
                throw AOSPSourceWorkflowFailure.invalidOutput(
                    "resolved manifest contains an invalid project record")
            }
        }
        if let mismatch = resolved.keys.sorted()
            .first(where: { resolved[$0] != expected[$0] })
        {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "resolved manifest does not match superproject at \(mismatch)")
        }
    }

    private func aospRemoteRefs(
        url: String,
        revisions: [String],
        in directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> [String: String] {
        let output = try await aospCaptured(
            .named("git"),
            ["ls-remote", url] + revisions,
            in: directory,
            environment: environment,
            stage: stage)
        var refs: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "\t", maxSplits: 1)
            guard pieces.count == 2 else {
                throw AOSPSourceWorkflowFailure.invalidOutput(
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
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("python3"),
                arguments: [preparation.launcher.string] + arguments,
                workingDirectory: preparation.source,
                environment: preparation.environment,
                output: output))
        guard result.succeeded else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw result.executionFailure(
                reason: "Repo \(arguments.first ?? "command") failed"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result.standardOutput
    }

    private func requireCleanAOSPSource(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws {
        let manifest = preparation.source.appending(".repo/manifest.xml")
        guard try context.files.metadata(for: manifest) != nil else {
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
                "--jobs=\(preparation.syncJobs)",
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
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "manifest checkout is \(manifestCommit); expected "
                    + platform.manifestCommit)
        }
        let repoCommit = try await aospGitRevision(
            repository: preparation.source.appending(".repo/repo"),
            revision: "HEAD",
            environment: preparation.environment,
            stage: stage)
        guard repoCommit == repo.commit else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo checkout is \(repoCommit); expected \(repo.commit)")
        }
        let manifest = manifestRepository.appending("default.xml")
        let manifestDigest = try context.files.digest(file: manifest)
        guard manifestDigest == platform.defaultManifestDigest else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "default manifest digest is \(manifestDigest); expected "
                    + platform.defaultManifestDigest.description)
        }
        return AOSPInitializedSource(
            manifestCommit: manifestCommit,
            repoCommit: repoCommit)
    }

    private func validateAOSPSuperproject(
        _ preparation: AOSPSourcePreparation,
        stage: TaskID
    ) async throws -> String {
        let platform = preparation.specification.platform
        let superprojectRoot = preparation.source.appending(
            ".repo/exp-superproject")
        let superprojects = try directoryNames(
            in: superprojectRoot,
            suffix: "-superproject.git")
        guard superprojects.count == 1 else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "Repo must materialize exactly one pinned experimental "
                    + "superproject checkout")
        }
        let superprojectCommit = try await aospGitRevision(
            repository: superprojectRoot.appending(superprojects[0]),
            revision: platform.superprojectCommit,
            environment: preparation.environment,
            stage: stage)
        guard superprojectCommit == platform.superprojectCommit else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "superproject revision \(platform.superprojectRevision) is "
                    + "\(superprojectCommit); expected "
                    + platform.superprojectCommit)
        }
        return superprojectCommit
    }

    private func aospCaptured(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: .captured(limit: 32 * 1_024 * 1_024)))
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "\(arguments.first ?? "command") failed: "
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

    private func directoryNames(
        in directory: FilePath,
        suffix: String
    ) throws -> [String] {
        try context.files.listRecursively(directory)
            .filter {
                !$0.relativePath.contains("/")
                    && $0.metadata.type == .directory
                    && $0.relativePath.hasSuffix(suffix)
            }
            .map(\.relativePath)
            .sorted()
    }
}

private func aospManifestAttribute(
    _ name: String,
    in element: String
) -> String? {
    let prefix = "\(name)=\""
    guard let start = element.range(of: prefix) else {
        return nil
    }
    let valueStart = start.upperBound
    guard let end = element[valueStart...].firstIndex(of: "\"") else {
        return nil
    }
    return String(element[valueStart..<end])
}

private func requireAOSPRemoteRef(
    _ refs: [String: String],
    revision: String,
    expected: String,
    description: String
) throws {
    guard refs[revision] == expected else {
        throw AOSPSourceWorkflowFailure.invalidOutput(
            "\(description) resolved to \(refs[revision] ?? "nothing"); "
                + "expected \(expected)")
    }
}

private func requireEmptyOrRepo(
    _ source: FilePath,
    files: ActionFileSystem
) throws {
    if try files.metadata(for: source) == nil {
        try files.createDirectory(source)
        return
    }
    if try files.metadata(for: source.appending(".repo"))?.type == .directory {
        return
    }
    let entries = try files.listRecursively(source)
    guard entries.isEmpty else {
        throw AOSPSourceWorkflowFailure.invalidOutput(
            "\(source) exists without Repo metadata and is not empty; "
                + "refusing to overwrite it")
    }
}

private enum AOSPSourceWorkflowFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let message): message
        }
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
        throw AOSPSourceWorkflowFailure.invalidOutput(
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
        throw AOSPSourceWorkflowFailure.invalidOutput(
            "Repo launcher does not declare a recognizable version")
    }
    return components.joined(separator: ".")
}

extension ArtifactDigest {
    fileprivate var sha256Hex: String {
        let prefix = "sha256:"
        precondition(description.hasPrefix(prefix))
        return String(description.dropFirst(prefix.count))
    }
}

private struct AOSPInitializedSource {
    let manifestCommit: String
    let repoCommit: String
}

private struct AOSPSourceLockReport: Encodable {
    struct Platform: Encodable {
        let release: String
        let revision: String
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

private struct AOSPSourceProvenance: Codable {
    let status: String
    let release: String
    let revision: String
    let manifestCommit: String
    let superprojectCommit: String
    let repoCommit: String
    let resolvedManifestSHA256: String
}
