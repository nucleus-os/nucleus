import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct MacOSBuilderContract: Codable, Sendable {
    struct OperatingSystem: Codable, Sendable {
        let productVersion: String
        let buildVersion: String
    }

    struct Xcode: Codable, Sendable {
        let developerDirectory: String
        let version: String
        let buildVersion: String
        let swiftVersionFragment: String
        let testingMacroPluginRelativePath: String
    }

    struct AppleContainer: Codable, Sendable {
        let version: String
        let commit: String
        let installerURL: String
        let installerSHA256: String
        let executable: String
        let apiServerExecutable: String
        let appRoot: String
        let installRoot: String
        let network: String
    }

    struct Launchd: Codable, Sendable {
        let label: String
        let plistRelativePath: String
        let starterRelativePath: String
        let standardOutPath: String
        let standardErrorPath: String
        let maximumOpenFileCount: UInt64
    }

    struct Resources: Codable, Sendable {
        let physicalCPUCount: Int
        let memoryBytes: UInt64
    }

    struct Environment: Codable, Sendable {
        let buildRoot: String
        let xdgCacheHome: String
        let nativeSDKRoot: String
        let androidSDKRoot: String
    }

    struct Storage: Codable, Sendable {
        enum Recoverability: String, Codable, Sendable {
            case protected
            case reconstructible
            case immutable
            case diagnostic
        }

        let name: String
        let mountPath: String
        let owner: String
        let storageClass: StorageClass
        let quotaBytes: UInt64
        let reserveBytes: UInt64
        let recoverability: Recoverability
        let retention: String
        let cleanupPolicy: StorageCleanupPolicy
    }

    let operatingSystem: OperatingSystem
    let xcode: Xcode
    let appleContainer: AppleContainer
    let launchd: Launchd
    let resources: Resources
    let environment: Environment
    let storage: [Storage]

    static let relativePath = "tools/macos-builder/contract.json"

    static func load(root: FilePath) throws -> MacOSBuilderContract {
        let url = URL(fileURLWithPath: root.appending(relativePath).string)
        let contract = try JSONDecoder().decode(
            MacOSBuilderContract.self,
            from: Data(contentsOf: url))
        try contract.validate()
        return contract
    }

    private func validate() throws {
        guard Set(storage.map(\.name)).count == storage.count,
            Set(storage.map(\.mountPath)).count == storage.count
        else {
            throw MacOSBuilderContractFailure.invalid(
                "storage names and mount paths must be unique")
        }
        guard launchd.maximumOpenFileCount > 0 else {
            throw MacOSBuilderContractFailure.invalid(
                "launchd maximum open-file count must be positive")
        }
        for declaration in storage {
            guard declaration.mountPath.hasPrefix("/"),
                declaration.quotaBytes > 0,
                declaration.quotaBytes >= declaration.reserveBytes
            else {
                throw MacOSBuilderContractFailure.invalid(
                    "invalid storage capacity declaration: \(declaration.name)")
            }
            if [.source, .sourceSnapshot, .published].contains(
                declaration.storageClass),
                declaration.cleanupPolicy != .protected
            {
                throw MacOSBuilderContractFailure.invalid(
                    "protected storage class has a cleanup policy: \(declaration.name)")
            }
            if [.protected, .immutable].contains(declaration.recoverability),
                declaration.cleanupPolicy != .protected
            {
                throw MacOSBuilderContractFailure.invalid(
                    "protected storage is reclaimable: \(declaration.name)")
            }
        }
        guard
            let build = storage.first(where: { $0.name == "NucleusBuild" }),
            isDescendant(environment.buildRoot, of: build.mountPath),
            let cache = storage.first(where: { $0.name == "NucleusCache" }),
            isDescendant(environment.xdgCacheHome, of: cache.mountPath),
            isDescendant(environment.nativeSDKRoot, of: cache.mountPath),
            URL(fileURLWithPath: environment.nativeSDKRoot).lastPathComponent
                == "linux-arm64",
            isDescendant(environment.androidSDKRoot, of: cache.mountPath),
            let oci = storage.first(where: { $0.name == "NucleusOCI" }),
            isDescendant(appleContainer.appRoot, of: oci.mountPath),
            let logs = storage.first(where: { $0.name == "NucleusLogs" }),
            isDescendant(launchd.standardOutPath, of: logs.mountPath),
            isDescendant(launchd.standardErrorPath, of: logs.mountPath)
        else {
            throw MacOSBuilderContractFailure.invalid(
                "service and build paths must remain inside their declared storage volumes")
        }
    }
}

