import ColliderCore
import ColliderEngine
import ColliderPersistence
import Foundation
import FoundationXML
import Synchronization
import SystemPackage
import Testing

@testable import AndroidRuntimeColliderRecipe
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
                printf '%s\t%s\n' '\#(fixture.manifestCommit)' 'refs/heads/platform'
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
          init)
            destination=
            for argument in "$@"; do destination="$argument"; done
            mkdir -p "$destination"
            ;;
          -C)
            case "$3" in
              fetch)
                cp "$FIXTURE_MANIFEST" "$2/default.xml"
                ;;
              checkout)
                ;;
              rev-parse)
                test "$4" = HEAD
                printf '%s\n' '\#(fixture.manifestCommit)'
                ;;
              *)
                exit 2
                ;;
            esac
            ;;
          *)
            exit 2
            ;;
        esac
        """#,
        to: git)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.aosp-source-lock"),
        component: ComponentID(rawValue: "android-runtime"),
        outputs: [
            OutputDeclaration(
                path: FilePath(report.path),
                validation: .json)
        ],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(
                VerifyAOSPSourceLockAction(
                    verification: AOSPSourceLockVerification(
                        specification: fixture.specification,
                        launcher: FilePath(fixture.launcher.path),
                        report: FilePath(report.path),
                        environment: fixture.environment))))

    let execution = try await ColliderEngine(runtime: ColliderRuntime()).execute(
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
        case "$1" in
          init)
            destination=
            for argument in "$@"; do destination="$argument"; done
            mkdir -p "$destination"
            ;;
          --git-dir)
            case "$3" in
              config)
                printf 'true\n'
                ;;
              fetch)
                ;;
              ls-tree)
                printf '%s\n' \
                  '160000 commit 0123456789abcdef	platform/frameworks/base' \
                  '160000 commit abcdef0123456789	prebuilts/host/darwin'
                ;;
              *)
                exit 2
                ;;
            esac
            ;;
          -C)
            case "$2" in
              */.repo/manifests)
                printf '%s\n' '\#(fixture.manifestCommit)'
                ;;
              */.repo/repo)
                printf '%s\n' '\#(fixture.repoCommit)'
                ;;
              */.nucleus/superproject.git)
                test "$4" = FETCH_HEAD
                printf '%s\n' '\#(fixture.superprojectCommit)'
                ;;
              *)
                exit 2
                ;;
            esac
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
              .repo/repo
            cp "$FIXTURE_MANIFEST" .repo/manifests/default.xml
            cp "$FIXTURE_MANIFEST" .repo/manifest.xml
            ;;
          forall)
            ;;
          sync)
            ;;
          manifest)
            printf '%s\\n' \
              '<manifest><project name="platform/frameworks/base" upstream="refs/heads/platform"/></manifest>'
            ;;
          *)
            exit 2
            ;;
        esac
        """,
        to: fixture.bin.appendingPathComponent("python3"))
    let hydrationScript = fixture.root.appendingPathComponent(
        "hydrate-aosp-source-inputs")
    try fixture.writeExecutable(
        """
        #!/bin/sh
        set -eu
        printf 'hydrate %s %s %s\\n' "$1" "$2" "$3" >> "$FIXTURE_COMMAND_LOG"
        """,
        to: hydrationScript)
    let environment = fixture.environment.merging([
        "FIXTURE_COMMAND_LOG": commandLog.path
    ]) { _, value in value }
    let provenance = source.appendingPathComponent(
        ".nucleus/source-provenance.json")
    let resolvedManifest = source.appendingPathComponent(
        ".nucleus/resolved-manifest.xml")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.aosp-source"),
        component: ComponentID(rawValue: "android-runtime"),
        outputs: [
            OutputDeclaration(
                path: FilePath(resolvedManifest.path),
                validation: .regularFile),
            OutputDeclaration(
                path: FilePath(provenance.path),
                validation: .json),
        ],
        action:
            try AnyColliderAction(
                PrepareAOSPSourceInputsAction(
                    preparation: AOSPSourceInputPreparation(
                        specification: fixture.specification,
                        launcher: FilePath(fixture.launcher.path),
                        sourceInputs: FilePath(source.path),
                        hydrationScript: FilePath(hydrationScript.path),
                        resolvedManifest: FilePath(resolvedManifest.path),
                        provenance: FilePath(provenance.path),
                        syncJobs: 4,
                        retryFetches: 3,
                        environment: environment))))

    let execution = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(
            fixture.root.appendingPathComponent("state").path))

    #expect(execution.executed == [task.id])
    let commands = try String(contentsOf: commandLog, encoding: .utf8)
    #expect(
        commands.contains(
            "init --quiet --partial-clone --clone-filter=blob:limit=10M "
                + "--no-clone-bundle --use-superproject "
                + "--repo-url=repo://fixture --repo-rev=refs/tags/v2.65 "
                + "-u manifest://fixture -b refs/heads/platform"))
    #expect(
        commands.contains(
            "sync --network-only --current-branch --fail-fast --force-sync "
                + "--no-clone-bundle --no-interleaved "
                + "--no-tags --optimized-fetch --prune --jobs-network=4 "
                + "--retry-fetches=3"))
    #expect(commands.contains("hydrate "))
    #expect(commands.contains("manifest --no-local-manifests"))
    let materialization = try JSONDecoder().decode(
        AOSPSourceProvenance.self,
        from: Data(contentsOf: provenance))
    #expect(materialization.status == "hydrated")
    #expect(materialization.manifestCommit == fixture.manifestCommit)
    #expect(materialization.superprojectCommit == fixture.superprojectCommit)
    #expect(materialization.repoCommit == fixture.repoCommit)
    #expect(!materialization.resolvedManifestSHA256.isEmpty)
    #expect(
        XMLParser(data: try Data(contentsOf: resolvedManifest)).parse())
}

