import ColliderCore
import ColliderRuntime
import Foundation
import NucleusAndroidContainerContract
import NucleusSessionProtocol
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct AndroidFrameworkBootCommand {
    let context: WorkspaceContext
    let timeoutSeconds: UInt32

    func run() async throws {
        guard getuid() != 0 else {
            throw WorkspaceFailure.message(
                "run Collider as the workspace user, not as root")
        }
        try await ComponentRegistry(context: context).buildAndroidRuntimeHost()
        let installation = try await RuntimeInstaller(context: context).install(
            .session,
            prefix: context.root.appendingPathComponent(".install"))
        let layout = AndroidFrameworkBootLayout(context: context)
        let provenance = try await loadAndValidateImages(layout: layout)
        let host = try await validateHost(layout: layout)
        try requireFreeSeat()
        let compositorRuntime = try createCompositorRuntime()
        defer {
            try? FileManager.default.removeItem(
                at: compositorRuntime.directory)
        }
        try FileManager.default.createDirectory(
            at: layout.diagnostics,
            withIntermediateDirectories: true)

        try await context.run("sudo", ["--validate"], terminal: true)
        let frameworkSession = AndroidFrameworkBootSession(
            context: context,
            layout: layout,
            host: host)
        let statusFile = layout.diagnostics.appendingPathComponent(
            "session-status.bin")
        var environment = context.environment
        environment["XDG_RUNTIME_DIR"] = compositorRuntime.parent.path
        environment["NUCLEUS_SESSION_ID"] = compositorRuntime.identifier
        environment["NUCLEUS_SESSION_RUNTIME_DIR"] =
            compositorRuntime.directory.path
        environment["NUCLEUS_EPHEMERAL_CONFIG"] = "1"
        environment["NUCLEUS_RUN_LOG"] =
            layout.diagnostics.appendingPathComponent("session.log").path
        do {
            try await context.withRunningCommand(
                installation.session.path,
                [
                    "--status-file", statusFile.path,
                    "--configuration", try SessionConfiguration().hexEncoded,
                    "--", installation.compositor.path,
                ],
                environmentOverrides: environment
            ) { compositorSession in
                try await compositorSession.waitUntilReady()
                try await waitForSessionReadiness(
                    compositorSession,
                    statusFile: statusFile)
                try await frameworkSession.prepare()
                try await frameworkSession.mountImages(provenance.images)
                try await frameworkSession.mountApexes()
                try await frameworkSession.createBinderDevices()
                try await frameworkSession.writeConfiguration()
                try await frameworkSession.runProcesses(
                    timeoutSeconds: timeoutSeconds,
                    waylandRuntimeDirectory: compositorRuntime.directory,
                    waylandSocket: "wayland-0")
            }
        } catch {
            await Task {
                await frameworkSession.cleanup()
                await frameworkSession.printFailureDiagnostics()
            }.value
            throw error
        }
        await Task {
            await frameworkSession.cleanup()
        }.value
        print(
            "Contained Android framework boot completed; diagnostics: "
                + layout.diagnostics.path)
    }

    private func requireFreeSeat() throws {
        guard context.environment["WAYLAND_DISPLAY"] == nil,
              context.environment["DISPLAY"] == nil
        else {
            throw WorkspaceFailure.message(
                "cannot launch Android framework presentation inside an "
                    + "existing Wayland/X11 session; switch to a free virtual terminal")
        }
    }

    private func createCompositorRuntime() throws -> (
        identifier: String,
        parent: URL,
        directory: URL
    ) {
        let parent = URL(
            fileURLWithPath:
                context.environment["XDG_RUNTIME_DIR"]
                ?? "/run/user/\(getuid())",
            isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard parent.path != "/",
              FileManager.default.fileExists(
                atPath: parent.path,
                isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceFailure.message(
                "the login runtime directory does not exist: \(parent.path)")
        }
        let identifier =
            "android-framework-\(UUID().uuidString.lowercased())"
        let directory = parent.appendingPathComponent(
            "nucleus-\(identifier)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return (identifier, parent, directory)
    }

    private func waitForSessionReadiness(
        _ session: RunningCommand,
        statusFile: URL
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: statusFile),
               let message = SessionReadinessMessage(encoded: Array(data))
            {
                if message.role == .shell,
                   message.milestone == .shellReady {
                    return
                }
                if message.milestone == .failed {
                    let reason = SessionFailureReason(rawValue: message.detail)
                    throw WorkspaceFailure.message(
                        "Nucleus session startup failed: "
                            + (reason.map(String.init(describing:))
                                ?? "reason \(message.detail)"))
                }
            }
            guard await session.isRunning else {
                throw WorkspaceFailure.message(
                    "Nucleus session exited before Android startup "
                        + "(status \(await session.terminationStatus ?? -1))")
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        throw WorkspaceFailure.message(
            "Nucleus session did not become ready before the startup deadline")
    }

    private func loadAndValidateImages(
        layout: AndroidFrameworkBootLayout
    ) async throws -> AndroidImageProvenance {
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
                    "device/generic/goldfish",
                    "external/mesa3d",
                    "frameworks/base",
                    "frameworks/native",
                    "hardware/interfaces",
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
        try await context.run(
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
    ) async throws -> AndroidFrameworkBootHost {
        var failures: [String] = []
        if !FileManager.default.isExecutableFile(
            atPath: layout.gfxstreamBrokerExecutable.path)
        {
            failures.append(
                "missing Android gfxstream broker: "
                    + layout.gfxstreamBrokerExecutable.path)
        }
        if !FileManager.default.isExecutableFile(
            atPath: layout.displayHostExecutable.path)
        {
            failures.append(
                "missing Android display host: "
                    + layout.displayHostExecutable.path)
        }
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
            "apparmor_parser",
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
                    _ = try await context.run(
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
                try await context.run("aa-enabled", ["--quiet"])
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
            layout.appArmorProfile,
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

private actor AndroidFrameworkBootSession {
    let context: WorkspaceContext
    let layout: AndroidFrameworkBootLayout
    let host: AndroidFrameworkBootHost
    var mounts = AndroidFrameworkMountLedger()
    var binderMounted = false
    var containerStarted = false
    var kernelLog: PseudoTerminalLog?
    var frameworkHealth = AndroidFrameworkHealthMonitor()
    var binderDevices: [AndroidContainerDevice] = []
    let startedAt = Date()

    init(
        context: WorkspaceContext,
        layout: AndroidFrameworkBootLayout,
        host: AndroidFrameworkBootHost
    ) {
        self.context = context
        self.layout = layout
        self.host = host
    }

    func prepare() async throws {
        for module in ["binder_linux", "erofs"] {
            try await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "modprobe",
                    module,
                ])
        }
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "apparmor_parser",
                "--replace",
                "--skip-cache",
                "--Werror",
                layout.appArmorProfile.path,
            ])
        try FileManager.default.createDirectory(
            at: layout.diagnostics,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: layout.diagnosticTombstones,
            withIntermediateDirectories: true)
        for log in [
            layout.lxcLog,
            layout.androidLog,
            layout.gfxstreamBrokerLog,
            layout.displayHostLog,
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(host.subordinateUID):\(host.subordinateGID)",
                kernelLog.slavePath,
            ])
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chmod",
                "0622",
                kernelLog.slavePath,
            ])
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--mode=0710",
                layout.instance.path,
            ])
        try await context.run(
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--owner=\(host.userID)",
                "--group=\(host.groupID)",
                "--mode=0711",
                layout.gfxstreamBrokerDirectory.path,
            ])
        try await context.run(
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--bind",
                try currentColliderExecutable(),
                layout.bpfHookExecutable.path,
            ])
        mounts.record(layout.bpfHookExecutable)
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,bind,ro,nosuid,nodev,exec",
                layout.bpfHookExecutable.path,
            ])
        try await context.run(
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--bind",
                swiftRuntime.libraryRoot.path,
                layout.swiftRuntime.path,
            ])
        mounts.record(layout.swiftRuntime)
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,bind,ro,nosuid,nodev,exec",
                layout.swiftRuntime.path,
            ])
        try await context.run(
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(mappedSystemUser):\(mappedSystemGroup)",
                layout.containerTombstones.path,
            ])
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chmod",
                "0775",
                layout.containerTombstones.path,
            ])
    }

    func mountImages(
        _ images: [AndroidImageProvenance.Image]
    ) async throws {
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
            try await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--options=ro,nosuid,nodev,loop",
                    layout.images.appendingPathComponent(name).path,
                    mountPoint.path,
                ])
            mounts.record(mountPoint)
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

    func createBinderDevices() async throws {
        try await context.run(
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(host.userID):\(host.groupID)",
                control.path,
            ])
        do {
            for name in ["binder", "hwbinder", "vndbinder"] {
                let number = try BinderFS.addDevice(
                    control: FilePath(control.path),
                    name: name)
                let device = layout.binder.appendingPathComponent(name)
                try await context.run(
                    "sudo",
                    [
                        "--non-interactive",
                        "chown",
                        "\(host.subordinateUID):\(host.subordinateGID)",
                        device.path,
                    ])
                try await context.run(
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
        } catch {
            await restoreBinderControlOwnership(control)
            throw error
        }
        await restoreBinderControlOwnership(control)
    }

    private func restoreBinderControlOwnership(_ control: URL) async {
        _ = try? await context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "0:0",
                control.path,
            ])
    }

    func mountApexes() async throws {
        let apexRoot = layout.rootFileSystem.appendingPathComponent(
            "apex",
            isDirectory: true)
        let apexes = try await discoverApexes()
        guard !apexes.isEmpty else {
            throw WorkspaceFailure.message(
                "signed Android image set contains no APEX packages")
        }

        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--types=tmpfs",
                "--options=rw,nosuid,noexec,mode=0755",
                "tmpfs",
                apexRoot.path,
            ])
        mounts.record(apexRoot)

        let colliderExecutable = try currentColliderExecutable()
        for apex in apexes {
            let versionName = "\(apex.name)@\(apex.version)"
            let versionMount = apexRoot.appendingPathComponent(
                versionName,
                isDirectory: true)
            let activeMount = apexRoot.appendingPathComponent(
                apex.name,
                isDirectory: true)
            try await context.run(
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
            try await context.run(
                mountInvocation.executable,
                mountInvocation.arguments)
            mounts.record(versionMount)
            let mountedManifest = versionMount.appendingPathComponent(
                "apex_manifest.pb")
            guard
                FileManager.default.fileExists(
                    atPath: mountedManifest.path)
            else {
                throw WorkspaceFailure.message(
                    "mounted APEX \(apex.name) has no apex_manifest.pb")
            }
            try await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--bind",
                    versionMount.path,
                    activeMount.path,
                ])
            mounts.record(activeMount)
            try await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "mount",
                    "--options=remount,bind,ro,nosuid,nodev",
                    activeMount.path,
                ])
        }
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,rw,nosuid,nodev,noexec",
                apexRoot.path,
            ])
    }

    private func discoverApexes() async throws -> [AndroidFrameworkApex] {
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
                let payloadType = try await context.run(
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
                let manifestOutput = try await context.run(
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

    func writeConfiguration() throws {
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
            gfxstreamSocketDirectory:
                layout.gfxstreamBrokerDirectory.path,
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

    func runProcesses(
        timeoutSeconds: UInt32,
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async throws {
        let invocation = AndroidBPFBrokerInvocation(
            colliderExecutable: try currentColliderExecutable(),
            socket: layout.bpfBrokerSocket.path,
            rootUID: host.subordinateUID,
            rootGID: host.subordinateGID)
        try await context.withRunningCommand(
            invocation.executable,
            invocation.arguments
        ) { broker in
            try await broker.waitUntilReady()
            try await self.waitForBPFDelegationBrokerReady(broker)
            try await self.context.withRunningCommand(
                self.layout.gfxstreamBrokerExecutable.path,
                [
                    "--socket",
                    self.layout.gfxstreamBrokerSocket.path,
                    "--expected-uid",
                    "\(UInt64(self.host.subordinateUID) + 1_000)",
                    "--parent-pid",
                    "\(getpid())",
                ],
                output: .file(FilePath(
                    self.layout.gfxstreamBrokerLog.path))
            ) { gfxstreamBroker in
                try await gfxstreamBroker.waitUntilReady()
                try await self.waitForGfxstreamBrokerReady(gfxstreamBroker)
                try await self.context.withRunningCommand(
                    self.layout.displayHostExecutable.path,
                    [
                        "--socket",
                        self.layout.displayHostSocket.path,
                        "--expected-uid",
                        "\(UInt64(self.host.subordinateUID) + 1_000)",
                        "--render-device",
                        "auto",
                        "--parent-pid",
                        "\(getpid())",
                        "--wayland",
                        waylandSocket,
                    ],
                    environmentOverrides: [
                        "XDG_RUNTIME_DIR": waylandRuntimeDirectory.path,
                    ],
                    output: .file(FilePath(
                        self.layout.displayHostLog.path))
                ) { displayHost in
                    try await displayHost.waitUntilReady()
                    try await self.waitForDisplayHostReady(displayHost)
                    let containerInvocation = AndroidLXCStartInvocation(
                        name: self.layout.name,
                        configuration: self.layout.configuration.path,
                        logFile: self.layout.lxcLog.path)
                    await self.markContainerStarted()
                    try await self.context.withRunningCommand(
                        containerInvocation.executable,
                        containerInvocation.arguments
                    ) { container in
                        try await container.waitUntilReady()
                        do {
                            try await self.waitForBPFDelegation(
                                broker: broker,
                                container: container)
                            try await self.waitForFramework(
                                container: container,
                                timeoutSeconds: timeoutSeconds)
                        } catch {
                            await self.stopContainer()
                            throw error
                        }
                        await self.stopContainer()
                    }
                }
            }
        }
    }

    private func waitForDisplayHostReady(
        _ displayHost: RunningCommand
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.displayHostSocket.path)
            {
                return
            }
            if !(await displayHost.isRunning) {
                let status = try await displayHost.wait().status
                throw WorkspaceFailure.message(
                    "Android display host exited before becoming ready "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        throw WorkspaceFailure.message(
            "Android display host did not become ready; diagnostics: "
                + layout.diagnostics.path)
    }

    private func waitForGfxstreamBrokerReady(
        _ broker: RunningCommand
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.gfxstreamBrokerSocket.path)
            {
                return
            }
            if !(await broker.isRunning) {
                let status = try await broker.wait().status
                throw WorkspaceFailure.message(
                    "Android gfxstream broker exited before becoming ready "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        throw WorkspaceFailure.message(
            "Android gfxstream broker did not become ready; diagnostics: "
                + layout.diagnostics.path)
    }

    private func markContainerStarted() {
        containerStarted = true
    }

    private func waitForBPFDelegationBrokerReady(
        _ broker: RunningCommand
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.bpfBrokerSocket.path)
            {
                return
            }
            if !(await broker.isRunning) {
                let status = try await broker.wait().status
                throw WorkspaceFailure.message(
                    "Android BPF delegation broker exited before becoming "
                        + "ready (status \(status))")
            }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        throw WorkspaceFailure.message(
            "Android BPF delegation broker did not become ready")
    }

    private func waitForBPFDelegation(
        broker: RunningCommand,
        container: RunningCommand
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            if !(await broker.isRunning) {
                let status = try await broker.wait().status
                guard status == 0 else {
                    throw WorkspaceFailure.message(
                        "Android BPF delegation broker failed "
                            + "(status \(status)); diagnostics: "
                            + layout.diagnostics.path)
                }
                return
            }
            if !(await container.isRunning) {
                let status = try await container.wait().status
                throw WorkspaceFailure.message(
                    "Android container exited before mounting its delegated "
                        + "BPF filesystem (lxc-start status \(status)); "
                        + "diagnostics: \(layout.diagnostics.path)")
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }
        throw WorkspaceFailure.message(
            "Android container did not mount its delegated BPF filesystem; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func waitForFramework(
        container: RunningCommand,
        timeoutSeconds: UInt32
    ) async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(Int64(timeoutSeconds)))
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            try frameworkHealth.check(
                log: layout.androidKernelLog,
                diagnostics: layout.diagnostics)
            if !(await container.isRunning) {
                let status = try await container.wait().status
                throw WorkspaceFailure.message(
                    "Android container exited before framework boot "
                        + "(lxc-start status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            if let state = try? await containerProperty("init.svc.logd"),
                state == "running"
            {
                let invocation = AndroidLogcatInvocation(
                    name: layout.name,
                    sinceEpochSecond:
                        max(0, Int64(startedAt.timeIntervalSince1970) - 1))
                try await context.withRunningCommand(
                    invocation.executable,
                    invocation.arguments,
                    output: .file(FilePath(layout.androidLog.path))
                ) { logcat in
                    try await logcat.waitUntilReady()
                    try await self.waitForFrameworkBoot(
                        container: container,
                        logcat: logcat,
                        deadline: deadline)
                }
                return
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        throw WorkspaceFailure.message(
            "Android framework did not publish sys.boot_completed=1; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func waitForFrameworkBoot(
        container: RunningCommand,
        logcat: RunningCommand,
        deadline: ContinuousClock.Instant
    ) async throws {
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            try frameworkHealth.check(
                log: layout.androidKernelLog,
                diagnostics: layout.diagnostics)
            if !(await container.isRunning) {
                let status = try await container.wait().status
                throw WorkspaceFailure.message(
                    "Android container exited before framework boot "
                        + "(lxc-start status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            if !(await logcat.isRunning) {
                let status = try await logcat.wait().status
                throw WorkspaceFailure.message(
                    "Android logcat collector exited unexpectedly "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            if let property = try? await containerProperty(
                "sys.boot_completed"),
                property == "1"
            {
                return
            }
            try await ContinuousClock().sleep(for: .seconds(1))
        }
        throw WorkspaceFailure.message(
            "Android framework did not publish sys.boot_completed=1; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func containerProperty(_ name: String) async throws -> String {
        try await context.run(
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

    private func stopContainer() async {
        if containerStarted {
            _ = try? await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "lxc-stop",
                    "--kill",
                    "--name",
                    layout.name,
                ])
            containerStarted = false
        }
    }

    func cleanup() async {
        await stopContainer()
        await persistTombstones()
        await captureHostAudit()
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
        for mountPoint in mounts.takeInReverseOrder() {
            _ = try? await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "umount",
                    mountPoint.path,
                ])
        }
        if binderMounted {
            _ = try? await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "umount",
                    layout.binder.path,
                ])
            binderMounted = false
        }
        _ = try? await context.run(
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

    func printFailureDiagnostics() async {
        writeStandardError(
            "Android framework boot diagnostics: "
                + layout.diagnostics.path + "\n")
        for log in [
            layout.androidKernelLog,
            layout.androidLog,
            layout.gfxstreamBrokerLog,
            layout.displayHostLog,
            layout.lxcLog,
            layout.hostAuditLog,
            layout.collectorErrors,
        ] {
            guard FileManager.default.fileExists(atPath: log.path),
                let tail = try? await context.run(
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

    private func captureHostAudit() async {
        let since = max(
            0,
            Int64(startedAt.timeIntervalSince1970) - 1)
        _ = try? await context.run(
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
    }

    private func persistTombstones() async {
        guard
            FileManager.default.fileExists(
                atPath: layout.containerTombstones.path)
        else {
            return
        }
        _ = try? await context.run(
            "sudo",
            [
                "--non-interactive",
                "cp",
                "--archive",
                layout.containerTombstones.path + "/.",
                layout.diagnosticTombstones.path,
            ])
        _ = try? await context.run(
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

struct AndroidFrameworkMountLedger {
    private var mountPoints: [URL] = []

    mutating func record(_ mountPoint: URL) {
        mountPoints.append(mountPoint)
    }

    mutating func takeInReverseOrder() -> [URL] {
        defer { mountPoints.removeAll(keepingCapacity: false) }
        return mountPoints.reversed()
    }
}

struct AndroidFrameworkHealthMonitor {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var surfaceFlingerCrashCount = 0

    mutating func check(log: URL, diagnostics: URL) throws {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: log.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            return
        }
        if size < offset {
            offset = 0
            pending.removeAll(keepingCapacity: true)
            surfaceFlingerCrashCount = 0
        }
        guard size > offset else { return }

        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else {
            return
        }
        offset += UInt64(data.count)
        pending.append(data)

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(
                decoding: pending[..<newline],
                as: UTF8.self)
            pending.removeSubrange(...newline)
            try inspect(line: line, diagnostics: diagnostics)
        }
    }

    private mutating func inspect(
        line: String,
        diagnostics: URL
    ) throws {
        if line.contains(
            "process with updatable components 'surfaceflinger' exited "
                + "4 times before boot completed")
        {
            throw failure(
                "Android init declared SurfaceFlinger critically crashing",
                diagnostics: diagnostics)
        }
        guard line.contains("init: Service 'surfaceflinger'"),
            line.contains("received SIGABRT")
                || line.contains("received SIGSEGV")
        else {
            return
        }
        surfaceFlingerCrashCount += 1
        if surfaceFlingerCrashCount >= 2 {
            throw failure(
                "SurfaceFlinger crashed \(surfaceFlingerCrashCount) times "
                    + "before framework boot",
                diagnostics: diagnostics)
        }
    }

    private func failure(
        _ reason: String,
        diagnostics: URL
    ) -> WorkspaceFailure {
        .message("\(reason); diagnostics: \(diagnostics.path)")
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
    let gfxstreamBrokerDirectory: URL
    let gfxstreamBrokerSocket: URL
    let gfxstreamBrokerExecutable: URL
    let displayHostSocket: URL
    let displayHostExecutable: URL
    let swiftRuntime: URL
    let diagnostics: URL
    let configuration: URL
    let lxcLog: URL
    let androidKernelLog: URL
    let androidLog: URL
    let gfxstreamBrokerLog: URL
    let displayHostLog: URL
    let hostAuditLog: URL
    let collectorErrors: URL
    let containerTombstones: URL
    let diagnosticTombstones: URL
    let images: URL
    let provenance: URL
    let signingIdentity: URL
    let hostTools: URL
    let appArmorProfile: URL
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
        gfxstreamBrokerDirectory = instance.appendingPathComponent(
            "gfxstream-broker",
            isDirectory: true)
        gfxstreamBrokerSocket = gfxstreamBrokerDirectory
            .appendingPathComponent("gfxstream.sock")
        displayHostSocket = gfxstreamBrokerDirectory
            .appendingPathComponent("composer.sock")
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
        gfxstreamBrokerLog = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.log")
        displayHostLog = diagnostics.appendingPathComponent(
            "android-display-host.log")
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
        gfxstreamBrokerExecutable = android.appendingPathComponent(
            ".build/debug/nucleus-android-gfxstream-broker")
        displayHostExecutable = android.appendingPathComponent(
            ".build/debug/nucleus-android-display-host")
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
        appArmorProfile = android.appendingPathComponent(
            "container/lxc-nucleus-android.apparmor")
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
