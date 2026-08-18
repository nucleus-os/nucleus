import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

@Test
func macOSBuilderContractSelectsOneImmutableHost() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let contract = try MacOSBuilderContract.load(
        root: root)

    #expect(contract.operatingSystem.majorVersion == 27)
    #expect(
        contract.xcode.developerDirectory
            == "/Applications/Xcode-beta.app/Contents/Developer")
    #expect(contract.xcode.majorVersion == 27)
    #expect(contract.appleContainer.version == "1.2.0")
    #expect(
        contract.appleContainer.commit
            == "6e65319fe476ffe8db8ddaf828a537ed36fe2859")
    #expect(contract.appleContainer.network == "nucleus-build-internal")
    #expect(contract.launchd.maximumOpenFileCount == 245_760)
    #expect(contract.builder.user == "nucleus-builder")
    #expect(contract.builder.organization == "https://github.com/nucleus-os")
    #expect(contract.builder.runnerGroup == "nucleus")
    #expect(contract.builder.runnerVersion == "2.336.0")
    #expect(contract.builder.runnerArchiveSize == 127_389_671)
    #expect(contract.builder.runnerRoot == "/Library/Nucleus/GitHubActionsRunner")
    #expect(contract.builder.hostContractRoot == "/Library/Nucleus/Builder")
    // A builder in staff would read the whole interactive home by group.
    #expect(contract.builder.group == "nucleus-builder")
    #expect(contract.builder.group != "staff")
    #expect(
        contract.builder.runnerWorkRoot
            == "/Users/nucleus-builder/Library/Developer/Nucleus/Collider/actions-runner-work")
    // Retirement removes the machine root, so the job checkout must not be
    // inside it.
    #expect(!contract.builder.runnerWorkRoot.hasPrefix(contract.builder.runnerRoot + "/"))
    #expect(contract.builder.runnerWorkRoot.hasPrefix(contract.builder.home + "/"))
}

@Test
func appleMajorVersionSelectsAReleaseRatherThanABetaBuild() {
    #expect(appleMajorVersion(of: "27.0") == 27)
    #expect(appleMajorVersion(of: "27.1.2") == 27)
    #expect(appleMajorVersion(of: "27") == 27)
    #expect(appleMajorVersion(of: "26.4") == 26)
    #expect(appleMajorVersion(of: "") == nil)
    #expect(appleMajorVersion(of: "beta") == nil)
}

@Test
func macOSBuilderContractRejectsWhitespaceInMachineWideRoots() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let declared = try String(
        contentsOf: root.appendingPathComponent(MacOSBuilderContract.relativePath),
        encoding: .utf8)
    let staging = URL(
        fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("nucleus-builder-contract-\(UUID().uuidString)", isDirectory: true)
    let contractFile = staging.appendingPathComponent(
        MacOSBuilderContract.relativePath)
    try FileManager.default.createDirectory(
        at: contractFile.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    for rejected in [
        "/Library/Application Support/Nucleus/GitHubActionsRunner",
        "Library/Nucleus/GitHubActionsRunner",
        "/Library/Nucleus/GitHubActionsRunner/",
    ] {
        try declared.replacingOccurrences(
            of: "\"/Library/Nucleus/GitHubActionsRunner\"",
            with: "\"\(rejected)\""
        ).write(to: contractFile, atomically: true, encoding: .utf8)

        #expect(throws: MacOSBuilderContractFailure.self) {
            try MacOSBuilderContract.load(root: FilePath(staging.path))
        }
    }

    // Step scripts are written to the work root's `_temp`, and retirement
    // removes the machine root, so the work root carries both invariants.
    for rejected in [
        "/Users/nucleus-builder/Library/Developer/Nucleus/Collider/actions runner work",
        "/Library/Nucleus/GitHubActionsRunner/_work",
        "/Users/someone-else/actions-runner-work",
    ] {
        try declared.replacingOccurrences(
            of:
                "\"/Users/nucleus-builder/Library/Developer/Nucleus/Collider/actions-runner-work\"",
            with: "\"\(rejected)\""
        ).write(to: contractFile, atomically: true, encoding: .utf8)

        #expect(throws: MacOSBuilderContractFailure.self) {
            try MacOSBuilderContract.load(root: FilePath(staging.path))
        }
    }
}

@Test
func macOSBuilderDoctorAcceptsPinnedContainerEvidence() throws {
    let contract = try loadMacOSBuilderContract()
    let layout = MacOSHostStorageLayout(
        homeDirectory: FilePath("/Users/developer"))
    let health = OCIRuntimeHealth(
        appRoot: URL(fileURLWithPath: layout.appleContainerApplicationRoot.string),
        installRoot: URL(fileURLWithPath: "/usr/local/"),
        apiServerVersion:
            "container-apiserver version 1.2.0 (build: release, commit: 6e65319)",
        apiServerCommit: "6e65319fe476ffe8db8ddaf828a537ed36fe2859",
        apiServerBuild: "release",
        apiServerAppName: "container-apiserver")
    let network = OCIRuntimeNetworkState(
        name: "nucleus-build-internal",
        mode: "hostOnly")

    #expect(
        MacOSBuilderDoctor.containerSystemDetail(
            health,
            expectedAppRoot: layout.appleContainerApplicationRoot,
            contract: contract) != nil)
    #expect(
        MacOSBuilderDoctor.hostOnlyNetworkDetail(
            network, contract: contract) != nil)
}

