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
    #expect(
        contract.launchd.starterRelativePath
            == "Library/Application Support/Nucleus/bin/container-system-start")
    #expect(contract.launchd.maximumOpenFileCount == 245_760)
    #expect(contract.environment.buildRoot == "/Volumes/NucleusBuild")
    #expect(contract.environment.xdgCacheHome == "/Volumes/NucleusCache")
    #expect(
        contract.environment.nativeSDKRoot
            == "/Volumes/NucleusCache/nucleus/nucleus-native-sdk/linux-arm64")
    #expect(
        contract.environment.androidSDKRoot
            == "/Volumes/NucleusCache/android-sdk")
    #expect(Set(contract.storage.map(\.name)).count == contract.storage.count)
    #expect(contract.storage.allSatisfy { $0.quotaBytes > 0 })
    #expect(
        contract.storage.filter { $0.storageClass == .source }
            .allSatisfy { $0.cleanupPolicy == .protected })
    #expect(
        contract.storage.filter { $0.recoverability == .immutable }
            .allSatisfy { $0.cleanupPolicy == .protected })
    #expect(
        contract.storage.first { $0.name == "NucleusDev" }?.owner
            == "remote-development")
    #expect(
        contract.storage.first { $0.name == "NucleusOCI" }?.owner
            == "apple-container")
}

@Test
func macOSBuilderDoctorAcceptsPinnedContainerEvidence() throws {
    let contract = try loadMacOSBuilderContract()
    let health = OCIRuntimeHealth(
        appRoot: URL(fileURLWithPath: "/Volumes/NucleusOCI/apple-container/"),
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
            health, contract: contract) != nil)
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
            driftedHealth, contract: contract) == nil)
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
        "/Users/builder/Library/Application Support/Nucleus/bin/container-system-start"
    let rendered = template.replacingOccurrences(
        of: "NUCLEUS_CONTAINER_STARTER_PATH",
        with: starterPath)

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
            contract: contract)
            == "login-session/com.nucleus.container-system-start")

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

private func loadMacOSBuilderContract() throws -> MacOSBuilderContract {
    try MacOSBuilderContract.load(
        root: FilePath(workspaceRootForMacOSBuilderTests().path))
}

private func workspaceRootForMacOSBuilderTests() throws -> URL {
    let path = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    return URL(path, isDirectory: true)
}
