import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func aospSourceLockVerificationChecksPinnedUpstreamsAndLauncher() async throws {
    let fixture = try AOSPWorkflowFixture(name: "source-lock")
    defer { fixture.remove() }
    let report = fixture.root.appendingPathComponent("verification.json")
    let git = fixture.bin.appendingPathComponent("git")
    try fixture.writeExecutable(
        #"""
        #!/bin/sh
        set -eu
        case "$1" in
          ls-remote)
            case "$2" in
              manifest://fixture)
                printf '%s\t%s\n' '\#(fixture.manifestTag)' 'refs/tags/platform'
                printf '%s\t%s\n' '\#(fixture.manifestCommit)' 'refs/tags/platform^{}'
                ;;
              superproject://fixture)
                printf '%s\t%s\n' '\#(fixture.superprojectCommit)' 'refs/heads/platform'
                ;;
              repo://fixture)
                printf '%s\t%s\n' '\#(fixture.repoTag)' 'refs/tags/v2.65'
                printf '%s\t%s\n' '\#(fixture.repoCommit)' 'refs/tags/v2.65^{}'
                ;;
              *)
                exit 2
                ;;
            esac
            ;;
          clone)
            destination=
            for argument in "$@"; do destination="$argument"; done
            mkdir -p "$destination"
            cp "$FIXTURE_MANIFEST" "$destination/default.xml"
            ;;
          -C)
            test "$3" = rev-parse
            test "$4" = HEAD
            printf '%s\n' '\#(fixture.manifestCommit)'
            ;;
          *)
            exit 2
            ;;
        esac
        """#,
        to: git)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.aosp-source-lock"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(report.path),
                validation: .json)
        ],
        cachePolicy: .always,
        operation: .verifyAOSPSourceLock(
            AOSPSourceLockVerification(
                specification: fixture.specification,
                launcher: FilePath(fixture.launcher.path),
                report: FilePath(report.path),
                environment: fixture.environment)))

    let execution = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(
            fixture.root.appendingPathComponent("state").path))

    #expect(execution.executed == [task.id])
    let verification = try JSONDecoder().decode(
        AOSPVerificationReport.self,
        from: Data(contentsOf: report))
    #expect(verification.status == "verified")
    #expect(verification.platform.manifestCommit == fixture.manifestCommit)
    #expect(
        verification.platform.defaultManifestSHA256
            == fixture.defaultManifestDigest.sha256Hex)
    #expect(verification.repo.commit == fixture.repoCommit)
    #expect(
        verification.repo.launcherSHA256
            == fixture.launcherDigest.sha256Hex)
}

@Test func aospSourcePreparationMaterializesPinnedSourceAndProvenance() async throws {
    let fixture = try AOSPWorkflowFixture(name: "source")
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    let commandLog = fixture.root.appendingPathComponent("repo-commands")
    try fixture.writeExecutable(
        #"""
        #!/bin/sh
        set -eu
        test "$1" = -C
        case "$2" in
          */.repo/manifests)
            printf '%s\n' '\#(fixture.manifestCommit)'
            ;;
          */.repo/repo)
            printf '%s\n' '\#(fixture.repoCommit)'
            ;;
          */.repo/exp-superproject/*-superproject.git)
            test "$4" = refs/heads/platform
            printf '%s\n' '\#(fixture.superprojectCommit)'
            ;;
          *)
            exit 2
            ;;
        esac
        """#,
        to: fixture.bin.appendingPathComponent("git"))
    try fixture.writeExecutable(
        """
        #!/bin/sh
        set -eu
        launcher="$1"
        shift
        command="$1"
        shift
        printf '%s' "$command" >> "$FIXTURE_COMMAND_LOG"
        for argument in "$@"; do
          printf ' %s' "$argument" >> "$FIXTURE_COMMAND_LOG"
        done
        printf '\\n' >> "$FIXTURE_COMMAND_LOG"
        case "$command" in
          init)
            mkdir -p \
              .repo/manifests \
              .repo/repo \
              .repo/exp-superproject/platform-superproject.git
            cp "$FIXTURE_MANIFEST" .repo/manifests/default.xml
            cp "$FIXTURE_MANIFEST" .repo/manifest.xml
            ;;
          forall)
            ;;
          sync)
            ;;
          manifest)
            printf '%s\\n' \
              '<manifest><project name="platform/frameworks/base" revision="0123456789abcdef"/></manifest>'
            ;;
          *)
            exit 2
            ;;
        esac
        """,
        to: fixture.bin.appendingPathComponent("python3"))
    let environment = fixture.environment.merging([
        "FIXTURE_COMMAND_LOG": commandLog.path
    ]) { _, value in value }
    let provenance = source.appendingPathComponent(
        ".nucleus/source-provenance.json")
    let resolvedManifest = source.appendingPathComponent(
        ".nucleus/resolved-manifest.xml")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.aosp-source"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(resolvedManifest.path),
                validation: .regularFile),
            OutputDeclaration(
                path: FilePath(provenance.path),
                validation: .json),
        ],
        operation: .prepareAOSPSource(
            AOSPSourcePreparation(
                specification: fixture.specification,
                launcher: FilePath(fixture.launcher.path),
                source: FilePath(source.path),
                minimumFreeBytes: 1,
                syncJobs: 4,
                retryFetches: 3,
                environment: environment)))

    let execution = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(
            fixture.root.appendingPathComponent("state").path))

    #expect(execution.executed == [task.id])
    let commands = try String(contentsOf: commandLog, encoding: .utf8)
    #expect(
        commands.contains(
            "init --quiet --partial-clone --clone-filter=blob:limit=10M "
                + "--use-superproject --no-clone-bundle "
                + "--repo-url=repo://fixture --repo-rev=refs/tags/v2.65 "
                + "-u manifest://fixture -b refs/tags/platform"))
    #expect(
        commands.contains(
            "sync --current-branch --detach --fail-fast --no-clone-bundle "
                + "--no-tags --optimized-fetch --prune --jobs=4 "
                + "--retry-fetches=3"))
    #expect(
        commands.components(
            separatedBy:
                "forall --ignore-missing --jobs=1 --verbose -c "
        ).count == 3)
    #expect(commands.contains("if test ! -e .git; then exit 0; fi"))
    #expect(commands.contains("manifest --revision-as-HEAD"))
    let materialization = try JSONDecoder().decode(
        AOSPSourceProvenance.self,
        from: Data(contentsOf: provenance))
    #expect(materialization.status == "materialized")
    #expect(materialization.manifestCommit == fixture.manifestCommit)
    #expect(materialization.superprojectCommit == fixture.superprojectCommit)
    #expect(materialization.repoCommit == fixture.repoCommit)
    #expect(!materialization.resolvedManifestSHA256.isEmpty)
}

private struct AOSPWorkflowFixture {
    let manifestTag = String(repeating: "a", count: 40)
    let manifestCommit = String(repeating: "b", count: 40)
    let superprojectCommit = String(repeating: "c", count: 40)
    let repoTag = String(repeating: "d", count: 40)
    let repoCommit = String(repeating: "e", count: 40)
    let root: URL
    let bin: URL
    let manifest: URL
    let launcher: URL
    let defaultManifestDigest: ArtifactDigest
    let launcherDigest: ArtifactDigest
    let specification: AOSPSourceSpecification

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "collider-aosp-\(name)-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        manifest = root.appendingPathComponent("default.xml")
        launcher = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true)
        try Data(
            "<manifest><remote name=\"fixture\"/></manifest>\n".utf8
        ).write(to: manifest)
        try Data("VERSION = (2, 65)\n".utf8).write(to: launcher)
        defaultManifestDigest = try ArtifactHasher.digest(
            file: FilePath(manifest.path))
        launcherDigest = try ArtifactHasher.digest(
            file: FilePath(launcher.path))
        specification = AOSPSourceSpecification(
            platform: AOSPPlatformSource(
                release: "Fixture Android",
                revision: "refs/tags/platform",
                manifestURL: "manifest://fixture",
                manifestTagObject: manifestTag,
                manifestCommit: manifestCommit,
                defaultManifestDigest: defaultManifestDigest,
                superprojectURL: "superproject://fixture",
                superprojectRevision: "refs/heads/platform",
                superprojectCommit: superprojectCommit),
            repo: AOSPRepoSource(
                launcherVersion: "2.65",
                launcherDigest: launcherDigest,
                repositoryURL: "repo://fixture",
                revision: "refs/tags/v2.65",
                tagObject: repoTag,
                commit: repoCommit))
    }

    var environment: [String: String] {
        [
            "PATH": bin.path + ":/usr/bin:/bin",
            "FIXTURE_MANIFEST": manifest.path,
        ]
    }

    func writeExecutable(_ contents: String, to destination: URL) throws {
        try Data(contents.utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension ArtifactDigest {
    var sha256Hex: String {
        String(description.dropFirst("sha256:".count))
    }
}

private struct AOSPVerificationReport: Decodable {
    struct Platform: Decodable {
        let manifestCommit: String
        let defaultManifestSHA256: String
    }

    struct Repo: Decodable {
        let commit: String
        let launcherSHA256: String
    }

    let status: String
    let platform: Platform
    let repo: Repo
}

private struct AOSPSourceProvenance: Decodable {
    let status: String
    let manifestCommit: String
    let superprojectCommit: String
    let repoCommit: String
    let resolvedManifestSHA256: String
}
