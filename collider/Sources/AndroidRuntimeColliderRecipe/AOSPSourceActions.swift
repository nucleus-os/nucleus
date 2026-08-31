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

struct AOSPSourceInputPreparation: Hashable, Sendable {
    let specification: AOSPSourceSpecification
    let launcher: FilePath
    let sourceInputs: FilePath
    let hydrationScript: FilePath
    let resolvedManifest: FilePath
    let provenance: FilePath
    let syncJobs: UInt32
    let retryFetches: UInt32
    let environment: [String: String]

    var source: FilePath { sourceInputs }
}

struct AOSPSourceMaterialization: Hashable, Sendable {
    let specification: AOSPSourceSpecification
    let launcher: FilePath
    let sourceInputs: FilePath
    let resolvedManifest: FilePath
    let provenance: FilePath
    let exportedResolvedManifest: FilePath
    let exportedProvenance: FilePath
    let script: FilePath
    let entrypoint: OCIMountedEntrypoint
    let sourceWorkspace: PersistentWorkspaceDeclaration
    let syncJobs: UInt32
    let environment: [String: String]
}

struct VerifyAOSPSourceLockAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let specification: AOSPSourceSpecification
        let launcher: FilePath
        let report: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encodeAOSPSourceSpecification(specification, into: &encoder)
            encoder.append(path: launcher)
            encoder.append(path: report)
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
            networkAccess: .contentAddressed,
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

struct PrepareAOSPSourceInputsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let specification: AOSPSourceSpecification
        let launcher: FilePath
        let sourceInputs: FilePath
        let hydrationScript: FilePath
        let resolvedManifest: FilePath
        let provenance: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encodeAOSPSourceSpecification(specification, into: &encoder)
            encoder.append(path: launcher)
            encoder.append(path: sourceInputs)
            encoder.append(path: hydrationScript)
            encoder.append(path: resolvedManifest)
            encoder.append(path: provenance)
        }
    }

    static let kind: ActionKind = "android-runtime.prepare-aosp-source-inputs"

    let preparation: AOSPSourceInputPreparation

    var identity: Identity {
        Identity(
            specification: preparation.specification,
            launcher: preparation.launcher,
            sourceInputs: preparation.sourceInputs,
            hydrationScript: preparation.hydrationScript,
            resolvedManifest: preparation.resolvedManifest,
            provenance: preparation.provenance)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "bash",
                    executable: .named("bash"),
                    role: .operational),
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
                ActionEffect(.read, scope: .input(preparation.hydrationScript)),
                ActionEffect(.readWrite, scope: .output(preparation.sourceInputs)),
                ActionEffect(
                    .readWrite,
                    scope: .output(preparation.resolvedManifest)),
                ActionEffect(.readWrite, scope: .output(preparation.provenance)),
            ],
            lane: .hostExclusive,
            networkAccess: .contentAddressed,
            executionPlatform: .macOSARM64Native)
    }

    var environment: [String: String] { preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await AOSPSourceWorkflow(context: context).prepareAOSPSourceInputs(
            preparation,
            stage: TaskID(rawValue: "android-runtime.prepare-aosp-source-inputs"))
    }
}

struct MaterializeAOSPSourceAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let materialization: AOSPSourceMaterialization

        func encode(into encoder: inout IdentityEncoder) {
            encodeAOSPSourceSpecification(
                materialization.specification,
                into: &encoder)
            encoder.append(path: materialization.launcher)
            encoder.append(path: materialization.sourceInputs)
            encoder.append(path: materialization.resolvedManifest)
            encoder.append(path: materialization.provenance)
            encoder.append(path: materialization.script)
            encoder.append(path: materialization.entrypoint.image.path)
            encoder.append(path: materialization.entrypoint.executable)
            encoder.append(materialization.entrypoint.containerPath)
            encoder.append(materialization.sourceWorkspace.identity.key)
            encoder.append(materialization.sourceWorkspace.capacityBytes)
        }
    }

    static let kind: ActionKind = "android-runtime.materialize-aosp-source"

    let materialization: AOSPSourceMaterialization

    var identity: Identity { Identity(materialization: materialization) }

    private var export: FilePath {
        materialization.exportedProvenance.removingLastComponent()
    }

    private var launcherDirectory: FilePath {
        materialization.launcher.removingLastComponent()
    }

    private var sourceLockDirectory: FilePath {
        materialization.provenance.removingLastComponent()
    }

    private var toolingDirectory: FilePath {
        materialization.script.removingLastComponent()
    }

    var requirements: ActionRequirements {
        // The entrypoint executable is one of the tools, so its mount names a
        // directory this already reaches under another target.
        let effects = [
            ActionEffect(.read, scope: .input(launcherDirectory)),
            ActionEffect(.read, scope: .input(materialization.sourceInputs)),
            ActionEffect(.read, scope: .input(sourceLockDirectory)),
            ActionEffect(.read, scope: .input(toolingDirectory)),
            ActionEffect(
                .read,
                scope: .input(materialization.entrypoint.image.path)),
            materialization.entrypoint.effect,
            ActionEffect(.readWrite, scope: .output(export)),
        ].uniqued()
        return ActionRequirements(
            effects: effects,
            persistentWorkspaceEffects: [
                ActionPersistentWorkspaceEffect(
                    workspace: materialization.sourceWorkspace,
                    target: "/src",
                    access: .readWrite)
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64)
    }

    var environment: [String: String] { materialization.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(export)
        let execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            // Materialization checks source out; it produces no artifact for a
            // target, so it names the platform it runs on.
            artifactTarget: .linuxARM64,
            imageID: materialization.entrypoint.image.path,
            hostname: "aosp-source",
            workingDirectory: "/src",
            hostWorkingDirectory: export,
            mounts: [
                materialization.entrypoint.mount,
                OCIMount(
                    source: launcherDirectory,
                    target: "/inputs/repo-launcher",
                    access: .readOnly),
                OCIMount(
                    source: materialization.sourceInputs,
                    target: "/inputs/source-inputs",
                    access: .readOnly),
                OCIMount(
                    source: sourceLockDirectory,
                    target: "/inputs/source-lock",
                    access: .readOnly),
                OCIMount(
                    source: toolingDirectory,
                    target: "/inputs/tooling",
                    access: .readOnly),
                OCIMount(boundedExport: export, target: "/export"),
            ],
            persistentWorkspaceMounts: [
                OCIPersistentWorkspaceMount(
                    workspace: materialization.sourceWorkspace,
                    target: "/src",
                    access: .readWrite)
            ],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .parallelBuild,
            containerEnvironment: [
                "AOSP_SYNC_JOBS": String(materialization.syncJobs),
                "AOSP_REPO_LAUNCHER":
                    "/inputs/repo-launcher/"
                    + (materialization.launcher.lastComponent?.string ?? "repo"),
                "AOSP_RESOLVED_MANIFEST":
                    "/inputs/source-lock/"
                    + (materialization.resolvedManifest.lastComponent?.string
                        ?? "resolved-manifest.xml"),
                "AOSP_SOURCE_PROVENANCE":
                    "/inputs/source-lock/"
                    + (materialization.provenance.lastComponent?.string
                        ?? "source-provenance.json"),
                "HOME": "/home/nucleus-build",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "TZ": "UTC",
            ],
            imageEntrypointOverride: materialization.entrypoint.containerPath,
            command: [
                "source",
                "/inputs/tooling/"
                    + (materialization.script.lastComponent?.string
                        ?? "materialize-source.sh"),
            ],
            environment: materialization.environment,
            output: .logged)
        try await context.containers.run(execution)
    }
}

