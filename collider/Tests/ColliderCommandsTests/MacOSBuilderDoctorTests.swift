import Foundation
import Testing

@testable import ColliderCommands

@Test
func macOSBuilderContractSelectsOneImmutableHost() throws {
    let root = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    let contract = try MacOSBuilderContract.load(
        root: URL(fileURLWithPath: root, isDirectory: true))

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
    let versions = """
        [
          {
            "appName": "container",
            "buildType": "release",
            "commit": "6e65319fe476ffe8db8ddaf828a537ed36fe2859",
            "version": "1.2.0"
          },
          {
            "appName": "container-apiserver",
            "buildType": "release",
            "commit": "6e65319fe476ffe8db8ddaf828a537ed36fe2859",
            "version": "container-apiserver version 1.2.0 (build: release, commit: 6e65319)"
          }
        ]
        """
    let status = """
        {
          "status": "running",
          "appRoot": "/Volumes/NucleusOCI/apple-container/",
          "installRoot": "/usr/local/"
        }
        """
    let network = """
        [
          {
            "configuration": {
              "mode": "hostOnly",
              "name": "nucleus-build-internal"
            }
          }
        ]
        """

    #expect(
        MacOSBuilderDoctor.containerVersionDetail(
            versions, contract: contract) != nil)
    #expect(
        MacOSBuilderDoctor.containerStatusDetail(
            status, contract: contract) != nil)
    #expect(
        MacOSBuilderDoctor.hostOnlyNetworkDetail(
            network, contract: contract) != nil)
}

@Test
func macOSBuilderDoctorRejectsDriftedContainerEvidence() throws {
    let contract = try loadMacOSBuilderContract()
    let wrongVersion = """
        [
          {
            "appName": "container",
            "commit": "wrong",
            "version": "1.2.1"
          }
        ]
        """
    let wrongRoot = """
        {
          "status": "running",
          "appRoot": "/Users/developer/Library/Application Support/container",
          "installRoot": "/usr/local"
        }
        """
    let routedNetwork = """
        [
          {
            "configuration": {
              "mode": "nat",
              "name": "nucleus-build-internal"
            }
          }
        ]
        """

    #expect(
        MacOSBuilderDoctor.containerVersionDetail(
            wrongVersion, contract: contract) == nil)
    #expect(
        MacOSBuilderDoctor.containerStatusDetail(
            wrongRoot, contract: contract) == nil)
    #expect(
        MacOSBuilderDoctor.hostOnlyNetworkDetail(
            routedNetwork, contract: contract) == nil)
}

@Test
func persistentServiceTemplateCarriesTheDeclaredIdentity() throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let contract = try MacOSBuilderContract.load(root: root)
    let template = try String(
        contentsOf: root.appendingPathComponent(
            "tools/macos-builder/com.nucleus.container-system-start.plist.in"),
        encoding: .utf8)
    let rendered =
        template

    #expect(
        MacOSBuilderDoctor.persistentServiceDetail(
            Data(rendered.utf8), contract: contract)
            == "login-session/com.nucleus.container-system-start")
}

@Test
func ciMacOSBuilderDoctorScopeDryRunsWithoutHostMutation() async throws {
    let root = try workspaceRootForMacOSBuilderTests()
    let command = try Doctor.parse(["ci-macos-builder", "--dry-run"])
    #expect(command.scope == .ciMacOSBuilder)
    #expect(command.dryRun)

    try await WorkspaceDoctor(
        context: WorkspaceContext(
            root: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    ).run(
        scope: .ciMacOSBuilder,
        dryRun: true,
        json: false,
        quiet: true)
}

private func loadMacOSBuilderContract() throws -> MacOSBuilderContract {
    try MacOSBuilderContract.load(root: workspaceRootForMacOSBuilderTests())
}

private func workspaceRootForMacOSBuilderTests() throws -> URL {
    let path = try #require(
        discoverWorkspaceRoot(from: FileManager.default.currentDirectoryPath))
    return URL(fileURLWithPath: path, isDirectory: true)
}
