import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

struct MacOSBuilderContract: Codable, Sendable {
    struct OperatingSystem: Codable, Sendable {
        let majorVersion: Int
    }

    struct Xcode: Codable, Sendable {
        let developerDirectory: String
        let majorVersion: Int
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
        let installRoot: String
        let network: String
    }

    struct Launchd: Codable, Sendable {
        let label: String
        let maximumOpenFileCount: UInt64
    }

    struct Resources: Codable, Sendable {
        let physicalCPUCount: Int
        let memoryBytes: UInt64
    }

    struct Builder: Codable, Sendable {
        let user: String
        let group: String
        let home: String
        let developerUser: String
        let authoritativeCheckout: String
        let organization: String
        let repository: String
        let runnerGroup: String
        let runnerLabel: String
        let runnerName: String
        let runnerVersion: String
        let runnerArchiveURL: String
        let runnerArchiveSHA256: String
        let runnerArchiveSize: UInt64
        let runnerServiceLabel: String
        let runnerWatchdogServiceLabel: String
        let runnerWatchdogIntervalSeconds: UInt64
        let bootCoordinatorServiceLabel: String
        let bootCoordinatorIntervalSeconds: UInt64
        let runnerRoot: String
        let buildStateGroup: String
        let hostContractRoot: String
        let hostExecutionLock: String
        let runnerWorkRoot: String
    }

