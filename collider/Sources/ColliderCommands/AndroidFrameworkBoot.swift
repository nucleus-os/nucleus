import ColliderCore
import ColliderRuntime
import Foundation
import NucleusAndroidContainerContract
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct AndroidFrameworkBootCommand {
    let context: WorkspaceContext
    let timeoutSeconds: UInt32

    func run() throws {
        guard getuid() != 0 else {
            throw WorkspaceFailure.message(
                "run Collider as the workspace user, not as root")
        }
        let layout = AndroidFrameworkBootLayout(context: context)
        let provenance = try loadAndValidateImages(layout: layout)
        let host = try validateHost(layout: layout)

        try context.run("sudo", ["--validate"], terminal: true)
        var session = AndroidFrameworkBootSession(
            context: context,
            layout: layout,
            host: host)
        do {
            try session.prepare()
            try session.mountImages(provenance.images)
            try session.mountApexes()
            try session.createBinderDevices()
            try session.writeConfiguration()
            try session.startBPFDelegationBroker()
            try session.start()
            try session.waitForBPFDelegation()
            try session.waitForFramework(timeoutSeconds: timeoutSeconds)
        } catch {
            session.cleanup()
            session.printFailureDiagnostics()
            throw error
        }
        session.cleanup()
        print(
            "Contained Android framework boot completed; diagnostics: "
                + layout.diagnostics.path)
    }

    private func loadAndValidateImages(
        layout: AndroidFrameworkBootLayout
    ) throws -> AndroidImageProvenance {
        let provenance = try JSONDecoder().decode(
            AndroidImageProvenance.self,
            from: Data(contentsOf: layout.provenance))
        let expected = Set([
            "system.img",
            "system_ext.img",
            "product.img",
            "vendor.img",
            "vbmeta.img",
            "vbmeta_system.img",
        ])
        let patchedRepositories = Set(
            provenance.sourceForwardPatches.map(\.repositoryPath))
        guard provenance.status == "signed",
            provenance.product == "nucleus_x86_64",
            patchedRepositories.isSuperset(
                of: [
                    "frameworks/native",
                    "packages/modules/Connectivity",
                    "packages/modules/UprobeStats",
                    "system/apex",
                    "system/bpf",
                    "system/core",
                    "system/vold",
                ]),
            Set(provenance.images.map(\.name)) == expected,
            provenance.images.allSatisfy({
                $0.storageFormat == "raw"
            })
        else {
            throw WorkspaceFailure.message(
                "signed Android image provenance does not satisfy the "
                    + "contained framework-boot contract")
        }
        for image in provenance.images {
            let path = layout.images.appendingPathComponent(image.name)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: path.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value
            guard size == image.size else {
                throw WorkspaceFailure.message(
                    "\(image.name) size does not match image provenance")
            }
            let digest = try ArtifactHasher.digest(
                file: FilePath(path.path)
            ).sha256Hex
            guard digest == image.sha256 else {
                throw WorkspaceFailure.message(
                    "\(image.name) digest does not match image provenance")
            }
        }
        let avbTool = layout.hostTools.appendingPathComponent("avbtool")
        let releaseKey = layout.signingIdentity.appendingPathComponent(
            "releasekey.pem")
        try context.run(
            avbTool.path,
            [
                "verify_image",
                "--image",
                layout.images.appendingPathComponent("vbmeta.img").path,
                "--key",
                releaseKey.path,
                "--follow_chain_partitions",
            ],
            capture: true)
        return provenance
    }

    private func validateHost(
        layout: AndroidFrameworkBootLayout
    ) throws -> AndroidFrameworkBootHost {
        var failures: [String] = []
        for tool in [
            "sudo",
            "mount",
            "umount",
            "lxc-start",
            "lxc-stop",
            "lxc-attach",
            "newuidmap",
            "newgidmap",
            "systemd-run",
            "aa-enabled",
            "modprobe",
            "modinfo",
            "journalctl",
        ] where resolveExecutable(tool, environment: context.environment) == nil {
            failures.append("missing host tool: \(tool)")
        }
        let mountedFilesystems =
            (try? String(
                contentsOfFile: "/proc/filesystems",
                encoding: .utf8)) ?? ""
        for requirement in [
            (
                fileSystem: "binder",
                module: "binder_linux",
                failure:
                    "kernel neither exposes binderfs nor provides "
                    + "the binder_linux module"
            ),
            (
                fileSystem: "erofs",
                module: "erofs",
                failure:
                    "kernel neither exposes EROFS nor provides "
                    + "the erofs module"
            ),
            (
                fileSystem: "bpf",
                module: "",
                failure:
                    "kernel does not expose the BPF filesystem required "
                    + "for per-instance BPF delegation"
            ),
        ] {
            if !mountedFilesystems.split(whereSeparator: \.isNewline)
                .contains(where: {
                    $0.split(whereSeparator: \.isWhitespace)
                        .last == Substring(requirement.fileSystem)
                })
            {
                do {
                    guard !requirement.module.isEmpty else {
                        failures.append(requirement.failure)
                        continue
                    }
                    _ = try context.run(
                        "modinfo",
                        [requirement.module],
                        capture: true)
                } catch {
                    failures.append(requirement.failure)
                }
            }
        }
        let controllers =
            (try? String(
                contentsOfFile: "/sys/fs/cgroup/cgroup.controllers",
                encoding: .utf8)) ?? ""
        if controllers.isEmpty {
            failures.append("unified cgroup v2 is not mounted")
        }
        if resolveExecutable(
            "aa-enabled",
            environment: context.environment) != nil
        {
            do {
                try context.run("aa-enabled", ["--quiet"])
            } catch {
                failures.append("AppArmor is not enabled")
            }
        }
        let mappingOwner = "root"
        let uidRange = subordinateRange(
            user: mappingOwner,
            contents: (try? String(
                contentsOfFile: "/etc/subuid",
                encoding: .utf8)) ?? "")
        let gidRange = subordinateRange(
            user: mappingOwner,
            contents: (try? String(
                contentsOfFile: "/etc/subgid",
                encoding: .utf8)) ?? "")
        if uidRange == nil {
            failures.append(
                "root has no subordinate UID range for the LXC manager")
        }
        if gidRange == nil {
            failures.append(
                "root has no subordinate GID range for the LXC manager")
        }
        for path in [
            URL(fileURLWithPath: "/usr/bin/env"),
            layout.seccompProfile,
            layout.provenance,
            layout.hostTools.appendingPathComponent("avbtool"),
            layout.hostTools.appendingPathComponent("deapexer"),
            layout.signingIdentity.appendingPathComponent("releasekey.pem"),
        ] where !FileManager.default.fileExists(atPath: path.path) {
            failures.append("missing framework-boot input: \(path.path)")
        }
        guard failures.isEmpty,
            let uidRange,
            let gidRange
        else {
            throw WorkspaceFailure.message(
                "contained Android framework boot prerequisites failed:\n"
                    + failures.map { "  - \($0)" }.joined(separator: "\n"))
        }
        return AndroidFrameworkBootHost(
            userID: getuid(),
            groupID: getgid(),
            subordinateUID: uidRange.start,
            subordinateGID: gidRange.start,
            subordinateUIDCount: uidRange.count,
            subordinateGIDCount: gidRange.count)
    }
}