enum MacOSBuilderContractFailure: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

struct MacOSBuilderDoctor {
    let context: WorkspaceContext

    var prerequisites: [HostPrerequisite] {
        let scope = DoctorScope.ciMacOSBuilder.rawValue
        let contract: MacOSBuilderContract
        do {
            contract = try MacOSBuilderContract.load(root: context.root)
        } catch {
            return [
                HostPrerequisite(
                    id: "macos-builder:contract",
                    scope: scope,
                    description: "macOS builder host contract",
                    remediation:
                        "restore \(MacOSBuilderContract.relativePath): \(error)"
                ) { nil }
            ]
        }

        return [
            operatingSystem(contract, scope: scope),
            xcode(contract, scope: scope),
            swiftBootstrap(contract, scope: scope),
            resources(contract, scope: scope),
            persistentService(contract, scope: scope),
            containerSystem(contract, scope: scope),
            hostOnlyNetwork(contract, scope: scope),
            storageEnvironment(contract, scope: scope),
            storage(contract, scope: scope),
        ]
    }

    private func operatingSystem(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:operating-system",
            scope: scope,
            description:
                "macOS \(contract.operatingSystem.productVersion) build \(contract.operatingSystem.buildVersion)",
            remediation:
                "provision the selected macOS 27 beta build from \(MacOSBuilderContract.relativePath)"
        ) {
            guard
                let version = try? await context.run(
                    "/usr/bin/sw_vers", ["-productVersion"], capture: true),
                let build = try? await context.run(
                    "/usr/bin/sw_vers", ["-buildVersion"], capture: true),
                version == contract.operatingSystem.productVersion,
                build == contract.operatingSystem.buildVersion
            else { return nil }
            return "macOS \(version) (\(build))"
        }
    }

    private func xcode(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:xcode",
            scope: scope,
            description:
                "Xcode \(contract.xcode.version) build \(contract.xcode.buildVersion)",
            remediation:
                "install the selected Xcode 27 beta and select its developer directory during host provisioning"
        ) {
            guard
                let selected = try? await context.run(
                    "/usr/bin/xcode-select", ["--print-path"],
                    capture: true),
                selected == contract.xcode.developerDirectory,
                let output = try? await context.run(
                    "/usr/bin/xcodebuild", ["-version"], capture: true),
                output
                    == "Xcode \(contract.xcode.version)\nBuild version \(contract.xcode.buildVersion)",
                FileManager.default.fileExists(
                    atPath: URL(
                        fileURLWithPath: contract.xcode.developerDirectory
                    ).appendingPathComponent(
                        contract.xcode.testingMacroPluginRelativePath
                    ).path)
            else { return nil }
            return "Xcode \(contract.xcode.version) (\(contract.xcode.buildVersion))"
        }
    }

    private func swiftBootstrap(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:swift",
            scope: scope,
            description: "selected Xcode Swift 6.4 compiler",
            remediation:
                "select the Xcode developer directory declared in \(MacOSBuilderContract.relativePath)"
        ) {
            guard
                let output = try? await context.run(
                    "/usr/bin/xcrun", ["swift", "--version"], capture: true),
                output.contains(contract.xcode.swiftVersionFragment)
            else { return nil }
            return output.split(separator: "\n").prefix(2).joined(separator: " ")
        }
    }

    private func resources(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:resources",
            scope: scope,
            description:
                "\(contract.resources.physicalCPUCount) physical CPUs and \(contract.resources.memoryBytes) bytes memory",
            remediation: "run this lane on the declared M2 Ultra host"
        ) {
            guard
                let cpuOutput = try? await context.run(
                    "/usr/sbin/sysctl", ["-n", "hw.physicalcpu"],
                    capture: true),
                let memoryOutput = try? await context.run(
                    "/usr/sbin/sysctl", ["-n", "hw.memsize"],
                    capture: true),
                let cpuCount = Int(cpuOutput),
                let memoryBytes = UInt64(memoryOutput),
                cpuCount == contract.resources.physicalCPUCount,
                memoryBytes == contract.resources.memoryBytes
            else { return nil }
            return "\(cpuCount) CPUs, \(memoryBytes) bytes"
        }
    }

    private func persistentService(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:persistent-container-service",
            scope: scope,
            description: "persistent login-session Apple container service",
            remediation:
                "stop the login-session service, then run tools/macos-builder/install-container-service.sh"
        ) {
            let fileManager = FileManager.default
            guard let home = context.environment["HOME"] else { return nil }
            let starterPath = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(contract.launchd.starterRelativePath)
                .path
            guard
                fileManager.isExecutableFile(
                    atPath: starterPath),
                let plistData = fileManager.contents(
                    atPath: URL(fileURLWithPath: home)
                        .appendingPathComponent(
                            contract.launchd.plistRelativePath
                        ).path),
                let uid = try? await context.run(
                    "/usr/bin/id", ["-u"], capture: true),
                let launchd = try? await context.run(
                    "/bin/launchctl",
                    ["print", "gui/\(uid)/\(contract.launchd.label)"],
                    capture: true),
                let serviceDetail = Self.persistentServiceDetail(
                    plistData,
                    launchdOutput: launchd,
                    starterPath: starterPath,
                    contract: contract)
            else { return nil }
            return serviceDetail
        }
    }

    private func containerSystem(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:apple-container",
            scope: scope,
            description:
                "Apple container \(contract.appleContainer.version) at the declared application root",
            remediation:
                "install the signed pinned package and provision the persistent login-session service"
        ) {
            guard
                let health = try? await context.runtime.ociRuntimeHealth(),
                let detail = Self.containerSystemDetail(
                    health, contract: contract)
            else { return nil }
            return detail
        }
    }

    private func hostOnlyNetwork(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:host-only-network",
            scope: scope,
            description:
                "host-only Apple container network \(contract.appleContainer.network)",
            remediation:
                "run container network create --internal \(contract.appleContainer.network)"
        ) {
            guard
                let network = try? await context.runtime.ociRuntimeNetwork(
                    named: contract.appleContainer.network),
                let detail = Self.hostOnlyNetworkDetail(
                    network, contract: contract)
            else { return nil }
            return detail
        }
    }

    private func storage(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:storage",
            scope: scope,
            description: "declared case-sensitive APFS storage and quotas",
            remediation:
                "provision every volume and quota declared by \(MacOSBuilderContract.relativePath)"
        ) {
            guard
                let listOutput = try? await context.run(
                    "/usr/sbin/diskutil", ["apfs", "list", "-plist"],
                    capture: true),
                let volumes = try? APFSStorageInventory.decode(listOutput)
            else { return nil }
            let declaredNames = Set(contract.storage.map(\.name))
            guard declaredNames.isSubset(of: Set(volumes.keys)) else { return nil }
            var details: [String] = []
            for declaration in contract.storage {
                guard
                    let volume = volumes[declaration.name],
                    volume.capacityQuota >= declaration.quotaBytes,
                    volume.capacityReserve >= declaration.reserveBytes,
                    let infoOutput = try? await context.run(
                        "/usr/sbin/diskutil",
                        ["info", "-plist", declaration.mountPath],
                        capture: true),
                    let info = try? PropertyListDecoder().decode(
                        MountedVolumeInfo.self,
                        from: Data(infoOutput.utf8)),
                    info.volumeName == declaration.name,
                    info.mountPoint == declaration.mountPath,
                    info.filesystemName == "Case-sensitive APFS",
                    info.globalPermissionsEnabled
                else { return nil }
                details.append(
                    "\(declaration.name)=\(volume.capacityInUse)/\(volume.capacityQuota)"
                        + " \(declaration.cleanupPolicy.rawValue)")
            }
            return details.joined(separator: ", ")
        }
    }

    private func storageEnvironment(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:storage-environment",
            scope: scope,
            description: "declared Collider cache and SDK roots",
            remediation:
                "run the installed 'collider' command; its launcher resolves macOS storage from \(MacOSBuilderContract.relativePath)"
        ) {
            guard
                normalizedPath(context.environment["XDG_CACHE_HOME"] ?? "")
                    == normalizedPath(contract.environment.xdgCacheHome),
                normalizedPath(
                    context.environment["NUCLEUS_NATIVE_SDK_ROOT"] ?? "")
                    == normalizedPath(contract.environment.nativeSDKRoot),
                normalizedPath(context.environment["NUCLEUS_BUILD_ROOT"] ?? "")
                    == normalizedPath(contract.environment.buildRoot),
                normalizedPath(context.environment["ANDROID_SDK_ROOT"] ?? "")
                    == normalizedPath(contract.environment.androidSDKRoot)
            else { return nil }
            return
                "build root \(contract.environment.buildRoot), XDG cache \(contract.environment.xdgCacheHome), native SDK \(contract.environment.nativeSDKRoot)"
        }
    }

    static func persistentServiceDetail(
        _ data: Data,
        launchdOutput: String,
        starterPath: String,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let plist = try? PropertyListDecoder().decode(
                PersistentServicePlist.self,
                from: data),
            plist.label == contract.launchd.label,
            plist.programArguments == [starterPath],
            plist.standardOutPath == contract.launchd.standardOutPath,
            plist.standardErrorPath == contract.launchd.standardErrorPath,
            plist.runAtLoad,
            Set(plist.limitLoadToSessionType) == ["Aqua", "Background"],
            plist.softResourceLimits.numberOfFiles
                == contract.launchd.maximumOpenFileCount,
            plist.hardResourceLimits.numberOfFiles
                == contract.launchd.maximumOpenFileCount,
            launchdOutput.contains(
                "maxfiles (soft) => \(contract.launchd.maximumOpenFileCount)"),
            launchdOutput.contains(
                "maxfiles (hard) => \(contract.launchd.maximumOpenFileCount)")
        else { return nil }
        return "login-session/\(plist.label)"
    }

    static func containerSystemDetail(
        _ health: OCIRuntimeHealth,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            health.apiServerAppName == "container-apiserver",
            health.apiServerVersion.contains(
                "version \(contract.appleContainer.version)"),
            health.apiServerCommit == contract.appleContainer.commit,
            normalizedPath(health.appRoot.path)
                == normalizedPath(contract.appleContainer.appRoot),
            normalizedPath(health.installRoot.path)
                == normalizedPath(contract.appleContainer.installRoot)
        else { return nil }
        return "\(contract.appleContainer.version) "
            + "(\(contract.appleContainer.commit.prefix(7))), running at "
            + health.appRoot.path
    }

    static func hostOnlyNetworkDetail(
        _ network: OCIRuntimeNetworkState,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            network.name == contract.appleContainer.network,
            network.mode == "hostOnly"
        else { return nil }
        return "\(network.name) mode=hostOnly"
    }
}