@Test func aospSourceMaterializationDeclaresItsBoundedExportRoot() throws {
    let fixture = try AOSPWorkflowFixture(name: "source-materialization-effects")
    defer { fixture.remove() }
    let export = FilePath(fixture.root.appendingPathComponent("export").path)
    let workspace = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "android-runtime-aosp-source",
            artifactTarget: .androidX86_64(apiLevel: 37),
            role: "aosp-source"),
        capacityBytes: 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB,
        cleanupPolicy: .protected)
    let action = MaterializeAOSPSourceAction(
        materialization: AOSPSourceMaterialization(
            specification: fixture.specification,
            launcher: FilePath(fixture.launcher.path),
            sourceInputs: FilePath(fixture.root.appendingPathComponent("inputs").path),
            resolvedManifest: FilePath(
                fixture.root.appendingPathComponent("resolved.xml").path),
            provenance: FilePath(
                fixture.root.appendingPathComponent("provenance.json").path),
            exportedResolvedManifest: export.appending("resolved-manifest.xml"),
            exportedProvenance: export.appending("source-provenance.json"),
            script: FilePath(fixture.root.appendingPathComponent("materialize").path),
            imageID: FilePath(fixture.root.appendingPathComponent("image-id").path),
            sourceWorkspace: workspace,
            syncJobs: 4,
            environment: [:]))

    #expect(
        action.requirements.effects.contains(
            ActionEffect(.write, scope: .output(export))))
    #expect(
        action.requirements.effects.contains(
            ActionEffect(
                .read,
                scope: .input(FilePath(fixture.root.path)))))
}