private struct AndroidFrameworkBootSession {
    let context: WorkspaceContext
    let layout: AndroidFrameworkBootLayout
    let host: AndroidFrameworkBootHost
    var mounted: [URL] = []
    var binderMounted = false
    var containerStarted = false
    var command: WorkspaceManagedCommand?
    var bpfBrokerCommand: WorkspaceManagedCommand?
    var logcatCommand: WorkspaceManagedCommand?
    var kernelLog: PseudoTerminalLog?
    var binderDevices: [AndroidContainerDevice] = []
    let startedAt = Date()

    mutating func prepare() throws {
        for module in ["binder_linux", "erofs"] {
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "modprobe",
                    module,
                ])
        }
        try FileManager.default.createDirectory(
            at: layout.diagnostics,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: layout.diagnosticTombstones,
            withIntermediateDirectories: true)
        for log in [
            layout.lxcLog,
            layout.androidLog,
            layout.hostAuditLog,
        ] {
            try Data().write(to: log, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: log.path)
        }
        kernelLog = try PseudoTerminalLog(
            output: FilePath(layout.androidKernelLog.path))
        guard let kernelLog else {
            throw WorkspaceFailure.message(
                "failed to create the Android kernel-log transport")
        }
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(host.subordinateUID):\(host.subordinateGID)",
                kernelLog.slavePath,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chmod",
                "0622",
                kernelLog.slavePath,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--mode=0710",
                layout.instance.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--owner=root",
                "--group=root",
                "--mode=0711",
                layout.bpfBrokerDirectory.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--owner=root",
                "--group=root",
                "--mode=0555",
                "/dev/null",
                layout.bpfHookExecutable.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--bind",
                try currentColliderExecutable(),
                layout.bpfHookExecutable.path,
            ])
        mounted.append(layout.bpfHookExecutable)
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,bind,ro,nosuid,nodev,exec",
                layout.bpfHookExecutable.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--owner=root",
                "--group=root",
                "--mode=0755",
                layout.swiftRuntime.path,
            ])
        let swiftRuntime =
            try currentSwiftRuntime()
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--bind",
                swiftRuntime.libraryRoot.path,
                layout.swiftRuntime.path,
            ])
        mounted.append(layout.swiftRuntime)
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,bind,ro,nosuid,nodev,exec",
                layout.swiftRuntime.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(host.userID):\(host.subordinateGID)",
                layout.instance.path,
            ])
        for directory in [
            layout.rootFileSystem,
            layout.binder,
            layout.containerTombstones,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        }
        let mappedSystemUser = UInt64(host.subordinateUID) + 1_000
        let mappedSystemGroup = UInt64(host.subordinateGID) + 1_000
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(mappedSystemUser):\(mappedSystemGroup)",
                layout.containerTombstones.path,
            ])
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chmod",
                "0775",
                layout.containerTombstones.path,
            ])
    }

    mutating func mountImages(
        _ images: [AndroidImageProvenance.Image]
    ) throws {
        let byName = Dictionary(
            uniqueKeysWithValues: images.map { ($0.name, $0) })
        for (name, mountPoint) in [
            ("system.img", layout.rootFileSystem),
            (
                "system_ext.img",
                layout.rootFileSystem.appendingPathComponent("system_ext")
            ),
            (
                "product.img",
                layout.rootFileSystem.appendingPathComponent("product")
            ),
            (
                "vendor.img",
                layout.rootFileSystem.appendingPathComponent("vendor")
            ),
        ] {
            guard byName[name] != nil else {
                throw WorkspaceFailure.message(
                    "signed image set is missing \(name)")
            }
            if name != "system.img",
                !FileManager.default.fileExists(atPath: mountPoint.path)
            {
                throw WorkspaceFailure.message(
                    "system-as-root image is missing mount point "
                        + mountPoint.path)
            }
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--options=ro,nosuid,nodev,loop",
                    layout.images.appendingPathComponent(name).path,
                    mountPoint.path,
                ])
            mounted.append(mountPoint)
            if name == "system.img" {
                let initPath = layout.rootFileSystem.appendingPathComponent(
                    "system/bin/init")
                guard
                    FileManager.default.isExecutableFile(
                        atPath: initPath.path)
                else {
                    throw WorkspaceFailure.message(
                        "system-as-root image does not provide "
                            + "/system/bin/init")
                }
            }
        }
    }

    mutating func createBinderDevices() throws {
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--types=binder",
                "binder",
                layout.binder.path,
            ])
        binderMounted = true
        let control = layout.binder.appendingPathComponent(
            "binder-control")
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(host.userID):\(host.groupID)",
                control.path,
            ])
        defer {
            _ = try? context.run(
                "sudo",
                [
                    "--non-interactive",
                    "chown",
                    "0:0",
                    control.path,
                ])
        }
        for name in ["binder", "hwbinder", "vndbinder"] {
            let number = try BinderFS.addDevice(
                control: FilePath(control.path),
                name: name)
            let device = layout.binder.appendingPathComponent(name)
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "chown",
                    "\(host.subordinateUID):\(host.subordinateGID)",
                    device.path,
                ])
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "chmod",
                    "0666",
                    device.path,
                ])
            binderDevices.append(
                AndroidContainerDevice(
                    name: name,
                    source: device.path,
                    major: number.major,
                    minor: number.minor))
        }
    }

    mutating func mountApexes() throws {
        let apexRoot = layout.rootFileSystem.appendingPathComponent(
            "apex",
            isDirectory: true)
        let apexes = try discoverApexes()
        guard !apexes.isEmpty else {
            throw WorkspaceFailure.message(
                "signed Android image set contains no APEX packages")
        }

        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--types=tmpfs",
                "--options=rw,nosuid,noexec,mode=0755",
                "tmpfs",
                apexRoot.path,
            ])
        mounted.append(apexRoot)

        let colliderExecutable = try currentColliderExecutable()
        for apex in apexes {
            let versionName = "\(apex.name)@\(apex.version)"
            let versionMount = apexRoot.appendingPathComponent(
                versionName,
                isDirectory: true)
            let activeMount = apexRoot.appendingPathComponent(
                apex.name,
                isDirectory: true)
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "install",
                    "--directory",
                    "--mode=0755",
                    versionMount.path,
                    activeMount.path,
                ])
            let mountRequest = try AndroidApexMountRequest(
                rootFileSystem: layout.rootFileSystem.path,
                source: apex.containerPath,
                target: "/apex/\(versionName)",
                payloadFileSystem: apex.payloadFileSystem,
                payloadOffset: apex.payload.offset)
            let mountInvocation = AndroidApexMountInvocation(
                colliderExecutable: colliderExecutable,
                request: mountRequest)
            try context.run(
                mountInvocation.executable,
                mountInvocation.arguments)
            mounted.append(versionMount)
            let mountedManifest = versionMount.appendingPathComponent(
                "apex_manifest.pb")
            guard
                FileManager.default.fileExists(
                    atPath: mountedManifest.path)
            else {
                throw WorkspaceFailure.message(
                    "mounted APEX \(apex.name) has no apex_manifest.pb")
            }
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--bind",
                    versionMount.path,
                    activeMount.path,
                ])
            mounted.append(activeMount)
            try context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--options=remount,bind,ro,nosuid,nodev",
                    activeMount.path,
                ])
        }
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,rw,nosuid,nodev,noexec",
                apexRoot.path,
            ])
    }

    private func discoverApexes() throws -> [AndroidFrameworkApex] {
        let deapexer = layout.hostTools.appendingPathComponent("deapexer")
        var apexes: [AndroidFrameworkApex] = []
        var names = Set<String>()
        for partition in [
            (
                host: layout.rootFileSystem.appendingPathComponent(
                    "system/apex",
                    isDirectory: true),
                container: "/system/apex"
            ),
            (
                host: layout.rootFileSystem.appendingPathComponent(
                    "system_ext/apex",
                    isDirectory: true),
                container: "/system_ext/apex"
            ),
            (
                host: layout.rootFileSystem.appendingPathComponent(
                    "product/apex",
                    isDirectory: true),
                container: "/product/apex"
            ),
            (
                host: layout.rootFileSystem.appendingPathComponent(
                    "vendor/apex",
                    isDirectory: true),
                container: "/vendor/apex"
            ),
        ] {
            guard
                FileManager.default.fileExists(
                    atPath: partition.host.path)
            else {
                continue
            }
            let archives = try FileManager.default.contentsOfDirectory(
                at: partition.host,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for archive in archives {
                if archive.pathExtension == "capex" {
                    throw WorkspaceFailure.message(
                        "Nucleus container image contains compressed APEX: "
                            + archive.path)
                }
                guard archive.pathExtension == "apex" else {
                    continue
                }
                let payload = try AndroidApexArchive.payload(in: archive)
                let payloadType = try context.run(
                    deapexer.path,
                    ["info", "--print-payload-type", archive.path],
                    capture: true)
                guard
                    let payloadFileSystem =
                        AndroidApexPayloadFileSystem(rawValue: payloadType)
                else {
                    throw WorkspaceFailure.message(
                        "Nucleus container APEX payload filesystem is "
                            + "unsupported (\(payloadType)): \(archive.path)")
                }
                let manifestOutput = try context.run(
                    deapexer.path,
                    ["info", archive.path],
                    capture: true)
                let manifest = try JSONDecoder().decode(
                    AndroidFrameworkApexManifest.self,
                    from: Data(manifestOutput.utf8))
                guard isValidApexName(manifest.name),
                    let version = Int32(manifest.version),
                    version > 0,
                    names.insert(manifest.name).inserted
                else {
                    throw WorkspaceFailure.message(
                        "Nucleus container APEX manifest is invalid or "
                            + "duplicated: \(archive.path)")
                }
                apexes.append(
                    AndroidFrameworkApex(
                        name: manifest.name,
                        version: String(version),
                        containerPath:
                            partition.container + "/" + archive.lastPathComponent,
                        payloadFileSystem: payloadFileSystem,
                        payload: payload))
            }
        }
        return apexes.sorted { $0.name < $1.name }
    }

    mutating func writeConfiguration() throws {
        guard let kernelLog else {
            throw WorkspaceFailure.message(
                "Android kernel-log transport is not prepared")
        }
        let configuration = AndroidContainerConfiguration(
            name: layout.name,
            rootFileSystem: layout.rootFileSystem.path,
            seccompProfile: layout.seccompProfile.path,
            kernelLogDevice: kernelLog.slavePath,
            tombstones: layout.containerTombstones.path,
            hostUIDStart: host.subordinateUID,
            hostGIDStart: host.subordinateGID,
            hostUIDCount: host.subordinateUIDCount,
            hostGIDCount: host.subordinateGIDCount,
            binderDevices: binderDevices,
            mountHook: AndroidContainerMountHook(
                executable: "/usr/bin/env",
                arguments: [
                    "LD_LIBRARY_PATH="
                        + layout.swiftRuntime
                        .appendingPathComponent(
                            swiftRuntimeLoaderSearchPath,
                            isDirectory: true
                        )
                        .path,
                    layout.bpfHookExecutable.path,
                    androidBPFMountCommandName,
                    "--socket",
                    layout.bpfBrokerSocket.path,
                    "--root-file-system",
                    layout.rootFileSystem.path,
                    "--container",
                    layout.name,
                ]))
        try Data(
            try configuration.lxcConfiguration().utf8
        ).write(to: layout.configuration, options: .atomic)
    }

    mutating func startBPFDelegationBroker() throws {
        let invocation = AndroidBPFBrokerInvocation(
            colliderExecutable: try currentColliderExecutable(),
            socket: layout.bpfBrokerSocket.path,
            peerUID: host.subordinateUID)
        bpfBrokerCommand = context.start(
            invocation.executable,
            invocation.arguments)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(
                atPath: layout.bpfBrokerSocket.path)
            {
                return
            }
            if bpfBrokerCommand?.isRunning == false {
                let status = try bpfBrokerCommand?.wait().status ?? -1
                throw WorkspaceFailure.message(
                    "Android BPF delegation broker exited before becoming "
                        + "ready (status \(status))")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw WorkspaceFailure.message(
            "Android BPF delegation broker did not become ready")
    }

    mutating func start() throws {
        containerStarted = true
        let invocation = AndroidLXCStartInvocation(
            name: layout.name,
            configuration: layout.configuration.path,
            logFile: layout.lxcLog.path)
        command = context.start(
            invocation.executable,
            invocation.arguments)
    }

    mutating func waitForBPFDelegation() throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try kernelLog?.checkHealth()
            if bpfBrokerCommand?.isRunning == false {
                let status = try bpfBrokerCommand?.wait().status ?? -1
                guard status == 0 else {
                    throw WorkspaceFailure.message(
                        "Android BPF delegation broker failed "
                            + "(status \(status)); diagnostics: "
                            + layout.diagnostics.path)
                }
                bpfBrokerCommand = nil
                return
            }
            if command?.isRunning == false {
                let status = try command?.wait().status ?? -1
                throw WorkspaceFailure.message(
                    "Android container exited before mounting its delegated "
                        + "BPF filesystem (lxc-start status \(status)); "
                        + "diagnostics: \(layout.diagnostics.path)")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw WorkspaceFailure.message(
            "Android container did not mount its delegated BPF filesystem; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    mutating func waitForFramework(timeoutSeconds: UInt32) throws {
        let deadline = Date().addingTimeInterval(
            TimeInterval(timeoutSeconds))
        while Date() < deadline {
            try kernelLog?.checkHealth()
            if command?.isRunning == false {
                let status = try command?.wait().status ?? -1
                throw WorkspaceFailure.message(
                    "Android container exited before framework boot "
                        + "(lxc-start status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try startLogcatIfReady()
            if let property = try? containerProperty("sys.boot_completed"),
                property == "1"
            {
                try validateLogcat()
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw WorkspaceFailure.message(
            "Android framework did not publish sys.boot_completed=1; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private mutating func startLogcatIfReady() throws {
        if logcatCommand != nil {
            try validateLogcat()
            return
        }
        guard let state = try? containerProperty("init.svc.logd"),
            state == "running"
        else {
            return
        }
        let invocation = AndroidLogcatInvocation(
            name: layout.name,
            sinceEpochSecond:
                max(0, Int64(startedAt.timeIntervalSince1970) - 1))
        logcatCommand = context.start(
            invocation.executable,
            invocation.arguments,
            output: .file(FilePath(layout.androidLog.path)))
    }

    private func validateLogcat() throws {
        guard let logcatCommand,
            !logcatCommand.isRunning
        else {
            return
        }
        let status = try logcatCommand.wait().status
        throw WorkspaceFailure.message(
            "Android logcat collector exited unexpectedly "
                + "(status \(status)); diagnostics: "
                + layout.diagnostics.path)
    }

    private func containerProperty(_ name: String) throws -> String {
        try context.run(
            "sudo",
            [
                "--non-interactive",
                "lxc-attach",
                "--name",
                layout.name,
                "--",
                "/system/bin/getprop",
                name,
            ],
            capture: true)
    }

    mutating func cleanup() {
        if containerStarted {
            _ = try? context.run(
                "sudo",
                [
                    "--non-interactive",
                    "lxc-stop",
                    "--kill",
                    "--name",
                    layout.name,
                ])
            command?.cancel()
            _ = try? command?.wait()
            containerStarted = false
        }
        if logcatCommand?.isRunning == true {
            logcatCommand?.cancel()
        }
        _ = try? logcatCommand?.wait()
        logcatCommand = nil
        bpfBrokerCommand?.cancel()
        _ = try? bpfBrokerCommand?.wait()
        bpfBrokerCommand = nil
        persistTombstones()
        captureHostAudit()
        kernelLog?.stop()
        if let kernelLog {
            do {
                try kernelLog.checkHealth()
            } catch {
                try? Data(
                    "\(error)\n".utf8
                ).write(to: layout.collectorErrors, options: .atomic)
            }
        }
        kernelLog = nil
        for mountPoint in mounted.reversed() {
            _ = try? context.run(
                "sudo",
                [
                    "--non-interactive",
                    "umount",
                    mountPoint.path,
                ])
        }
        mounted.removeAll()
        if binderMounted {
            _ = try? context.run(
                "sudo",
                [
                    "--non-interactive",
                    "umount",
                    layout.binder.path,
                ])
            binderMounted = false
        }
        _ = try? context.run(
            "sudo",
            [
                "--non-interactive",
                "rm",
                "--recursive",
                "--force",
                "--one-file-system",
                layout.instance.path,
            ])
    }

    func printFailureDiagnostics() {
        writeStandardError(
            "Android framework boot diagnostics: "
                + layout.diagnostics.path + "\n")
        for log in [
            layout.androidKernelLog,
            layout.androidLog,
            layout.lxcLog,
            layout.hostAuditLog,
            layout.collectorErrors,
        ] {
            guard FileManager.default.fileExists(atPath: log.path),
                let tail = try? context.run(
                    "tail",
                    ["--lines=80", log.path],
                    capture: true),
                !tail.isEmpty
            else {
                continue
            }
            writeStandardError(
                "\n--- \(log.lastPathComponent) ---\n\(tail)\n")
        }
    }

    private func captureHostAudit() {
        let since = max(
            0,
            Int64(startedAt.timeIntervalSince1970) - 1)
        let collector = context.start(
            "sudo",
            [
                "--non-interactive",
                "journalctl",
                "--dmesg",
                "--no-pager",
                "--output=short-precise",
                "--since=@\(since)",
                "--grep",
                "\(layout.name)|nucleus_container|apparmor=.*lxc",
            ],
            output: .file(FilePath(layout.hostAuditLog.path)))
        _ = try? collector.wait()
    }

    private func persistTombstones() {
        guard
            FileManager.default.fileExists(
                atPath: layout.containerTombstones.path)
        else {
            return
        }
        _ = try? context.run(
            "sudo",
            [
                "--non-interactive",
                "cp",
                "--archive",
                layout.containerTombstones.path + "/.",
                layout.diagnosticTombstones.path,
            ])
        _ = try? context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "--recursive",
                "\(host.userID):\(host.groupID)",
                layout.diagnosticTombstones.path,
            ])
    }
}

private struct AndroidFrameworkBootLayout {
    let name: String
    let runtime: URL
    let instance: URL
    let rootFileSystem: URL
    let binder: URL
    let bpfBrokerDirectory: URL
    let bpfBrokerSocket: URL
    let bpfHookExecutable: URL
    let swiftRuntime: URL
    let diagnostics: URL
    let configuration: URL
    let lxcLog: URL
    let androidKernelLog: URL
    let androidLog: URL
    let hostAuditLog: URL
    let collectorErrors: URL
    let containerTombstones: URL
    let diagnosticTombstones: URL
    let images: URL
    let provenance: URL
    let signingIdentity: URL
    let hostTools: URL
    let seccompProfile: URL

    init(context: WorkspaceContext) {
        name = "nucleus-framework-\(ProcessInfo.processInfo.processIdentifier)"
        runtime = URL(
            fileURLWithPath: "/run/nucleus/android",
            isDirectory: true)
        instance = runtime.appendingPathComponent(name, isDirectory: true)
        rootFileSystem = instance.appendingPathComponent(
            "rootfs",
            isDirectory: true)
        binder = instance.appendingPathComponent(
            "binder",
            isDirectory: true)
        bpfBrokerDirectory = instance.appendingPathComponent(
            "bpf-broker",
            isDirectory: true)
        bpfBrokerSocket = bpfBrokerDirectory.appendingPathComponent(
            "broker.sock")
        bpfHookExecutable = bpfBrokerDirectory.appendingPathComponent(
            "collider")
        swiftRuntime = instance.appendingPathComponent(
            "swift-runtime",
            isDirectory: true)
        containerTombstones = instance.appendingPathComponent(
            "tombstones",
            isDirectory: true)
        let runDirectory =
            context.environment["NUCLEUS_RUN_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? context.root.appendingPathComponent(
                ".nucleus/android-framework-boot",
                isDirectory: true)
        diagnostics = runDirectory.appendingPathComponent(
            "android-framework-boot",
            isDirectory: true)
        configuration = diagnostics.appendingPathComponent("lxc.conf")
        lxcLog = diagnostics.appendingPathComponent("lxc.log")
        androidKernelLog = diagnostics.appendingPathComponent(
            "android-kmsg.log")
        androidLog = diagnostics.appendingPathComponent(
            "android-logcat.log")
        hostAuditLog = diagnostics.appendingPathComponent(
            "host-audit.log")
        collectorErrors = diagnostics.appendingPathComponent(
            "collector-errors.log")
        diagnosticTombstones = diagnostics.appendingPathComponent(
            "tombstones",
            isDirectory: true)
        let android = context.root.appendingPathComponent(
            "android-runtime",
            isDirectory: true)
        images = android.appendingPathComponent(
            ".aosp-build/images",
            isDirectory: true)
        provenance = android.appendingPathComponent(
            ".aosp-build/signed/image-provenance.json")
        signingIdentity = android.appendingPathComponent(
            ".aosp-signing/local-development",
            isDirectory: true)
        hostTools = android.appendingPathComponent(
            ".aosp-build/out/host/linux-x86/bin",
            isDirectory: true)
        seccompProfile = android.appendingPathComponent(
            "container/nucleus-android.seccomp")
    }
}

struct SwiftRuntime: Equatable {
    let libraryRoot: URL
    let loaderSearchDirectory: URL
}

private let swiftRuntimeLoaderSearchPath = "swift/linux"

func currentSwiftRuntime() throws -> SwiftRuntime {
    #if os(Linux)
    let library = URL(
        fileURLWithPath: try LoadedLibrary.path(
            containingSymbol: "swift_retain"))
    let loaderSearchDirectory = library.deletingLastPathComponent()
    let swiftDirectory = loaderSearchDirectory.deletingLastPathComponent()
    let libraryRoot = swiftDirectory.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard library.lastPathComponent == "libswiftCore.so",
        loaderSearchDirectory.lastPathComponent == "linux",
        swiftDirectory.lastPathComponent == "swift",
        FileManager.default.fileExists(
            atPath: library.path),
        FileManager.default.fileExists(
            atPath: libraryRoot.path,
            isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        throw WorkspaceFailure.message(
            "the dynamic loader returned an invalid Swift runtime path: "
                + library.path)
    }
    return SwiftRuntime(
        libraryRoot: libraryRoot,
        loaderSearchDirectory: loaderSearchDirectory)
    #else
    throw WorkspaceFailure.message(
        "cannot resolve the Swift runtime used by Collider")
    #endif
}

private struct AndroidFrameworkBootHost {
    let userID: uid_t
    let groupID: gid_t
    let subordinateUID: UInt32
    let subordinateGID: UInt32
    let subordinateUIDCount: UInt32
    let subordinateGIDCount: UInt32
}

struct AndroidLXCStartInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        name: String,
        configuration: String,
        logFile: String
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            "systemd-run",
            "--scope",
            "--quiet",
            "--collect",
            "--unit",
            name,
            "--property",
            "Delegate=yes",
            "--",
            "lxc-start",
            "--foreground",
            "--name",
            name,
            "--rcfile",
            configuration,
            "--logfile",
            logFile,
            "--logpriority",
            "TRACE",
        ]
    }
}

struct AndroidLogcatInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(name: String, sinceEpochSecond: Int64) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            "lxc-attach",
            "--name",
            name,
            "--",
            "/system/bin/logcat",
            "-b",
            "all",
            "-D",
            "-v",
            "threadtime,year,usec,uid,descriptive",
            "-T",
            "\(sinceEpochSecond).000",
        ]
    }
}