private struct PersistentServicePlist: Decodable {
    struct ResourceLimits: Decodable {
        let numberOfFiles: UInt64

        enum CodingKeys: String, CodingKey {
            case numberOfFiles = "NumberOfFiles"
        }
    }

    let label: String
    let programArguments: [String]
    let limitLoadToSessionType: [String]
    let runAtLoad: Bool
    let standardOutPath: String
    let standardErrorPath: String
    let softResourceLimits: ResourceLimits
    let hardResourceLimits: ResourceLimits

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case limitLoadToSessionType = "LimitLoadToSessionType"
        case runAtLoad = "RunAtLoad"
        case standardOutPath = "StandardOutPath"
        case standardErrorPath = "StandardErrorPath"
        case softResourceLimits = "SoftResourceLimits"
        case hardResourceLimits = "HardResourceLimits"
    }
}

private struct MountedVolumeInfo: Decodable {
    let volumeName: String
    let mountPoint: String
    let filesystemName: String
    let globalPermissionsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case volumeName = "VolumeName"
        case mountPoint = "MountPoint"
        case filesystemName = "FilesystemName"
        case globalPermissionsEnabled = "GlobalPermissionsEnabled"
    }
}

private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func isDescendant(_ path: String, of root: String) -> Bool {
    FilePath(path).lexicallyNormalized().isContained(
        in: FilePath(root).lexicallyNormalized())
}