private func encodeAOSPSourceSpecification(
    _ specification: AOSPSourceSpecification,
    into encoder: inout IdentityEncoder
) {
    let platform = specification.platform
    encoder.append(platform.release)
    encoder.append(platform.revision)
    encoder.append(platform.manifestURL)
    encoder.append(platform.manifestRevision)
    encoder.append(platform.manifestCommit)
    encoder.append(bytes: platform.defaultManifestDigest.bytes)
    encoder.append(platform.superprojectURL)
    encoder.append(platform.superprojectRevision)
    encoder.append(platform.superprojectCommit)
    let repo = specification.repo
    encoder.append(repo.launcherVersion)
    encoder.append(bytes: repo.launcherDigest.bytes)
    encoder.append(repo.repositoryURL)
    encoder.append(repo.revision)
    encoder.append(repo.tagObject)
    encoder.append(repo.commit)
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

    func prepareAOSPSourceInputs(
        _ preparation: AOSPSourceInputPreparation,
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
            return
        }
        let initArguments = [
            "init",
            "--quiet",
            // The platform this source is built for, not the one acquiring it.
            // Repo defaults to `auto`, which reads the machine running it --
            // and that machine is this macOS host, while every AOSP build runs
            // in a Linux container. The default therefore selected Darwin host
            // prebuilts: 5.3 GiB of Clang, Go, and Rust toolchains for a
            // platform nothing here builds on, fetched into a store the guest
            // volume reads through a symlink and never asks for.
            "--platform=linux",
            "--partial-clone",
            "--clone-filter=blob:limit=10M",
            "--no-clone-bundle",
            "--use-superproject",
            "--repo-url=\(repo.repositoryURL)",
            "--repo-rev=\(repo.revision)",
            "-u",
            platform.manifestURL,
            "-b",
            platform.manifestRevision,
        ]
        _ = try await aospRepo(
            preparation,
            arguments: initArguments,
            output: .logged,
            stage: stage)
        try await requireAOSPHostSourceInputs(preparation, stage: stage)
        let initialized = try await validateInitializedAOSPSource(
            preparation,
            stage: stage)

        _ = try await aospRepo(
            preparation,
            arguments: [
                "sync",
                "--network-only",
                "--current-branch",
                "--fail-fast",
                "--force-sync",
                "--no-clone-bundle",
                "--no-interleaved",
                "--no-tags",
                "--optimized-fetch",
                "--prune",
                "--jobs-network=\(preparation.syncJobs)",
                "--retry-fetches=\(preparation.retryFetches)",
            ],
            output: .logged,
            stage: stage)
        let superprojectCommit = try await prepareAOSPSuperproject(
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
        try await hydrateAOSPSourceInputs(
            preparation,
            resolvedManifest: resolvedData,
            stage: stage)
        try context.cancellation.check()
        try context.files.write(
            Array(resolvedData),
            to: preparation.resolvedManifest)
        let resolvedDigest = try context.files.digest(
            file: preparation.resolvedManifest)
        let provenance = AOSPSourceProvenance(
            status: "hydrated",
            release: platform.release,
            revision: platform.revision,
            manifestCommit: initialized.manifestCommit,
            superprojectCommit: superprojectCommit,
            repoCommit: initialized.repoCommit,
            resolvedManifestSHA256: resolvedDigest.sha256Hex)
        try context.files.write(
            Array(try JSONEncoder().encode(provenance)),
            to: preparation.provenance)
    }

    private func validateExistingAOSPSourceIdentity(
        _ preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws -> AOSPSourceProvenance? {
        let manifest = preparation.source.appending(".repo/manifest.xml")
        guard try context.files.metadata(for: manifest) != nil else {
            return nil
        }
        let provenancePath = preparation.provenance
        guard try context.files.metadata(for: provenancePath) != nil
        else {
            return nil
        }
        let provenance = try JSONDecoder().decode(
            AOSPSourceProvenance.self,
            from: Data(try context.files.read(provenancePath)))
        guard provenance.status == "hydrated" else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "existing AOSP source-input provenance is not hydrated")
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
        let resolvedManifest = preparation.resolvedManifest
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
        _ preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws -> Data {
        let declaredManifest =
            try await aospRepo(
                preparation,
                arguments: ["manifest", "--no-local-manifests"],
                output: .captured(limit: 32 * 1_024 * 1_024),
                stage: stage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let revisions = try await aospSuperprojectRevisions(
            preparation.specification.platform.superprojectCommit,
            preparation: preparation,
            stage: stage)
        return try resolveAOSPManifest(
            Data(declaredManifest.utf8),
            revisions: revisions)
    }

    private func verifyAOSPResolvedManifest(
        _ manifest: Data,
        againstSuperproject superprojectCommit: String,
        preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws {
        let expected = try await aospSuperprojectRevisions(
            superprojectCommit,
            preparation: preparation,
            stage: stage)

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

    private func aospSuperprojectRevisions(
        _ commit: String,
        preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws -> [String: String] {
        let tree = try await aospCaptured(
            .named("git"),
            [
                "--git-dir",
                aospSuperprojectRepository(preparation).string,
                "ls-tree", "-r", "--full-tree", commit,
            ],
            in: preparation.source,
            environment: preparation.environment,
            stage: stage)
        var revisions: [String: String] = [:]
        for line in tree.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let identity = fields[0].split(separator: " ")
            guard identity.count == 3,
                identity[0] == "160000", identity[1] == "commit",
                revisions.updateValue(
                    String(identity[2]),
                    forKey: String(fields[1])) == nil
            else {
                continue
            }
        }
        return revisions
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
        _ preparation: AOSPSourceInputPreparation,
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

    private func hydrateAOSPSourceInputs(
        _ preparation: AOSPSourceInputPreparation,
        resolvedManifest: Data,
        stage: TaskID
    ) async throws {
        let manifest = preparation.source.appending(
            ".nucleus/hydration-manifest.xml")
        try context.files.createDirectory(manifest.removingLastComponent())
        try context.files.write(Array(resolvedManifest), to: manifest)
        defer { try? context.files.remove(manifest) }
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("bash"),
                arguments: [
                    preparation.hydrationScript.string,
                    preparation.source.string,
                    manifest.string,
                    String(preparation.syncJobs),
                ],
                workingDirectory: preparation.source,
                environment: preparation.environment,
                output: .logged))
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "locked AOSP source-input hydration failed")
        }
    }

    private func validateInitializedAOSPSource(
        _ preparation: AOSPSourceInputPreparation,
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

    private func requireAOSPHostSourceInputs(
        _ preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws {
        let partialClone = try await aospCaptured(
            .named("git"),
            [
                "--git-dir",
                preparation.source.appending(".repo/manifests.git").string,
                "config", "--bool", "--get", "repo.partialclone",
            ],
            in: preparation.source,
            environment: preparation.environment,
            stage: stage
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard partialClone == "true" else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "AOSP host source input is not a partial-clone Repo cache; remove the "
                    + "reconstructible source-input cache before retrying")
        }
    }

    private func prepareAOSPSuperproject(
        _ preparation: AOSPSourceInputPreparation,
        stage: TaskID
    ) async throws -> String {
        let platform = preparation.specification.platform
        let superproject = aospSuperprojectRepository(preparation)
        try context.files.createDirectory(superproject.removingLastComponent())
        try await aospChecked(
            .named("git"),
            ["init", "--quiet", "--bare", superproject.string],
            in: preparation.source,
            environment: preparation.environment,
            stage: stage)
        try await aospChecked(
            .named("git"),
            [
                "--git-dir", superproject.string,
                "fetch", "--quiet", "--force", "--no-tags",
                platform.superprojectURL,
                platform.superprojectRevision,
            ],
            in: preparation.source,
            environment: preparation.environment,
            stage: stage)
        let superprojectCommit = try await aospGitRevision(
            repository: superproject,
            revision: "FETCH_HEAD",
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

    private func aospSuperprojectRepository(
        _ preparation: AOSPSourceInputPreparation
    ) -> FilePath {
        preparation.source.appending(".nucleus/superproject.git")
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

private func resolveAOSPManifest(
    _ manifest: Data,
    revisions: [String: String]
) throws -> Data {
    var remaining = revisions
    var lines = String(decoding: manifest, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    for index in lines.indices where lines[index].contains("<project ") {
        let path =
            aospManifestAttribute("path", in: lines[index])
            ?? aospManifestAttribute("name", in: lines[index])
        guard let path, let revision = remaining.removeValue(forKey: path) else {
            throw AOSPSourceWorkflowFailure.invalidOutput(
                "declared manifest contains a project absent from the superproject")
        }
        let prefix = "revision=\""
        if let start = lines[index].range(of: prefix) {
            let valueStart = start.upperBound
            guard let end = lines[index][valueStart...].firstIndex(of: "\"") else {
                throw AOSPSourceWorkflowFailure.invalidOutput(
                    "declared manifest contains a malformed project revision")
            }
            lines[index].replaceSubrange(valueStart..<end, with: revision)
        } else {
            guard let end = lines[index].firstIndex(of: ">") else {
                throw AOSPSourceWorkflowFailure.invalidOutput(
                    "declared manifest contains a malformed project record")
            }
            let insertion =
                end > lines[index].startIndex
                    && lines[index][lines[index].index(before: end)] == "/"
                ? lines[index].index(before: end)
                : end
            lines[index].insert(
                contentsOf: " revision=\"\(revision)\"",
                at: insertion)
        }
    }
    return Data(lines.joined(separator: "\n").utf8)
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