private struct AndroidImageProvenance: Decodable {
    struct Image: Decodable {
        let name: String
        let size: UInt64
        let storageFormat: String
        let sha256: String
    }

    struct ForwardPatch: Decodable {
        let repositoryPath: String
    }

    let status: String
    let product: String
    let sourceForwardPatches: [ForwardPatch]
    let images: [Image]
}

private struct AndroidFrameworkApex {
    let name: String
    let version: String
    let containerPath: String
    let payloadFileSystem: AndroidApexPayloadFileSystem
    let payload: AndroidApexPayload
}

private struct AndroidFrameworkApexManifest: Decodable {
    let name: String
    let version: String
}

private func isValidApexName(_ value: String) -> Bool {
    guard let first = value.first,
        first.isASCII,
        first.isLetter
    else {
        return false
    }
    return value.allSatisfy {
        $0.isASCII
            && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_")
    }
}

private func resolveExecutable(
    _ name: String,
    environment: [String: String]
) -> URL? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin")
        .split(separator: ":")
    {
        let candidate = URL(fileURLWithPath: String(directory))
            .appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func subordinateRange(
    user: String,
    contents: String
) -> (start: UInt32, count: UInt32)? {
    var selected: (start: UInt32, count: UInt32)?
    for line in contents.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
            fields[0] == Substring(user),
            let start = UInt32(fields[1]),
            let count = UInt32(fields[2]),
            count > 0,
            UInt64(start) + UInt64(count)
                <= UInt64(UInt32.max) + 1
        else {
            continue
        }
        if selected == nil || count > selected!.count {
            selected = (start, count)
        }
    }
    return selected
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

extension ArtifactDigest {
    fileprivate var sha256Hex: String {
        String(description.dropFirst("sha256:".count))
    }
}