    let operatingSystem: OperatingSystem
    let xcode: Xcode
    let appleContainer: AppleContainer
    let launchd: Launchd
    let builder: Builder
    let resources: Resources

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
        guard launchd.maximumOpenFileCount > 0 else {
            throw MacOSBuilderContractFailure.invalid(
                "launchd maximum open-file count must be positive")
        }
        // The builder selects major macOS and Xcode releases. Their beta build
        // identifiers move under the host without changing what Nucleus needs.
        guard operatingSystem.majorVersion > 0, xcode.majorVersion > 0 else {
            throw MacOSBuilderContractFailure.invalid(
                "selected macOS and Xcode major versions must be positive")
        }
        // The reading group exists so the interactive developer can inspect run
        // records and artifacts without gaining the builder's own group, which
        // gates the runner registration credentials.
        guard builder.buildStateGroup != builder.group else {
            throw MacOSBuilderContractFailure.invalid(
                "build-state group must be distinct from the builder's primary group")
        }
        // A builder in staff would inherit read access to the whole
        // interactive home, which is mode 0750 and staff-readable.
        guard builder.group != "staff", builder.group != "wheel", builder.group != "admin",
            builder.buildStateGroup != "staff", builder.buildStateGroup != "wheel",
            builder.buildStateGroup != "admin"
        else {
            throw MacOSBuilderContractFailure.invalid(
                "builder group must be dedicated, not a shared system group")
        }
        guard builder.user == "nucleus-builder",
            builder.home == "/Users/nucleus-builder",
            builder.organization == "https://github.com/nucleus-os",
            builder.runnerGroup == "nucleus",
            builder.runnerLabel == "nucleus-m2-ultra",
            builder.runnerArchiveSHA256.count == 64,
            builder.runnerArchiveSize > 0,
            builder.runnerWatchdogIntervalSeconds > 0,
            builder.bootCoordinatorIntervalSeconds > 0,
            [
                builder.runnerServiceLabel,
                builder.runnerWatchdogServiceLabel,
                builder.bootCoordinatorServiceLabel,
            ].allSatisfy({ !$0.isEmpty }),
            Set([
                builder.runnerServiceLabel,
                builder.runnerWatchdogServiceLabel,
                builder.bootCoordinatorServiceLabel,
            ]).count == 3
        else {
            throw MacOSBuilderContractFailure.invalid(
                "builder identity and pinned runner contract are invalid")
        }
        // The Actions runner formats a `run:` step into one command string that
        // the process launcher resplits, so whitespace in any of these roots
        // reaches bash as separate arguments and fails every step body. The
        // work root matters most: step scripts are written to its `_temp`.
        for root in [
            builder.runnerRoot, builder.hostContractRoot, builder.runnerWorkRoot,
            builder.authoritativeCheckout,
        ] {
            guard root.hasPrefix("/"),
                !root.hasSuffix("/"),
                FilePath(root).components.count >= 2,
                root.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }
                )
            else {
                throw MacOSBuilderContractFailure.invalid(
                    "machine-wide builder root is not an absolute whitespace-free path: \(root)")
            }
        }
        // Two accounts share the checkout, so it lives in neither home. A
        // checkout inside one leaves the builder able to traverse that home but
        // not read it, which makes the tree's own absolute path unresolvable to
        // the identity that builds it.
        guard !builder.authoritativeCheckout.hasPrefix("/Users/") else {
            throw MacOSBuilderContractFailure.invalid(
                "authoritative checkout must not live in a user home: "
                    + builder.authoritativeCheckout)
        }
        // Collider locks the machine-wide execution lease at a compiled-in
        // path, because the machine, not a checkout it owns, decides which
        // inode serializes its execution. The declared path exists so the
        // privileged shell provisioning installs that same inode.
        guard builder.hostContractRoot == MacOSMachineStorageLayout.contractRoot.string,
            builder.hostExecutionLock
                == MacOSMachineStorageLayout.hostExecutionAdmission.string
        else {
            throw MacOSBuilderContractFailure.invalid(
                "declared machine-wide paths disagree with the compiled Collider layout")
        }
        // Both roots share one machine-wide parent, so retirement removes the
        // installed builder state as one directory derived from the installed
        // service rather than from the contract that may already have moved.
        guard
            FilePath(builder.runnerRoot).removingLastComponent()
                == FilePath(builder.hostContractRoot).removingLastComponent()
        else {
            throw MacOSBuilderContractFailure.invalid(
                "runner root and host contract root must share one machine-wide parent")
        }
        // The job checkout lives in builder-owned per-user storage rather than
        // under the machine root, so retiring or upgrading the runner never
        // destroys a multi-gigabyte submodule checkout.
        guard builder.runnerWorkRoot.hasPrefix(builder.home + "/") else {
            throw MacOSBuilderContractFailure.invalid(
                "runner work root must live in the builder's own storage, "
                    + "outside the machine root retirement removes")
        }
    }

    var machineRoot: FilePath {
        FilePath(builder.runnerRoot).removingLastComponent()
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

/// Leading integer of a dotted Apple version string such as `27.0` or `27.1.2`.
func appleMajorVersion(of version: String) -> Int? {
    Int(version.prefix { $0.isNumber })
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
        let storageLayout: MacOSHostStorageLayout
        do {
            storageLayout = try MacOSHostStorageLayout.current()
        } catch {
            return [
                HostPrerequisite(
                    id: "macos-builder:storage-layout",
                    scope: scope,
                    description: "standard per-user macOS storage layout",
                    remediation: "restore access to the current user's Library directories"
                ) { nil }
            ]
        }

        return [
            operatingSystem(contract, scope: scope),
            xcode(contract, scope: scope),
            swiftBootstrap(contract, scope: scope),
            resources(contract, scope: scope),
            executionLease(scope: scope),
            builderLauncher(scope: scope),
            bootCoordinator(contract, scope: scope),
            buildStore(contract, scope: scope),
            persistentService(contract, storageLayout: storageLayout, scope: scope),
            containerSystem(contract, storageLayout: storageLayout, scope: scope),
            hostOnlyNetwork(contract, scope: scope),
            storageEnvironment(storageLayout, scope: scope),
        ]
    }

    private func operatingSystem(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:operating-system",
            scope: scope,
            description: "macOS \(contract.operatingSystem.majorVersion)",
            remediation:
                "install a macOS \(contract.operatingSystem.majorVersion) release; "
                + "\(MacOSBuilderContract.relativePath) selects the major version only"
        ) {
            guard
                let version = try? await context.run(
                    "/usr/bin/sw_vers", ["-productVersion"], capture: true),
                appleMajorVersion(of: version) == contract.operatingSystem.majorVersion,
                let build = try? await context.run(
                    "/usr/bin/sw_vers", ["-buildVersion"], capture: true)
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
            description: "Xcode \(contract.xcode.majorVersion)",
            remediation:
                "install an Xcode \(contract.xcode.majorVersion) release at "
                + "\(contract.xcode.developerDirectory) and select its developer directory"
        ) {
            guard
                let selected = try? await context.run(
                    "/usr/bin/xcode-select", ["--print-path"],
                    capture: true),
                selected == contract.xcode.developerDirectory,
                let output = try? await context.run(
                    "/usr/bin/xcodebuild", ["-version"], capture: true),
                let versionLine = output.split(separator: "\n").first,
                versionLine.hasPrefix("Xcode "),
                appleMajorVersion(of: String(versionLine.dropFirst("Xcode ".count)))
                    == contract.xcode.majorVersion,
                FileManager.default.fileExists(
                    atPath: URL(
                        fileURLWithPath: contract.xcode.developerDirectory
                    ).appendingPathComponent(
                        contract.xcode.testingMacroPluginRelativePath
                    ).path)
            else { return nil }
            return output.split(separator: "\n").joined(separator: " ")
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

    /// The store is shared machine state, so its access contract is checked
    /// from whichever account is about to use it rather than only by the
    /// privileged provisioning that installs it.
    private func buildStore(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:build-store",
            scope: scope,
            description: "machine-wide Collider build store",
            remediation:
                "run 'collider provision macos-builder commission'; it installs the "
                + "store the builder writes and the build-state group reads, and "
                + "resets its ownership and modes to the contract"
        ) {
            let fileManager = FileManager.default
            let store = MacOSMachineStorageLayout.buildStore
            // A host that has not migrated yet is a valid host: it runs from
            // per-user storage, exactly as one with a single account does. Only
            // an installed store carries a contract to check.
            guard MacOSMachineStorageLayout.buildStoreIsInstalled() else {
                return "per-user storage; no machine build store is installed"
            }
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: store.string),
                let owner = attributes[.ownerAccountName] as? String,
                owner == contract.builder.user,
                let group = attributes[.groupOwnerAccountName] as? String,
                group == contract.builder.buildStateGroup,
                // Setgid keeps every object the builder creates in the group the
                // interactive account reads, without that account writing any.
                attributes[.posixPermissions] as? NSNumber == 0o2750,
                // Only builder-domain commands journal. Interactive inspection
                // reads the same history without writing the log root.
                let logs = try? fileManager.attributesOfItem(
                    atPath: store.appending("logs").string),
                logs[.posixPermissions] as? NSNumber == 0o2750,
                // Signing material is the one subtree the reading group must not
                // reach, because the identity that executes is the one that signs.
                let identity = try? fileManager.attributesOfItem(
                    atPath: store.appending("state/identity").string),
                identity[.posixPermissions] as? NSNumber == 0o700
            else { return nil }
            return "\(store), written by \(owner) and read by \(group)"
        }
    }

    /// The lease is the one piece of machine state both accounts touch, so it
    /// is checked from whichever account is about to build rather than only by
    /// the privileged provisioning that installs it.
    private func executionLease(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:execution-lease",
            scope: scope,
            description: "machine-wide Collider execution lease",
            remediation:
                "run 'collider provision macos-builder commission'; it installs one "
                + "root-owned lock file that every account may lock and none may replace"
        ) {
            let fileManager = FileManager.default
            let lease = MacOSMachineStorageLayout.hostExecutionAdmission
            let contractRoot = MacOSMachineStorageLayout.contractRoot
            guard
                let leaseAttributes = try? fileManager.attributesOfItem(
                    atPath: lease.string),
                leaseAttributes[.type] as? FileAttributeType == .typeRegular,
                leaseAttributes[.ownerAccountID] as? NSNumber == 0,
                leaseAttributes[.groupOwnerAccountID] as? NSNumber == 0,
                leaseAttributes[.posixPermissions] as? NSNumber == 0o666,
                // Only root may write the containing directory, so no account
                // can replace, unlink, or shadow the inode it locks.
                let rootAttributes = try? fileManager.attributesOfItem(
                    atPath: contractRoot.string),
                rootAttributes[.ownerAccountID] as? NSNumber == 0,
                rootAttributes[.posixPermissions] as? NSNumber == 0o755
            else { return nil }
            // Mode bits state an intent; only an acquisition proves this
            // account can lock the inode, and it subsumes the read-write
            // access the open requires. A lease another invocation already
            // holds demonstrates the same thing, so contention is a pass.
            do {
                let acquired = try ColliderFileLock(
                    path: lease,
                    purpose: "machine-wide Collider execution lease",
                    waitForExistingOwner: false)
                withExtendedLifetime(acquired) {}
                return "\(lease), locked and released by this account"
            } catch RuntimeLockFailure.alreadyOwned {
                return "\(lease), held by another invocation"
            } catch {
                return nil
            }
        }
    }

    /// Whether the installed launcher still matches the checkout it came from.
    ///
    /// The launcher is root-owned provisioned state compiled from a tracked
    /// file, and only a privileged step can update it. Nothing else would
    /// notice the two diverging: the stale copy keeps working and simply
    /// refuses operations the current checkout believes it accepts, which reads
    /// as a Collider bug rather than as un-reinstalled provisioning.
    private func builderLauncher(scope: String) -> HostPrerequisite {
        let source = context.root.appending(
            "tools/macos-builder/nucleus-builder-run")
        return HostPrerequisite(
            id: "macos-builder:launcher",
            scope: scope,
            description: "installed builder launcher matches the checkout",
            remediation:
                "run 'sudo tools/macos-builder/finalize-nucleus-builder.sh' to "
                + "reinstall \(MacOSMachineStorageLayout.builderLauncher) from "
                + "\(source)"
        ) {
            let installed = MacOSMachineStorageLayout.builderLauncher
            let fileManager = FileManager.default
            guard fileManager.isExecutableFile(atPath: installed.string),
                let attributes = try? fileManager.attributesOfItem(
                    atPath: installed.string),
                attributes[.ownerAccountID] as? NSNumber == 0,
                fileManager.contentsEqual(
                    atPath: installed.string,
                    andPath: source.string)
            else { return nil }
            return "\(installed), identical to \(source)"
        }
    }

    private func bootCoordinator(
        _ contract: MacOSBuilderContract,
        scope: String
    ) -> HostPrerequisite {
        let source = context.root.appending(
            "tools/macos-builder/builder-boot-coordinator")
        let installed = FilePath(contract.builder.hostContractRoot)
            .appending("builder-boot-coordinator")
        let plist = FilePath("/Library/LaunchDaemons")
            .appending("\(contract.builder.bootCoordinatorServiceLabel).plist")
        return HostPrerequisite(
            id: "macos-builder:boot-coordinator",
            scope: scope,
            description: "boot recovery for the isolated builder services",
            remediation:
                "run 'sudo tools/macos-builder/finalize-nucleus-builder.sh' to "
                + "install the root boot coordinator"
        ) {
            let files = FileManager.default
            guard files.contentsEqual(atPath: source.string, andPath: installed.string),
                let executableAttributes = try? files.attributesOfItem(
                    atPath: installed.string),
                executableAttributes[.ownerAccountID] as? NSNumber == 0,
                executableAttributes[.groupOwnerAccountID] as? NSNumber == 0,
                executableAttributes[.posixPermissions] as? NSNumber == 0o755,
                let plistAttributes = try? files.attributesOfItem(atPath: plist.string),
                plistAttributes[.ownerAccountID] as? NSNumber == 0,
                plistAttributes[.groupOwnerAccountID] as? NSNumber == 0,
                plistAttributes[.posixPermissions] as? NSNumber == 0o644,
                let data = files.contents(atPath: plist.string),
                let service = try? PropertyListDecoder().decode(
                    BootCoordinatorServicePlist.self,
                    from: data),
                service.label == contract.builder.bootCoordinatorServiceLabel,
                let builderUID = try? await context.run(
                    "/usr/bin/id", ["-u", contract.builder.user], capture: true),
                service.programArguments == [
                    installed.string,
                    contract.builder.user,
                    builderUID.trimmingCharacters(in: .whitespacesAndNewlines),
                    contract.launchd.label,
                    FilePath(contract.builder.home)
                        .appending("Library/LaunchAgents/\(contract.launchd.label).plist").string,
                    contract.appleContainer.executable,
                    contract.builder.runnerServiceLabel,
                    FilePath(contract.builder.hostContractRoot)
                        .appending("\(contract.builder.runnerServiceLabel).plist").string,
                    contract.builder.runnerRoot,
                    contract.builder.runnerWatchdogServiceLabel,
                    FilePath(contract.builder.hostContractRoot)
                        .appending("\(contract.builder.runnerWatchdogServiceLabel).plist").string,
                ],
                service.runAtLoad,
                service.startInterval == contract.builder.bootCoordinatorIntervalSeconds,
                let launchd = try? await context.run(
                    "/bin/launchctl",
                    ["print", "system/\(contract.builder.bootCoordinatorServiceLabel)"],
                    capture: true)
            else { return nil }
            return "\(installed), \(launchd.split(separator: "\n").first ?? "loaded")"
        }
    }

    /// Whether this account owns the container service.
    ///
    /// A store host runs exactly one, in the builder's launchd session, and a
    /// Mach service in another account's session cannot be reached from here at
    /// all. Reporting that as a fault would tell every developer invocation
    /// that a healthy host is broken, so these checks state who owns the
    /// service instead of asserting against one that was never theirs.
    private func inspectsContainerService(_ contract: MacOSBuilderContract) -> Bool {
        !MacOSMachineStorageLayout.buildStoreIsInstalled()
            || NSUserName() == contract.builder.user
    }

    private func containerServiceOwnedElsewhere(
        _ contract: MacOSBuilderContract
    ) -> String {
        "owned by \(contract.builder.user); this account runs no container service"
    }

    private func persistentService(
        _ contract: MacOSBuilderContract,
        storageLayout: MacOSHostStorageLayout,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:persistent-container-service",
            scope: scope,
            description: "persistent per-user Apple container service",
            remediation:
                "stop the per-user service, then run tools/macos-builder/install-container-service.sh"
        ) {
            guard inspectsContainerService(contract) else {
                return containerServiceOwnedElsewhere(contract)
            }
            let fileManager = FileManager.default
            let starterPath = storageLayout.containerServiceStarter.string
            let plistPath = storageLayout.launchAgentPlist(
                label: contract.launchd.label
            ).string
            guard
                fileManager.isExecutableFile(
                    atPath: starterPath),
                let plistData = fileManager.contents(
                    atPath: plistPath),
                let uid = try? await context.run(
                    "/usr/bin/id", ["-u"], capture: true),
                let launchd = try? await Self.launchdServiceOutput(
                    context: context,
                    uid: uid,
                    label: contract.launchd.label),
                let serviceDetail = Self.persistentServiceDetail(
                    plistData,
                    launchdOutput: launchd,
                    starterPath: starterPath,
                    standardOutPath: storageLayout.containerServiceStandardOutput.string,
                    standardErrorPath: storageLayout.containerServiceStandardError.string,
                    contract: contract)
            else { return nil }
            return serviceDetail
        }
    }

    private func containerSystem(
        _ contract: MacOSBuilderContract,
        storageLayout: MacOSHostStorageLayout,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:apple-container",
            scope: scope,
            description:
                "Apple container \(contract.appleContainer.version) at the declared application root",
            remediation:
                "install the signed pinned package and provision the persistent per-user service"
        ) {
            guard inspectsContainerService(contract) else {
                return containerServiceOwnedElsewhere(contract)
            }
            guard
                let health = try? await context.runtime.ociRuntimeHealth(),
                let detail = Self.containerSystemDetail(
                    health,
                    expectedAppRoot: storageLayout.appleContainerApplicationRoot,
                    contract: contract)
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
                "run any Collider build or bootstrap action; Collider creates and validates this network through the Apple container Swift API"
        ) {
            guard inspectsContainerService(contract) else {
                return containerServiceOwnedElsewhere(contract)
            }
            guard
                let network = try? await context.runtime.ociRuntimeNetwork(
                    named: contract.appleContainer.network),
                let detail = Self.hostOnlyNetworkDetail(
                    network, contract: contract)
            else { return nil }
            return detail
        }
    }

    private func storageEnvironment(
        _ storageLayout: MacOSHostStorageLayout,
        scope: String
    ) -> HostPrerequisite {
        HostPrerequisite(
            id: "macos-builder:storage-environment",
            scope: scope,
            description: "standard Collider cache and SDK roots",
            remediation:
                "run the installed 'collider' command; its launcher resolves conventional per-user macOS storage"
        ) {
            guard
                context.environment["XDG_CACHE_HOME"] == nil,
                normalizedPath(
                    context.environment["NUCLEUS_NATIVE_SDK_ROOT"] ?? "")
                    == normalizedPath(
                        storageLayout.nativeSDKs.appending("linux-arm64").string),
                normalizedPath(context.environment["NUCLEUS_BUILD_ROOT"] ?? "")
                    == normalizedPath(storageLayout.hostBuildState.string),
                normalizedPath(context.environment["ANDROID_SDK_ROOT"] ?? "")
                    == normalizedPath(storageLayout.androidSDKs.string),
                normalizedPath(context.environment["ANDROID_HOME"] ?? "")
                    == normalizedPath(storageLayout.androidSDKs.string)
            else { return nil }
            return
                "build root \(storageLayout.hostBuildState), cache root \(storageLayout.cacheRoot), native SDK \(storageLayout.nativeSDKs.appending("linux-arm64"))"
        }
    }

    static func persistentServiceDetail(
        _ data: Data,
        launchdOutput: String,
        starterPath: String,
        standardOutPath: String,
        standardErrorPath: String,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            let plist = try? PropertyListDecoder().decode(
                PersistentServicePlist.self,
                from: data),
            plist.label == contract.launchd.label,
            plist.programArguments == [starterPath],
            plist.standardOutPath == standardOutPath,
            plist.standardErrorPath == standardErrorPath,
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
        return "per-user/\(plist.label)"
    }

    private static func launchdServiceOutput(
        context: WorkspaceContext,
        uid: String,
        label: String
    ) async throws -> String {
        if let output = try? await context.run(
            "/bin/launchctl",
            ["print", "gui/\(uid)/\(label)"],
            capture: true)
        {
            return output
        }
        return try await context.run(
            "/bin/launchctl",
            ["print", "user/\(uid)/\(label)"],
            capture: true)
    }

    static func containerSystemDetail(
        _ health: OCIRuntimeHealth,
        expectedAppRoot: FilePath,
        contract: MacOSBuilderContract
    ) -> String? {
        guard
            health.apiServerAppName == "container-apiserver",
            health.apiServerVersion.contains(
                "version \(contract.appleContainer.version)"),
            health.apiServerCommit == contract.appleContainer.commit,
            normalizedPath(health.appRoot.path)
                == normalizedPath(expectedAppRoot.string),
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

private struct BootCoordinatorServicePlist: Decodable {
    let label: String
    let programArguments: [String]
    let runAtLoad: Bool
    let startInterval: UInt64

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case runAtLoad = "RunAtLoad"
        case startInterval = "StartInterval"
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

private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}