@Test func aospSigningIdentityCreatesAndValidatesEveryRequiredAlias() async throws {
    let fixture = try AOSPWorkflowFixture(name: "signing")
    defer { fixture.remove() }
    try fixture.writeExecutable(
        #"""
        #!/bin/sh
        set -eu
        command="$1"
        shift
        output=
        while test "$#" -gt 0; do
          if test "$1" = -out; then
            output="$2"
            shift 2
          else
            shift
          fi
        done
        test -n "$output"
        case "$command" in
          genpkey) printf 'private-key\n' > "$output" ;;
          req) printf 'certificate\n' > "$output" ;;
          pkcs8) printf 'pkcs8\n' > "$output" ;;
          x509|pkey) printf 'public-key\n' > "$output" ;;
          *) exit 2 ;;
        esac
        """#,
        to: fixture.bin.appendingPathComponent("openssl"))
    let destination = fixture.root.appendingPathComponent("signing")
    let identity = destination.appendingPathComponent("signing-identity.json")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "android-runtime.fixture-signing"),
        component: ComponentID(rawValue: "android-runtime"),
        outputs: [
            OutputDeclaration(
                path: FilePath(identity.path),
                validation: .json),
            OutputDeclaration(
                path: FilePath(destination.path),
                validation: .nonEmptyDirectory),
        ],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(
                PrepareAOSPSigningIdentityAction(
                    preparation: AOSPSigningIdentityPreparation(
                        destination: FilePath(destination.path),
                        subject: "/O=Nucleus/CN=Fixture",
                        environment: fixture.environment))))

    let runtime = ColliderRuntime()
    let graph = try TaskGraph([task])
    let stateRoot = FilePath(
        fixture.root.appendingPathComponent("state").path)
    _ = try await ColliderEngine(runtime: runtime).execute(
        graph: graph,
        selected: [task.id],
        stateRoot: stateRoot)
    _ = try await ColliderEngine(runtime: runtime).execute(
        graph: graph,
        selected: [task.id],
        stateRoot: stateRoot)

    let metadata = try JSONDecoder().decode(
        AOSPSigningIdentityFixture.self,
        from: Data(contentsOf: identity))
    #expect(metadata.purpose == "local-development")
    #expect(metadata.subject == "/O=Nucleus/CN=Fixture")
    #expect(
        metadata.certificates.map(\.alias) == [
            "releasekey", "platform", "shared", "media", "networkstack",
        ])
    for alias in metadata.certificates.map(\.alias) {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("\(alias).pem").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    }
}

@Test func aospCompileConcurrencyDoesNotChangeArtifactIdentity() throws {
    let root = FilePath("/fixture")
    func action(jobs: UInt32) throws -> AnyColliderAction {
        try AnyColliderAction(
            CompileAOSPProductAction(
                build: AOSPProductBuild(
                    productSource: root.appending("product"),
                    sourceProvenance: root.appending("source-provenance.json"),
                    artifactRoot: root.appending("build"),
                    sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
                    outputWorkspace: aospOutputWorkspace(apiLevel: 37),
                    compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
                    buildImageID: root.appending("container-image-id"),
                    artifactImageID: root.appending("container-image-id"),
                    signingIdentity: root.appending("signing-identity"),
                    product: "nucleus_x86_64",
                    release: "cp2a",
                    variant: "user",
                    buildNumber: "nucleus",
                    buildTimestamp: 1,
                    buildJobs: jobs,
                    expectedPlatformSDK: 37,
                    expectedVendorAPILevel: 202604,
                    environment: [:])))
    }

    let first = try action(jobs: 12)
    let second = try action(jobs: 24)
    #expect(first.identity == second.identity)
    #expect(
        first.requirements.persistentWorkspaceEffects.map(\.workspace)
            == [
                aospSourceWorkspace(apiLevel: 37),
                aospOutputWorkspace(apiLevel: 37),
                aospCompilerCacheWorkspace(apiLevel: 37),
            ])
    #expect(
        first.requirements.persistentWorkspaceEffects.first?.access == .readOnly)
}

@Test func aospCompileDelegatesIncrementalCleanupToSoong() async throws {
    let fixture = try AOSPWorkflowFixture(name: "product-compile")
    defer { fixture.remove() }
    let productSource = fixture.root.appendingPathComponent("product")
    let source = fixture.root.appendingPathComponent("source")
    let artifactRoot = fixture.root.appendingPathComponent("build")
    try FileManager.default.createDirectory(
        at: productSource,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true)
    try Data("product".utf8).write(
        to: productSource.appendingPathComponent("AndroidProducts.mk"))
    let provenance = fixture.root.appendingPathComponent("source.json")
    try Data(#"{"status":"materialized"}"#.utf8).write(to: provenance)
    let imageID = fixture.root.appendingPathComponent("image-id")
    try Data("fixture-image".utf8).write(to: imageID)
    let product = "nucleus_x86_64"
    let build = AOSPProductBuild(
        productSource: FilePath(productSource.path),
        sourceProvenance: FilePath(provenance.path),
        artifactRoot: FilePath(artifactRoot.path),
        sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildImageID: FilePath(imageID.path),
        artifactImageID: FilePath(imageID.path),
        signingIdentity: FilePath(
            fixture.root.appendingPathComponent("signing").path),
        product: product,
        release: "fixture",
        variant: "user",
        buildNumber: "1",
        buildTimestamp: 1,
        buildJobs: 24,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 37,
        environment: fixture.environment)
    let executions = Mutex<[OCIExecution]>([])

    let action = CompileAOSPProductAction(build: build)
    let files = ColliderRuntime().actionFileSystem()
    try await action.execute(
        in: ActionContext(
            files: files,
            cancellation: ActionCancellation {},
            logger: ActionLogger { _ in },
            commands: ActionCommandExecutor { _ in
                Issue.record("AOSP compilation escaped through the host executor")
                return CommandResult(status: 1)
            },
            downloads: ActionDownloader { _, _ in },
            containers: ActionContainerExecutor(run: { execution in
                executions.withLock { $0.append(execution) }
                if execution.command.contains("/bin/cp") {
                    let unsigned = artifactRoot.appendingPathComponent("unsigned")
                    try Data("target-files".utf8).write(
                        to: unsigned.appendingPathComponent(
                            "\(product)-target_files.zip"))
                }
                return CommandResult(status: 0)
            })))

    let recorded = executions.withLock { $0 }
    #expect(recorded.count == 2)
    #expect(recorded[0].command.contains("target-files-package"))
    #expect(recorded[0].command.contains("otatools"))
    #expect(recorded.allSatisfy { !$0.command.contains("installclean") })
    #expect(recorded.allSatisfy { !$0.command.contains("manifest") })
    #expect(recorded[1].command.contains("/bin/cp"))

    try action.validateOutputs(using: files)
    try Data("modified-target-files".utf8).write(
        to: artifactRoot.appendingPathComponent(
            "unsigned/\(product)-target_files.zip"))
    #expect(throws: (any Error).self) {
        try action.validateOutputs(using: files)
    }
}

@Test func aospProductAssemblyNormalizesSparseImagesAndStagesOutputs() async throws {
    let fixture = try AOSPWorkflowFixture(name: "assembly")
    defer { fixture.remove() }
    let buildRoot = fixture.root.appendingPathComponent("build")
    let source = fixture.root.appendingPathComponent("source")
    let hostTools = buildRoot.appendingPathComponent("out/host/linux-x86/bin")
    let staged = buildRoot.appendingPathComponent("staged")
    try FileManager.default.createDirectory(
        at: hostTools,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: staged,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true)
    for tool in ["img_from_target_files", "simg2img"] {
        let path = hostTools.appendingPathComponent(tool)
        try Data().write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path)
    }
    let product = "nucleus_x86_64"
    try Data("signed-target-files".utf8).write(
        to: staged.appendingPathComponent("\(product)-target_files.zip"))
    let imageID = fixture.root.appendingPathComponent("image-id")
    try Data("fixture-image".utf8).write(to: imageID)
    let build = AOSPProductBuild(
        productSource: FilePath(fixture.root.path),
        sourceProvenance: FilePath(
            fixture.root.appendingPathComponent("source.json").path),
        artifactRoot: FilePath(buildRoot.path),
        sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildImageID: FilePath(imageID.path),
        artifactImageID: FilePath(imageID.path),
        signingIdentity: FilePath(
            fixture.root.appendingPathComponent("signing").path),
        product: product,
        release: "fixture",
        variant: "user",
        buildNumber: "1",
        buildTimestamp: 1,
        buildJobs: 1,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 37,
        environment: fixture.environment)
    let executions = Mutex<[OCIExecution]>([])
    let imageCandidate = buildRoot.appendingPathComponent(".images-candidate")
    let archiveCandidate = staged.appendingPathComponent(
        ".\(product)-images.candidate.zip")
    let action = AssembleAOSPProductImagesAction(build: build)

    try await action.execute(
        in: ActionContext(
            files: ColliderRuntime().actionFileSystem(),
            cancellation: ActionCancellation {},
            logger: ActionLogger { _ in },
            commands: ActionCommandExecutor { _ in
                Issue.record("AOSP assembly escaped through the host executor")
                return CommandResult(status: 1)
            },
            downloads: ActionDownloader { _, _ in },
            containers: ActionContainerExecutor(run: { execution in
                executions.withLock { $0.append(execution) }
                if execution.command.first == "/usr/bin/unzip" {
                    for name in aospRequiredProductImages {
                        let bytes: [UInt8] =
                            name == "system.img"
                            ? [0x3a, 0xff, 0x26, 0xed]
                            : Array("raw-image".utf8)
                        try Data(bytes).write(
                            to: imageCandidate.appendingPathComponent(name))
                    }
                } else if execution.command.first?.hasSuffix("simg2img") == true {
                    try Data("normalized-image".utf8).write(
                        to: imageCandidate.appendingPathComponent("system.img.raw"))
                } else {
                    try Data("images-archive".utf8).write(
                        to: archiveCandidate)
                }
                return CommandResult(status: 0)
            })))

    #expect(
        try String(
            contentsOf: staged.appendingPathComponent("\(product)-images.zip"),
            encoding: .utf8) == "images-archive")
    #expect(
        try String(
            contentsOf: staged.appendingPathComponent("images/system.img"),
            encoding: .utf8) == "normalized-image")
    for name in aospRequiredProductImages where name != "system.img" {
        #expect(
            FileManager.default.fileExists(
                atPath: staged.appendingPathComponent("images/\(name)").path))
    }
    let recorded = executions.withLock { $0 }
    #expect(recorded.count == 3)
    #expect(recorded.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(
        recorded.allSatisfy {
            $0.artifactTarget == .androidX86_64(apiLevel: 37)
                && $0.intelBinaryTranslationPolicy == .required
        })
}

@Test func aospProductSigningValidatesKeysAndUsesReleaseAVBArguments() async throws {
    let fixture = try AOSPWorkflowFixture(name: "product-signing")
    defer { fixture.remove() }
    let buildRoot = fixture.root.appendingPathComponent("build")
    let source = fixture.root.appendingPathComponent("source")
    let signing = fixture.root.appendingPathComponent("signing")
    let hostTools = buildRoot.appendingPathComponent("out/host/linux-x86/bin")
    let unsigned = buildRoot.appendingPathComponent("unsigned")
    try FileManager.default.createDirectory(
        at: hostTools,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: unsigned,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: signing,
        withIntermediateDirectories: true)
    let signingTool = hostTools.appendingPathComponent("sign_target_files_apks")
    try Data().write(to: signingTool)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: signingTool.path)
    let certificateBytes = Data("certificate".utf8)
    let certificateDigest = ArtifactHasher.digest(
        bytes: certificateBytes
    ).hexadecimal
    for alias in aospSigningAliases {
        try Data("private".utf8).write(
            to: signing.appendingPathComponent("\(alias).pem"))
        try certificateBytes.write(
            to: signing.appendingPathComponent("\(alias).x509.pem"))
        try Data("pkcs8".utf8).write(
            to: signing.appendingPathComponent("\(alias).pk8"))
    }
    let identity = AOSPSigningIdentity(
        purpose: "local-development",
        subject: "/O=Nucleus/CN=Fixture",
        certificates: aospSigningAliases.map {
            AOSPSigningIdentity.Certificate(
                alias: $0,
                x509SHA256: certificateDigest)
        })
    try JSONEncoder().encode(identity).write(
        to: signing.appendingPathComponent("signing-identity.json"))
    let product = "nucleus_x86_64"
    try Data("unsigned-target-files".utf8).write(
        to: unsigned.appendingPathComponent("\(product)-target_files.zip"))
    let imageID = fixture.root.appendingPathComponent("image-id")
    try Data("fixture-image".utf8).write(to: imageID)
    let build = AOSPProductBuild(
        productSource: FilePath(fixture.root.path),
        sourceProvenance: FilePath(
            fixture.root.appendingPathComponent("source.json").path),
        artifactRoot: FilePath(buildRoot.path),
        sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildImageID: FilePath(imageID.path),
        artifactImageID: FilePath(imageID.path),
        signingIdentity: FilePath(signing.path),
        product: product,
        release: "fixture",
        variant: "user",
        buildNumber: "1",
        buildTimestamp: 1,
        buildJobs: 24,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 37,
        environment: fixture.environment)
    let execution = Mutex<OCIExecution?>(nil)
    let candidate = buildRoot.appendingPathComponent(
        "staged/.\(product)-target_files.candidate.zip")

    try await SignAOSPProductAction(build: build).execute(
        in: ActionContext(
            files: ColliderRuntime().actionFileSystem(),
            cancellation: ActionCancellation {},
            logger: ActionLogger { _ in },
            commands: ActionCommandExecutor { command in
                let outputIndex = try #require(
                    command.arguments.firstIndex(of: "-out"))
                let output = command.arguments[outputIndex + 1]
                try Data("public-key".utf8).write(
                    to: URL(fileURLWithPath: output))
                return CommandResult(status: 0)
            },
            downloads: ActionDownloader { _, _ in },
            containers: ActionContainerExecutor(run: { value in
                execution.withLock { $0 = value }
                try Data("signed-target-files".utf8).write(to: candidate)
                return CommandResult(status: 0)
            })))

    #expect(
        try String(
            contentsOf: buildRoot.appendingPathComponent(
                "staged/\(product)-target_files.zip"),
            encoding: .utf8) == "signed-target-files")
    let recorded = try #require(execution.withLock { $0 })
    #expect(recorded.command.contains("--avb_vbmeta_key"))
    #expect(recorded.command.contains("/keys/releasekey.pem"))
    let threadsIndex = try #require(recorded.command.firstIndex(of: "--threads"))
    #expect(recorded.command[threadsIndex + 1] == "8")
    #expect(!recorded.command.contains("--allow_gsi_debug_sepolicy"))
    let signingMount = try #require(
        recorded.mounts.first { $0.target == "/keys" })
    #expect(signingMount.source == FilePath(signing.path))
    #expect(signingMount.isReadOnly)
}

@Test func aospProductPublicationCommitsOutputsThenActivatesTheGeneration() async throws {
    let fixture = try AOSPWorkflowFixture(name: "publication")
    defer { fixture.remove() }
    let aospRoot = fixture.root.appendingPathComponent("aosp-build")
    let buildRoot = aospRoot.appendingPathComponent("generations/generation-one")
    let staged = buildRoot.appendingPathComponent("staged")
    let stagedImages = staged.appendingPathComponent("images")
    try FileManager.default.createDirectory(
        at: stagedImages,
        withIntermediateDirectories: true)
    for (name, contents) in [
        ("nucleus_x86_64-target_files.zip", "target-files"),
        ("nucleus_x86_64-images.zip", "images-archive"),
        ("image-provenance.json", "{}"),
    ] {
        try Data(contents.utf8).write(to: staged.appendingPathComponent(name))
    }
    try Data("system-image".utf8).write(
        to: stagedImages.appendingPathComponent("system.img"))
    let build = AOSPProductBuild(
        productSource: FilePath(fixture.root.path),
        sourceProvenance: FilePath(fixture.root.appendingPathComponent("source.json").path),
        artifactRoot: FilePath(buildRoot.path),
        sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildImageID: FilePath(fixture.root.appendingPathComponent("image-id").path),
        artifactImageID: FilePath(fixture.root.appendingPathComponent("image-id").path),
        signingIdentity: FilePath(fixture.root.appendingPathComponent("signing").path),
        product: "nucleus_x86_64",
        release: "fixture",
        variant: "user",
        buildNumber: "1",
        buildTimestamp: 1,
        buildJobs: 1,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 37,
        environment: fixture.environment)
    let active = aospRoot.appendingPathComponent("current")
    let publishedProvenance = buildRoot.appendingPathComponent(
        "signed/image-provenance.json")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "android-runtime.fixture-publication"),
        component: ComponentID(rawValue: "android-runtime"),
        outputs: [
            OutputDeclaration(
                path: FilePath(active.path),
                validation: .symlinkTarget),
            OutputDeclaration(
                path: FilePath(publishedProvenance.path),
                validation: .json),
        ],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(PublishAOSPProductAction(build: build)))

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(fixture.root.appendingPathComponent("state").path))

    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generations/generation-one")
    #expect(
        try String(
            contentsOf: buildRoot.appendingPathComponent("images/system.img"),
            encoding: .utf8) == "system-image")
    #expect(
        try String(contentsOf: publishedProvenance, encoding: .utf8) == "{}")
}

private struct AOSPSigningIdentityFixture: Decodable {
    struct Certificate: Decodable {
        let alias: String
        let x509SHA256: String
    }

    let purpose: String
    let subject: String
    let certificates: [Certificate]
}

private struct AOSPWorkflowFixture {
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
                manifestRevision: "refs/heads/platform",
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

extension ArtifactDigest {
    fileprivate var sha256Hex: String {
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
