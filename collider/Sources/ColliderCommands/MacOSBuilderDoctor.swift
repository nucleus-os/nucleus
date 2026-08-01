import Foundation

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
        let starterPath: String
        let standardOutPath: String
        let standardErrorPath: String
    }

    struct Resources: Codable, Sendable {
        let physicalCPUCount: Int
        let memoryBytes: UInt64
    }

    struct Storage: Codable, Sendable {
        let name: String
        let mountPath: String
        let quotaBytes: UInt64
        let reserveBytes: UInt64
        let recoverability: String
        let retention: String
        let reclaimable: Bool
    }

    let operatingSystem: OperatingSystem
    let xcode: Xcode
    let appleContainer: AppleContainer
    let launchd: Launchd
    let resources: Resources
    let storage: [Storage]

    static let relativePath = "tools/macos-builder/contract.json"

    static func load(root: URL) throws -> MacOSBuilderContract {
        let url = root.appendingPathComponent(relativePath)
        return try JSONDecoder().decode(
            MacOSBuilderContract.self,
            from: Data(contentsOf: url))
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
            rosetta(scope: scope),
            hostOnlyNetwork(contract, scope: scope),
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
                "stop the user-domain service, then run sudo tools/macos-builder/install-container-service.sh <service-user>"
        ) {
            let fileManager = FileManager.default
            guard
                let home = context.environment["HOME"],
                fileManager.isExecutableFile(
                    atPath: contract.launchd.starterPath),
                let plistData = fileManager.contents(
                    atPath: URL(fileURLWithPath: home)
                        .appendingPathComponent(
                            contract.launchd.plistRelativePath
                        ).path),
                let serviceDetail = Self.persistentServiceDetail(
                    plistData, contract: contract),
                let uid = try? await context.run(
                    "/usr/bin/id", ["-u"], capture: true),
                let launchd = try? await context.run(
                    "/bin/launchctl",
                    ["print", "gui/\(uid)/\(contract.launchd.label)"],
                    capture: true),
                !launchd.isEmpty
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
                let versionOutput = try? await context.run(
                    contract.appleContainer.executable,
                    ["system", "version", "--format", "json"],
                    capture: true),
                let versionDetail = Self.containerVersionDetail(
                    versionOutput, contract: contract),
                let statusOutput = try? await context.run(
                    contract.appleContainer.executable,
                    ["system", "status", "--format", "json"],
                    capture: true),
                let statusDetail = Self.containerStatusDetail(
                    statusOutput, contract: contract)
            else { return nil }
            return "\(versionDetail), \(statusDetail)"
        }
    }

    private func rosetta(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:rosetta",
            scope: scope,
            description: "Rosetta x86_64 execution",
            remediation:
                "run sudo softwareupdate --install-rosetta --agree-to-license"
        ) {
            guard
                let output = try? await context.run(
                    "/usr/bin/arch",
                    ["-x86_64", "/usr/bin/uname", "-m"],
                    capture: true),
                output == "x86_64"
            else { return nil }
            return output
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
                let output = try? await context.run(
                    contract.appleContainer.executable,
                    [
                        "network", "inspect",
                        contract.appleContainer.network,
                    ],
                    capture: true),
                let detail = Self.hostOnlyNetworkDetail(
                    output, contract: contract)
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
                let list = try? PropertyListDecoder().decode(
                    APFSList.self,
                    from: Data(listOutput.utf8))
            else { return nil }
            let declaredNames = Set(contract.storage.map(\.name))
            var volumes: [String: APFSList.Volume] = [:]
            for volume in list.containers.flatMap(\.volumes)
            where declaredNames.contains(volume.name) {
                guard volumes.updateValue(volume, forKey: volume.name) == nil else {
                    return nil
                }
            }
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
                        + (declaration.reclaimable ? " reclaimable" : " protected"))
            }
            return details.joined(separator: ", ")
        }
    }

    static func persistentServiceDetail(
        _ data: Data,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let plist = try? PropertyListDecoder().decode(
                PersistentServicePlist.self,
                from: data),
            plist.label == contract.launchd.label,
            plist.programArguments == [contract.launchd.starterPath],
            plist.standardOutPath == contract.launchd.standardOutPath,
            plist.standardErrorPath == contract.launchd.standardErrorPath,
            plist.runAtLoad,
            Set(plist.limitLoadToSessionType) == ["Aqua", "Background"]
        else { return nil }
        return "login-session/\(plist.label)"
    }

    static func containerVersionDetail(
        _ output: String,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let versions = try? JSONDecoder().decode(
                [ContainerVersionRecord].self,
                from: Data(output.utf8)),
            versions.contains(where: {
                $0.appName == "container"
                    && $0.version == contract.appleContainer.version
                    && $0.commit == contract.appleContainer.commit
            }),
            versions.contains(where: {
                $0.appName == "container-apiserver"
                    && $0.commit == contract.appleContainer.commit
            })
        else { return nil }
        return "\(contract.appleContainer.version) (\(contract.appleContainer.commit.prefix(7)))"
    }

    static func containerStatusDetail(
        _ output: String,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let status = try? JSONDecoder().decode(
                ContainerSystemStatus.self,
                from: Data(output.utf8)),
            status.status == "running",
            normalizedPath(status.appRoot)
                == normalizedPath(contract.appleContainer.appRoot),
            normalizedPath(status.installRoot)
                == normalizedPath(contract.appleContainer.installRoot)
        else { return nil }
        return "running at \(status.appRoot)"
    }

    static func hostOnlyNetworkDetail(
        _ output: String,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let networks = try? JSONDecoder().decode(
                [ContainerNetworkInspection].self,
                from: Data(output.utf8)),
            networks.count == 1,
            networks[0].configuration.name == contract.appleContainer.network,
            networks[0].configuration.mode == "hostOnly"
        else { return nil }
        return "\(networks[0].configuration.name) mode=hostOnly"
    }
}

private struct ContainerVersionRecord: Decodable {
    let appName: String
    let commit: String
    let version: String
}

private struct ContainerSystemStatus: Decodable {
    let status: String
    let appRoot: String
    let installRoot: String
}

private struct ContainerNetworkInspection: Decodable {
    struct Configuration: Decodable {
        let mode: String
        let name: String
    }

    let configuration: Configuration
}

private struct PersistentServicePlist: Decodable {
    let label: String
    let programArguments: [String]
    let limitLoadToSessionType: [String]
    let runAtLoad: Bool
    let standardOutPath: String
    let standardErrorPath: String

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case limitLoadToSessionType = "LimitLoadToSessionType"
        case runAtLoad = "RunAtLoad"
        case standardOutPath = "StandardOutPath"
        case standardErrorPath = "StandardErrorPath"
    }
}

private struct APFSList: Decodable {
    struct Container: Decodable {
        let volumes: [Volume]

        enum CodingKeys: String, CodingKey {
            case volumes = "Volumes"
        }
    }

    struct Volume: Decodable {
        let name: String
        let capacityInUse: UInt64
        let capacityQuota: UInt64
        let capacityReserve: UInt64

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case capacityInUse = "CapacityInUse"
            case capacityQuota = "CapacityQuota"
            case capacityReserve = "CapacityReserve"
        }
    }

    let containers: [Container]

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
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
