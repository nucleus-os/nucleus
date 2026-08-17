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

    #expect(contract.operatingSystem.productVersion == "27.0")
    #expect(contract.operatingSystem.buildVersion == "26A5388g")
    #expect(
        contract.xcode.developerDirectory
            == "/Applications/Xcode-beta.app/Contents/Developer")
    #expect(contract.xcode.version == "27.0")
    #expect(contract.xcode.buildVersion == "27A5228h")
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
func builderHandoffReconcilesOnlySupportedLocalAndRunnerStates() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let stateLibrary = root.appendingPathComponent(
        "tools/macos-builder/handoff-state.sh")
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        nucleus_handoff_local_state absent absent absent
        nucleus_handoff_local_state present present absent
        nucleus_handoff_local_state present absent pre-artifact
        nucleus_handoff_local_state present absent unregistered
        nucleus_handoff_local_state present absent registered
        nucleus_handoff_local_state present absent absent
        nucleus_handoff_runner_state '' nucleus-m2-ultra
        nucleus_handoff_runner_state nucleus-m2-ultra nucleus-m2-ultra
        nucleus_handoff_runner_state foreign nucleus-m2-ultra
        nucleus_handoff_runner_state $'nucleus-m2-ultra\\nforeign' nucleus-m2-ultra
        nucleus_handoff_action fresh fresh
        nucleus_handoff_action pre-artifact fresh
        nucleus_handoff_action unregistered fresh
        nucleus_handoff_action registered complete
        nucleus_handoff_action complete complete
        nucleus_handoff_action fresh complete
        nucleus_handoff_action complete fresh
        """,
        "handoff-state-test",
        stateLibrary.path,
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
                "fresh",
                "complete",
                "pre-artifact",
                "unregistered",
                "registered",
                "inconsistent",
                "fresh",
                "complete",
                "inconsistent",
                "inconsistent",
                "provision",
                "provision",
                "provision",
                "finalize",
                "verify",
                "inconsistent",
                "inconsistent",
            ])
}

@Test
func builderACLTraversalDoesNotFollowSymbolicLinks() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let aclLibrary = root.appendingPathComponent(
        "tools/macos-builder/builder-acl.sh")
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        set -euo pipefail
        source "$1"
        fixture="$(mktemp -d /tmp/nucleus-builder-acl-test.XXXXXX)"
        trap '/usr/bin/find "$fixture" -mindepth 1 -delete; /bin/rmdir "$fixture"' EXIT
        /bin/mkdir "$fixture/checkout"
        /usr/bin/touch "$fixture/checkout/file" "$fixture/outside"
        /bin/ln -s ../outside "$fixture/checkout/live-link"
        /bin/ln -s missing "$fixture/checkout/broken-link"
        outside_before="$(/bin/ls -lde "$fixture/outside")"
        user="$(/usr/bin/id -un)"
        nucleus_apply_acl_tree \
          "$fixture/checkout" \
          "$user allow read,execute" \
          "$user allow read,execute,file_inherit,directory_inherit"
        [[ $(/bin/ls -lde "$fixture/outside") == "$outside_before" ]]
        /bin/ls -lde "$fixture/checkout/broken-link" \
          | /usr/bin/grep -q "user:$user allow read,execute"
        """,
        "builder-acl-test",
        aclLibrary.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(output.isEmpty)
    #expect(errorOutput.isEmpty)
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