@Test
func macOSBuilderDoctorRejectsDriftedContainerEvidence() throws {
    let contract = try loadMacOSBuilderContract()
    let driftedHealth = OCIRuntimeHealth(
        appRoot: URL(
            fileURLWithPath: "/Users/developer/Library/Application Support/container"),
        installRoot: URL(fileURLWithPath: "/usr/local"),
        apiServerVersion: "container-apiserver version 1.2.1",
        apiServerCommit: "wrong",
        apiServerBuild: "release",
        apiServerAppName: "container-apiserver")
    let routedNetwork = OCIRuntimeNetworkState(
        name: "nucleus-build-internal",
        mode: "nat")

    #expect(
        MacOSBuilderDoctor.containerSystemDetail(
            driftedHealth,
            expectedAppRoot: FilePath(
                "/Users/developer/Library/Developer/Nucleus/Collider/apple-container"),
            contract: contract) == nil)
    #expect(
        MacOSBuilderDoctor.hostOnlyNetworkDetail(
            routedNetwork, contract: contract) == nil)
}

@Test
func persistentServiceTemplateCarriesTheDeclaredIdentity() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let contract = try MacOSBuilderContract.load(root: FilePath(root.path))
    let template = try String(
        contentsOf: root.appendingPathComponent(
            "tools/macos-builder/com.nucleus.container-system-start.plist.in"),
        encoding: .utf8)
    let starterPath =
        "/Users/builder/Library/Application Support/Nucleus/Collider/service/container-system-start"
    let rendered = template.replacingOccurrences(
        of: "NUCLEUS_CONTAINER_STARTER_PATH",
        with: starterPath
    ).replacingOccurrences(
        of: "NUCLEUS_CONTAINER_STANDARD_OUTPUT_PATH",
        with: "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.log"
    ).replacingOccurrences(
        of: "NUCLEUS_CONTAINER_STANDARD_ERROR_PATH",
        with:
            "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.error.log"
    )

    #expect(
        MacOSBuilderDoctor.persistentServiceDetail(
            Data(rendered.utf8),
            launchdOutput: """
                resource limits = {
                    maxfiles (soft) => 245760
                    maxfiles (hard) => 245760
                }
                """,
            starterPath: starterPath,
            standardOutPath:
                "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.log",
            standardErrorPath:
                "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.error.log",
            contract: contract)
            == "per-user/com.nucleus.container-system-start")

    #expect(
        MacOSBuilderDoctor.persistentServiceDetail(
            Data(rendered.utf8),
            launchdOutput: """
                resource limits = {
                    maxfiles (soft) => 65536
                    maxfiles (hard) => 65536
                }
                """,
            starterPath: starterPath,
            standardOutPath:
                "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.log",
            standardErrorPath:
                "/Users/builder/Library/Logs/Nucleus/Collider/service/apple-container-apiserver.error.log",
            contract: contract) == nil)
}

@Test
func ciMacOSBuilderDoctorScopeDryRunsWithoutHostMutation() async throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let command = try Doctor.parse(["ci-macos-builder", "--dry-run"])
    #expect(command.scope == .ciMacOSBuilder)
    #expect(command.dryRun)

    try await WorkspaceDoctor(
        context: WorkspaceContext(
            root: FilePath(root.path),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            runtime: ColliderRuntime())
    ).run(
        scope: .ciMacOSBuilder,
        dryRun: true,
        quiet: true)
}

@Test
func builderHandoffResolvesOnlySupportedLocalStates() {
    #expect(
        builderLocalState(account: .absent, service: .absent, recovery: .absent) == .fresh)
    #expect(
        builderLocalState(account: .present, service: .present, recovery: .absent) == .complete)
    #expect(
        builderLocalState(account: .present, service: .absent, recovery: .preArtifact)
            == .preArtifact)
    #expect(
        builderLocalState(account: .present, service: .absent, recovery: .unregistered)
            == .unregistered)
    #expect(
        builderLocalState(account: .present, service: .absent, recovery: .registered)
            == .registered)

    // Every remaining combination is partial state that provisioning refuses to
    // replace or guess at.
    let resolved: Set<[String]> = [
        ["absent", "absent", "absent"],
        ["present", "present", "absent"],
        ["present", "absent", "pre-artifact"],
        ["present", "absent", "unregistered"],
        ["present", "absent", "registered"],
    ]
    for account in BuilderAccountPresence.allCases {
        for service in BuilderServicePresence.allCases {
            for recovery in BuilderRecoveryState.allCases {
                let combination = [account.rawValue, service.rawValue, recovery.rawValue]
                guard !resolved.contains(combination) else { continue }
                #expect(
                    builderLocalState(account: account, service: service, recovery: recovery)
                        == .inconsistent,
                    "\(combination) must not resolve to a supported local state")
            }
        }
    }
}

@Test
func builderHomeStaysResumableAcrossTheGroupMigration() {
    // A host provisioned before the dedicated group existed still has a
    // staff-grouped home. Provisioning is what assigns the group, so the probe
    // that decides whether provisioning may resume must not require it.
    #expect(
        builderHomeIsProvisioned(
            BuilderOwnership(user: "nucleus-builder", group: "staff", permissions: 0o700),
            user: "nucleus-builder"))
    #expect(
        builderHomeIsProvisioned(
            BuilderOwnership(
                user: "nucleus-builder", group: "nucleus-builder", permissions: 0o700),
            user: "nucleus-builder"))
    // A home owned by someone else, or readable beyond its owner, is not one
    // provisioning established.
    #expect(
        !builderHomeIsProvisioned(
            BuilderOwnership(user: "maddy", group: "staff", permissions: 0o700),
            user: "nucleus-builder"))
    #expect(
        !builderHomeIsProvisioned(
            BuilderOwnership(user: "nucleus-builder", group: "staff", permissions: 0o755),
            user: "nucleus-builder"))
}

@Test
func builderRunnerStateAcceptsOnlyTheDeclaredRunner() {
    #expect(builderRunnerState(registeredNames: [], expected: "nucleus-m2-ultra") == .fresh)
    #expect(
        builderRunnerState(registeredNames: ["nucleus-m2-ultra"], expected: "nucleus-m2-ultra")
            == .complete)
    #expect(
        builderRunnerState(registeredNames: ["foreign"], expected: "nucleus-m2-ultra")
            == .inconsistent)
    #expect(
        builderRunnerState(
            registeredNames: ["nucleus-m2-ultra", "foreign"], expected: "nucleus-m2-ultra")
            == .inconsistent)
}

@Test
func builderHandoffActionPairsOnlyReconcilableStates() {
    #expect(builderHandoffAction(local: .fresh, runner: .fresh) == .provision)
    #expect(builderHandoffAction(local: .preArtifact, runner: .fresh) == .provision)
    #expect(builderHandoffAction(local: .unregistered, runner: .fresh) == .provision)
    #expect(builderHandoffAction(local: .registered, runner: .complete) == .finalize)
    #expect(builderHandoffAction(local: .complete, runner: .complete) == .verify)

    let reconcilable: Set<[String]> = [
        ["fresh", "fresh"],
        ["pre-artifact", "fresh"],
        ["unregistered", "fresh"],
        ["registered", "complete"],
        ["complete", "complete"],
    ]
    for local in BuilderLocalState.allCases {
        for runner in BuilderRunnerState.allCases {
            let pair = [local.rawValue, runner.rawValue]
            guard !reconcilable.contains(pair) else { continue }
            #expect(
                builderHandoffAction(local: local, runner: runner) == .inconsistent,
                "\(pair) must stop for explicit recovery")
        }
    }
}

@Test
func machineRootRemovalRefusesUnrecognizedPathsAndContents() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let guardLibrary = root.appendingPathComponent(
        "tools/macos-builder/builder-machine-root.sh")
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        set -uo pipefail
        source "$1"
        report() { if "$@"; then echo accept; else echo reject; fi; }

        report nucleus_supported_machine_root_path /Library/Nucleus
        report nucleus_supported_machine_root_path '/Library/Application Support/Nucleus'
        report nucleus_supported_machine_root_path /Library
        report nucleus_supported_machine_root_path /Library/
        report nucleus_supported_machine_root_path /Users/someone/Library/Nucleus
        report nucleus_supported_machine_root_path Library/Nucleus

        fixture="$(mktemp -d /tmp/nucleus-machine-root-test.XXXXXX)"
        trap '/bin/rm -rf "$fixture"' EXIT
        /bin/mkdir -p "$fixture/owned/GitHubActionsRunner" "$fixture/owned/Builder"
        /bin/mkdir -p "$fixture/empty"
        /bin/mkdir -p "$fixture/shared/GitHubActionsRunner" "$fixture/shared/Preferences"
        /bin/ln -s owned "$fixture/link"

        report nucleus_machine_root_holds_only_builder_state "$fixture/owned"
        report nucleus_machine_root_holds_only_builder_state "$fixture/empty"
        report nucleus_machine_root_holds_only_builder_state "$fixture/shared"
        report nucleus_machine_root_holds_only_builder_state "$fixture/link"
        report nucleus_machine_root_holds_only_builder_state "$fixture/absent"
        """,
        "machine-root-test",
        guardLibrary.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(errorOutput.isEmpty)
    #expect(
        String(decoding: output, as: UTF8.self).split(separator: "\n")
            == [
                // Only the system Library holds machine-wide builder state.
                "accept", "accept", "reject", "reject", "reject", "reject",
                // Only the two subtrees this provisioning creates may be removed.
                "accept", "accept", "reject", "reject", "reject",
            ])
}

private func loadMacOSBuilderContract() throws -> MacOSBuilderContract {
    try MacOSBuilderContract.load(
        root: FilePath(workspaceRootForMacOSBuilderTests().path))
}

private func workspaceRootForMacOSBuilderTests() throws -> URL {
    let path = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    return URL(path, isDirectory: true)
}
