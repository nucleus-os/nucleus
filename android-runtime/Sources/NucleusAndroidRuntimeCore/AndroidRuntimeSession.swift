import Foundation
import Glibc
internal import NucleusAndroidContainerContract

public func initializeAndroidRuntimeDiagnostics(
    layout: AndroidRuntimeLayout
) throws -> AndroidRuntimeEventRecorder {
    try FileManager.default.createDirectory(
        at: layout.diagnostics,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: layout.diagnosticTombstones,
        withIntermediateDirectories: true)
    let progress = try AndroidRuntimeEventRecorder(
        output: layout.progressLog)
    try progress.record(
        "session.initialized",
        fields: ["runtime": layout.name])
    for log in [
        layout.lxcLog,
        layout.androidKernelLog,
        layout.androidLog,
        layout.gfxstreamBrokerLog,
        layout.displayHostLog,
        layout.hostAuditLog,
        layout.gfxstreamCoreCollectorLog,
    ] {
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(
                atPath: log.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: log.path)
    }
    for artifact in [
        layout.gfxstreamCore,
        layout.gfxstreamCoreMetadata,
    ] where FileManager.default.fileExists(atPath: artifact.path) {
        try FileManager.default.removeItem(at: artifact)
    }
    return progress
}

public actor AndroidRuntimeSession<
    RuntimeHost: AndroidRuntimeHost
> {
    let context: RuntimeHost
    let layout: AndroidRuntimeLayout
    let host: AndroidRuntimeHostConfiguration
    let privilegedHelperExecutable: String
    let swiftRuntime: AndroidSwiftRuntime
    let persistentData: URL
    let gfxstreamBrokerEnvironment: [String: String]
    var mounts = AndroidRuntimeMountLedger()
    var binderMounted = false
    var containerStarted = false
    var kernelLog: RuntimeHost.KernelLog?
    var progress: AndroidRuntimeEventRecorder?
    var trackedHostProcesses: [String: Int32] = [:]
    var binderDevices: [AndroidContainerDevice] = []
    let startedAt = Date()

    public init(
        context: RuntimeHost,
        layout: AndroidRuntimeLayout,
        host: AndroidRuntimeHostConfiguration,
        privilegedHelperExecutable: String,
        swiftRuntime: AndroidSwiftRuntime,
        dataProvenanceKey: String,
        gfxstreamBrokerEnvironment: [String: String],
        progress: AndroidRuntimeEventRecorder
    ) {
        self.context = context
        self.layout = layout
        self.host = host
        self.privilegedHelperExecutable = privilegedHelperExecutable
        self.swiftRuntime = swiftRuntime
        self.persistentData = layout.androidRoot
            .appendingPathComponent(".runtime-data", isDirectory: true)
            .appendingPathComponent(dataProvenanceKey, isDirectory: true)
        self.gfxstreamBrokerEnvironment = gfxstreamBrokerEnvironment
        self.progress = progress
    }

    public func prepare() async throws {
        try await reconcileAbandonedRuntimes()
        for module in androidRuntimeRequiredKernelModules {
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
        kernelLog = try context.makeKernelLog(
            output: layout.androidKernelLog)
        guard let kernelLog else {
            throw AndroidRuntimeFailure(
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
                "--mode=0755",
                layout.deviceFileSystem.path,
            ])
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--types=tmpfs",
                "--options=rw,nosuid,dev,noexec,mode=0755,size=64k",
                "tmpfs",
                layout.deviceFileSystem.path,
            ])
        mounts.record(layout.deviceFileSystem)
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
                "--directory",
                "--owner=\(host.userID)",
                "--group=\(host.groupID)",
                "--mode=0711",
                layout.runtimeBridgeDirectory.path,
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
                privilegedHelperExecutable,
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
            layout.hostKernelConfigurationDirectory,
            layout.containerTombstones,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        }
        let kernelConfiguration = try Data(
            contentsOf: host.kernelConfiguration)
        guard isValidHostKernelConfiguration(kernelConfiguration) else {
            throw AndroidRuntimeFailure(
                "running kernel configuration is empty or malformed: "
                    + host.kernelConfiguration.path)
        }
        try kernelConfiguration.write(
            to: layout.hostKernelConfiguration,
            options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: layout.hostKernelConfiguration.path)
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
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "install",
                "--directory",
                "--owner=\(host.userID)",
                "--group=\(host.groupID)",
                "--mode=0771",
                persistentData.path,
            ])
        try await validatePersistentDataFileSystem()
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "chown",
                "\(mappedSystemUser):\(mappedSystemGroup)",
                persistentData.path,
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
                layout.persistentDataMountPoint.path,
            ])
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--bind",
                persistentData.path,
                layout.persistentDataMountPoint.path,
            ])
        mounts.record(layout.persistentDataMountPoint)
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "mount",
                "--options=remount,bind,rw,nosuid,nodev",
                layout.persistentDataMountPoint.path,
            ])
    }

    private func validatePersistentDataFileSystem() async throws {
        let validationFile = persistentData.appendingPathComponent(
            ".nucleus-fsverity-validation")
        try Data("nucleus-fsverity\n".utf8).write(
            to: validationFile,
            options: .atomic)
        defer { try? FileManager.default.removeItem(at: validationFile) }
        do {
            try await context.run(
                "fsverity",
                ["enable", validationFile.path])
            _ = try await context.run(
                "fsverity",
                ["digest", validationFile.path],
                capture: true)
        } catch {
            throw AndroidRuntimeFailure(
                "persistent Android data filesystem does not support "
                    + "fs-verity: \(persistentData.path)")
        }
    }

    public func mountImages(
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
                throw AndroidRuntimeFailure(
                    "signed image set is missing \(name)")
            }
            if name != "system.img",
                !FileManager.default.fileExists(atPath: mountPoint.path)
            {
                throw AndroidRuntimeFailure(
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
                    throw AndroidRuntimeFailure(
                        "system-as-root image does not provide "
                            + "/system/bin/init")
                }
            }
        }
    }

    public func createBinderDevices() async throws {
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
                let number = try context.addBinderDevice(
                    control: control,
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

    public func mountApexes() async throws {
        let apexRoot = layout.rootFileSystem.appendingPathComponent(
            "apex",
            isDirectory: true)
        let apexes = try await discoverApexes()
        guard !apexes.isEmpty else {
            throw AndroidRuntimeFailure(
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

        let helperExecutable =
            privilegedHelperExecutable
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
            let mountInvocation = AndroidApexMountInvocation(
                helperExecutable: helperExecutable,
                rootFileSystem: layout.rootFileSystem.path,
                source: apex.containerPath,
                target: "/apex/\(versionName)",
                payloadFileSystem: apex.payloadFileSystem,
                payloadOffset: apex.payload.offset)
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
                throw AndroidRuntimeFailure(
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
                    throw AndroidRuntimeFailure(
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
                        AndroidRuntimeApexPayloadFileSystem(
                            rawValue: payloadType)
                else {
                    throw AndroidRuntimeFailure(
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
                    throw AndroidRuntimeFailure(
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

    public func writeConfiguration() throws {
        guard let kernelLog else {
            throw AndroidRuntimeFailure(
                "Android kernel-log transport is not prepared")
        }
        let configuration = AndroidContainerConfiguration(
            name: layout.name,
            rootFileSystem: layout.rootFileSystem.path,
            seccompProfile: layout.seccompProfile.path,
            kernelLogDevice: kernelLog.slavePath,
            tombstones: layout.containerTombstones.path,
            persistentData: layout.persistentDataMountPoint.path,
            gfxstreamSocketDirectory:
                layout.gfxstreamBrokerDirectory.path,
            runtimeBridgeSocket: layout.runtimeBridgeSocket.path,
            presentationSocket: layout.presentationSocket.path,
            displayControlSocket: layout.displayControlSocket.path,
            hostKernelConfigurationDirectory:
                layout.hostKernelConfigurationDirectory.path,
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
                            swiftRuntime.loaderSearchPath,
                            isDirectory: true
                        )
                        .path,
                    layout.bpfHookExecutable.path,
                    AndroidRuntimePrivilegedOperation.bpfMountCommandName,
                    "--socket",
                    layout.bpfBrokerSocket.path,
                    "--root-file-system",
                    layout.rootFileSystem.path,
                    "--container",
                    layout.name,
                ]),
            startHostHook: AndroidContainerMountHook(
                executable: "/usr/bin/env",
                arguments: [
                    "LD_LIBRARY_PATH="
                        + layout.swiftRuntime
                        .appendingPathComponent(
                            swiftRuntime.loaderSearchPath,
                            isDirectory: true
                        )
                        .path,
                    layout.bpfHookExecutable.path,
                    AndroidRuntimePrivilegedOperation
                        .cgroupDelegateCommandName,
                    "--container",
                    layout.name,
                    "--system-uid",
                    "\(UInt64(host.subordinateUID) + 1_000)",
                    "--system-gid",
                    "\(UInt64(host.subordinateGID) + 1_000)",
                ]))
        try Data(
            try configuration.lxcConfiguration().utf8
        ).write(to: layout.configuration, options: .atomic)
    }

    public func recordRuntimeBridgeListener() throws {
        var metadata = stat()
        guard unsafe lstat(
            layout.runtimeBridgeSocket.path,
            &metadata) == 0
        else {
            throw AndroidRuntimeFailure(
                "Android runtime bridge listener is not visible before "
                    + "container start: \(layout.runtimeBridgeSocket.path)")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw AndroidRuntimeFailure(
                "Android runtime bridge endpoint is not a socket: "
                    + layout.runtimeBridgeSocket.path)
        }
        try progress?.record(
            "runtime-bridge.listener-ready",
            fields: [
                "path": layout.runtimeBridgeSocket.path,
                "uid": String(metadata.st_uid),
                "gid": String(metadata.st_gid),
                "mode": String(metadata.st_mode & 0o777, radix: 8),
                "device": String(metadata.st_dev),
                "inode": String(metadata.st_ino),
            ])
    }

    public func recordRuntimeBridgeStage(
        _ stage: String,
        fields: [String: String] = [:]
    ) throws {
        try progress?.record(
            "runtime-bridge.\(stage)",
            fields: fields)
    }

    public func runProcesses(
        timeoutSeconds: UInt32,
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async throws {
        try progress?.record("services.starting")
        let invocation = AndroidBPFBrokerInvocation(
            helperExecutable:
                privilegedHelperExecutable,
            socket: layout.bpfBrokerSocket.path,
            rootUID: host.subordinateUID,
            rootGID: host.subordinateGID)
        try await context.withRunningCommand(
            invocation.executable,
            invocation.arguments
        ) { broker in
            try await broker.waitUntilReady()
            try await self.waitForBPFDelegationBrokerReady(broker)
            try await self.recordProgress("bpf-broker.ready")
            try await self.context.withRunningCommand(
                self.layout.gfxstreamBrokerExecutable.path,
                [
                    "--socket",
                    self.layout.gfxstreamBrokerSocket.path,
                    "--uid-range-start",
                    "\(self.host.subordinateUID)",
                    "--uid-range-count",
                    "\(self.host.subordinateUIDCount)",
                    "--parent-pid",
                    "\(getpid())",
                ],
                environmentOverrides: self.gfxstreamBrokerEnvironment,
                output: .file(self.layout.gfxstreamBrokerLog)
            ) { gfxstreamBroker in
                try await gfxstreamBroker.waitUntilReady()
                guard let gfxstreamBrokerPID =
                    await gfxstreamBroker.processIdentifier
                else {
                    throw AndroidRuntimeFailure(
                        "Android gfxstream broker started without a "
                            + "process identifier")
                }
                await self.trackHostProcess(
                    "gfxstream-broker",
                    processIdentifier: gfxstreamBrokerPID)
                try await self.waitForGfxstreamBrokerReady(gfxstreamBroker)
                try await self.recordProgress("gfxstream-broker.ready")
                do {
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
                            "--input-socket",
                            self.layout.displayInputSocket.path,
                            "--presentation-socket",
                            self.layout.presentationSocket.path,
                            "--display-control-socket",
                            self.layout.displayControlSocket.path,
                            "--presentation-expected-uid",
                            "\(UInt64(self.host.subordinateUID) + 2_900)",
                        ],
                        environmentOverrides: [
                            "XDG_RUNTIME_DIR": waylandRuntimeDirectory.path,
                        ],
                        output: .file(self.layout.displayHostLog)
                    ) { displayHost in
                        try await displayHost.waitUntilReady()
                        guard let displayHostPID =
                            await displayHost.processIdentifier
                        else {
                            throw AndroidRuntimeFailure(
                                "Android display host started without a "
                                    + "process identifier")
                        }
                        await self.trackHostProcess(
                            "display-host",
                            processIdentifier: displayHostPID)
                        try await self.waitForDisplayHostReady(displayHost)
                        try await self.recordProgress("display-host.ready")
                        let containerInvocation = AndroidLXCStartInvocation(
                            helperExecutable:
                                self.privilegedHelperExecutable,
                            ownerProcessIdentifier: getpid(),
                            name: self.layout.name,
                            configuration: self.layout.configuration.path,
                            logFile: self.layout.lxcLog.path)
                        await self.markContainerStarted()
                        try await self.context.withRunningCommand(
                            containerInvocation.executable,
                            containerInvocation.arguments
                        ) { container in
                            try await container.waitUntilReady()
                            if let containerPID =
                                await container.processIdentifier
                            {
                                await self.trackHostProcess(
                                    "container-launcher",
                                    processIdentifier: containerPID)
                            }
                            try await self.recordProgress(
                                "container.started")
                            do {
                                try await self.waitForRuntimeBridgeMount(
                                    container: container)
                                try await self.waitForBPFDelegation(
                                    broker: broker,
                                    container: container)
                                try await self.runRuntime(
                                    container: container,
                                    displayHost: displayHost,
                                    gfxstreamBroker: gfxstreamBroker,
                                    timeoutSeconds: timeoutSeconds)
                            } catch {
                                try? await self.stopContainer()
                                throw error
                            }
                            try await self.stopContainer()
                            try await self.recordProgress(
                                "container.stopped")
                        }
                    }
                } catch {
                    if !(await gfxstreamBroker.isRunning) {
                        await self.captureGfxstreamCore(
                            processIdentifier: gfxstreamBrokerPID)
                    }
                    throw error
                }
            }
        }
    }

    private func captureGfxstreamCore(
        processIdentifier: Int32
    ) async {
        guard
            gfxstreamBrokerEnvironment[
                "NUCLEUS_ADDRESS_SANITIZER_SCOPE"
            ] != nil
        else {
            return
        }
        let identifier = String(processIdentifier)
        var metadata: String?
        for _ in 0..<100 {
            metadata = try? await context.run(
                "coredumpctl",
                [
                    "--no-pager",
                    "--json=pretty",
                    "info",
                    identifier,
                ],
                capture: true)
            if metadata?.isEmpty == false {
                break
            }
            try? await ContinuousClock().sleep(
                for: .milliseconds(100))
        }
        guard let metadata, !metadata.isEmpty else {
            try? Data(
                (
                    "systemd-coredump did not publish metadata for "
                        + "gfxstream broker PID \(identifier)\n"
                ).utf8
            ).write(
                to: layout.gfxstreamCoreCollectorLog,
                options: .atomic)
            return
        }
        do {
            try Data(metadata.utf8).write(
                to: layout.gfxstreamCoreMetadata,
                options: .atomic)
            try await context.run(
                "coredumpctl",
                [
                    "--quiet",
                    "--output=\(layout.gfxstreamCore.path)",
                    "dump",
                    identifier,
                ])
            let attributes = try FileManager.default.attributesOfItem(
                atPath: layout.gfxstreamCore.path)
            let coreSize =
                (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard coreSize > 0 else {
                throw AndroidRuntimeFailure(
                    "systemd-coredump exported an empty core file")
            }
        } catch {
            try? Data(
                (
                    "collecting gfxstream broker core for PID "
                        + "\(identifier) failed: \(error)\n"
                ).utf8
            ).write(
                to: layout.gfxstreamCoreCollectorLog,
                options: .atomic)
        }
    }

    private func waitForDisplayHostReady(
        _ displayHost: RuntimeHost.RunningProcess
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.displayHostSocket.path),
               FileManager.default.fileExists(
                atPath: layout.presentationSocket.path),
               FileManager.default.fileExists(
                atPath: layout.displayControlSocket.path)
            {
                return
            }
            if !(await displayHost.isRunning) {
                let status = try await displayHost.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android display host exited before becoming ready "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        throw AndroidRuntimeFailure(
            "Android display host did not become ready; diagnostics: "
                + layout.diagnostics.path)
    }

    private func waitForRuntimeBridgeMount(
        container: RuntimeHost.RunningProcess
    ) async throws {
        try await waitForRuntimeSocketMount(
            hostPath: layout.runtimeBridgeSocket.path,
            containerPath: "/dev/nucleus-runtime/broker.sock",
            container: container)
        try await waitForRuntimeSocketMount(
            hostPath: layout.presentationSocket.path,
            containerPath: "/dev/nucleus-runtime/presentation.sock",
            container: container)
        try await waitForRuntimeSocketMount(
            hostPath: layout.displayControlSocket.path,
            containerPath: "/dev/nucleus-runtime/display-control.sock",
            container: container)
    }

    private func waitForRuntimeSocketMount(
        hostPath: String,
        containerPath: String,
        container: RuntimeHost.RunningProcess
    ) async throws {
        var metadata = stat()
        guard unsafe lstat(
            hostPath,
            &metadata) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
        else {
            throw AndroidRuntimeFailure(
                "Android runtime socket disappeared before "
                    + "container mount validation")
        }
        let expected = "\(metadata.st_dev):\(metadata.st_ino)"
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var observed = "unavailable"
        while ContinuousClock.now < deadline {
            if let value = try? await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "lxc-attach",
                    "--name",
                    layout.name,
                    "--",
                    "/system/bin/stat",
                    "-c",
                    "%d:%i",
                    containerPath,
                ],
                capture: true)
            {
                observed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if observed == expected {
                    try progress?.record(
                        "runtime-bridge.mount-verified",
                        fields: [
                            "hostPath": hostPath,
                            "containerPath": containerPath,
                            "deviceAndInode": expected,
                        ])
                    return
                }
            }
            if !(await container.isRunning) {
                let status = try await container.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android container exited before runtime bridge mount "
                        + "validation (status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }
        throw AndroidRuntimeFailure(
            "Android runtime bridge mount does not resolve to the host "
                + "listener (expected \(expected), observed \(observed)); "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func waitForGfxstreamBrokerReady(
        _ broker: RuntimeHost.RunningProcess
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.gfxstreamBrokerSocket.path)
            {
                return
            }
            if !(await broker.isRunning) {
                let status = try await broker.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android gfxstream broker exited before becoming ready "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        throw AndroidRuntimeFailure(
            "Android gfxstream broker did not become ready; diagnostics: "
                + layout.diagnostics.path)
    }

    private func markContainerStarted() {
        containerStarted = true
    }

    private func waitForBPFDelegationBrokerReady(
        _ broker: RuntimeHost.RunningProcess
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(
                atPath: layout.bpfBrokerSocket.path)
            {
                return
            }
            if !(await broker.isRunning) {
                let status = try await broker.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android BPF delegation broker exited before becoming "
                        + "ready (status \(status))")
            }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        throw AndroidRuntimeFailure(
            "Android BPF delegation broker did not become ready")
    }

    private func waitForBPFDelegation(
        broker: RuntimeHost.RunningProcess,
        container: RuntimeHost.RunningProcess
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            if !(await broker.isRunning) {
                let status = try await broker.waitForExit().status
                guard status == 0 else {
                    throw AndroidRuntimeFailure(
                        "Android BPF delegation broker failed "
                            + "(status \(status)); diagnostics: "
                            + layout.diagnostics.path)
                }
                return
            }
            if !(await container.isRunning) {
                let status = try await container.waitForExit().status
                let primaryFailure = androidLXCPrimaryFailure(
                    logFile: layout.lxcLog)
                throw AndroidRuntimeFailure(
                    "Android container exited during LXC setup, before BPF "
                        + "delegation (lxc-start status \(status))"
                        + (primaryFailure.map { "; primary LXC failure: \($0)" }
                            ?? "")
                        + "; "
                        + "diagnostics: \(layout.diagnostics.path)")
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }
        throw AndroidRuntimeFailure(
            "Android container did not mount its delegated BPF filesystem; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func runRuntime(
        container: RuntimeHost.RunningProcess,
        displayHost: RuntimeHost.RunningProcess,
        gfxstreamBroker: RuntimeHost.RunningProcess,
        timeoutSeconds: UInt32
    ) async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(Int64(timeoutSeconds)))
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            try await checkGraphicsServices(
                displayHost: displayHost,
                gfxstreamBroker: gfxstreamBroker)
            if !(await container.isRunning) {
                let status = try await container.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android container exited during runtime startup "
                        + "(lxc-start status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            if let state = try? await containerProperty("init.svc.logd"),
                state == "running"
            {
                try progress?.record("android.logd.ready")
                let invocation = AndroidLogcatInvocation(
                    name: layout.name,
                    sinceEpochSecond:
                        max(0, Int64(startedAt.timeIntervalSince1970) - 1))
                try await context.withRunningCommand(
                    invocation.executable,
                    invocation.arguments,
                    output: .file(layout.androidLog)
                ) { logcat in
                    try await logcat.waitUntilReady()
                    try await self.recordProgress("android.logcat.ready")
                    try await self.recordProgress("runtime.monitoring")
                    try await self.monitorRuntime(
                        container: container,
                        logcat: logcat,
                        displayHost: displayHost,
                        gfxstreamBroker: gfxstreamBroker)
                }
                return
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        throw AndroidRuntimeFailure(
            "Android runtime did not publish sys.boot_completed=1; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func monitorRuntime(
        container: RuntimeHost.RunningProcess,
        logcat: RuntimeHost.RunningProcess,
        displayHost: RuntimeHost.RunningProcess,
        gfxstreamBroker: RuntimeHost.RunningProcess
    ) async throws {
        while true {
            try Task.checkCancellation()
            try kernelLog?.checkHealth()
            try await checkGraphicsServices(
                displayHost: displayHost,
                gfxstreamBroker: gfxstreamBroker)
            if !(await container.isRunning) {
                let status = try await container.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android container exited during the session "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            if !(await logcat.isRunning) {
                let status = try await logcat.waitForExit().status
                throw AndroidRuntimeFailure(
                    "Android logcat collector exited during the session "
                        + "(status \(status)); diagnostics: "
                        + layout.diagnostics.path)
            }
            try await ContinuousClock().sleep(for: .seconds(1))
        }
    }

    private func checkGraphicsServices(
        displayHost: RuntimeHost.RunningProcess,
        gfxstreamBroker: RuntimeHost.RunningProcess
    ) async throws {
        if !(await displayHost.isRunning) {
            try Task.checkCancellation()
            let status = try await displayHost.waitForExit().status
            try Task.checkCancellation()
            throw AndroidRuntimeFailure(
                "Android display host exited unexpectedly during runtime operation "
                    + "(status \(status)); diagnostics: "
                    + layout.diagnostics.path)
        }
        if !(await gfxstreamBroker.isRunning) {
            try Task.checkCancellation()
            let status = try await gfxstreamBroker.waitForExit().status
            try Task.checkCancellation()
            throw AndroidRuntimeFailure(
                "Android gfxstream broker exited unexpectedly during runtime operation "
                    + "(status \(status)); diagnostics: "
                + layout.diagnostics.path)
        }
        if let log = try? String(
            contentsOf: layout.gfxstreamBrokerLog,
            encoding: .utf8),
            log.contains("\"stage\":\"vulkan-fence.export.failed\"")
                || log.contains("\"stage\":\"vulkan-fence.wait.failed\"")
                || log.contains("\"stage\":\"vulkan-qsri.materialize.failed\"")
                || log.contains("\"stage\":\"vulkan-qsri.export.failed\"")
                || log.contains("\"stage\":\"vulkan-qsri.wait.failed\"")
                || log.contains("\"stage\":\"vulkan-qsri.signal.failed\"")
        {
            throw AndroidRuntimeFailure(
                "Android gfxstream graphics synchronization failed; "
                    + "diagnostics: \(layout.diagnostics.path)")
        }
    }

    private func containerProperty(_ name: String) async throws -> String {
        let began = ContinuousClock.now
        do {
            let value = try await context.run(
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
            let duration = AndroidRuntimeEventRecorder.milliseconds(
                began.duration(to: ContinuousClock.now))
            try progress?.record(
                "android.property",
                fields: [
                    "name": name,
                    "value": value,
                    "durationMilliseconds": "\(duration)",
                ])
            if duration >= 500 {
                try await captureStallSnapshot(
                    trigger: "property.\(name)",
                    durationMilliseconds: duration)
            }
            return value
        } catch {
            let duration = AndroidRuntimeEventRecorder.milliseconds(
                began.duration(to: ContinuousClock.now))
            try? progress?.record(
                "android.property.failed",
                fields: [
                    "name": name,
                    "durationMilliseconds": "\(duration)",
                    "error": "\(error)",
                ])
            throw error
        }
    }

    private var containerCgroup: URL {
        URL(
            fileURLWithPath:
                "/sys/fs/cgroup/system.slice/\(layout.name).scope",
            isDirectory: true)
    }

    private func trackHostProcess(
        _ name: String,
        processIdentifier: Int32
    ) {
        trackedHostProcesses[name] = processIdentifier
    }

    private func recordProgress(_ stage: String) throws {
        try progress?.record(stage)
    }

    public func recordFailure(_ error: String) {
        try? progress?.record(
            "runtime.failed",
            fields: ["error": error])
    }

    public func recordCancellation() {
        try? progress?.record("runtime.cancelled")
    }

    private func captureStallSnapshot(
        trigger: String,
        durationMilliseconds: Int64
    ) async throws {
        try progress?.recordHostSample(
            cgroup: containerCgroup,
            processIdentifiers: trackedHostProcesses)
        let processes = try? await context.run(
            "sudo",
            [
                "--non-interactive",
                "lxc-attach",
                "--name",
                layout.name,
                "--",
                "/system/bin/ps",
                "-A",
                "-o",
                "PID,PPID,NAME,STAT,WCHAN",
            ],
            capture: true)
        try progress?.record(
            "stall.snapshot",
            fields: [
                "trigger": trigger,
                "durationMilliseconds": "\(durationMilliseconds)",
                "guestProcesses": processes ?? "unavailable",
            ])
    }

    private func stopContainer() async throws {
        if containerStarted {
            try await context.run(
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

    private func reconcileAbandonedRuntimes() async throws {
        let output = try await context.run(
            "sudo",
            [
                "--non-interactive",
                "lxc-ls",
                "--running",
                "--line",
            ],
            capture: true)
        var abandonedNames = Set(androidRuntimeContainerNames(output))
        if FileManager.default.fileExists(atPath: layout.runtime.path) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: layout.runtime,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            abandonedNames.formUnion(
                entries.lazy
                    .map(\.lastPathComponent)
                    .filter(isNucleusAndroidRuntimeContainerName))
        }
        abandonedNames.remove(layout.name)
        let runningNames = Set(androidRuntimeContainerNames(output))
        for name in abandonedNames.sorted() {
            do {
                try progress?.record(
                    "runtime.orphan-discovered",
                    fields: [
                        "container": name,
                        "running":
                            runningNames.contains(name) ? "true" : "false",
                    ])
                if runningNames.contains(name) {
                    try await context.run(
                        "sudo",
                        [
                            "--non-interactive",
                            "lxc-stop",
                            "--kill",
                            "--name",
                            name,
                        ])
                }
                _ = try? await context.run(
                    "sudo",
                    [
                        "--non-interactive",
                        "systemctl",
                        "stop",
                        "\(name).scope",
                    ])
                try await removeAbandonedRuntimeDirectory(name: name)
                try progress?.record(
                    "runtime.orphan-reconciled",
                    fields: ["container": name])
            } catch {
                try? progress?.record(
                    "runtime.orphan-reconciliation-failed",
                    fields: [
                        "container": name,
                        "error": String(describing: error),
                    ])
                throw error
            }
        }
    }

    private func removeAbandonedRuntimeDirectory(
        name: String
    ) async throws {
        let instance = layout.runtime.appendingPathComponent(
            name,
            isDirectory: true)
        guard FileManager.default.fileExists(atPath: instance.path) else {
            return
        }
        let output = try await context.run(
            "findmnt",
            androidRuntimeMountDiscoveryArguments(
                instance: instance.path),
            capture: true)
        let mountPoints = androidRuntimeMountPoints(
            output,
            instance: instance.path)
        for mountPoint in mountPoints {
            try await context.run(
                "sudo",
                [
                    "--non-interactive",
                    "umount",
                    mountPoint,
                ])
        }
        try await context.run(
            "sudo",
            [
                "--non-interactive",
                "rm",
                "--recursive",
                "--force",
                "--one-file-system",
                instance.path,
            ])
    }

    public func cleanup() async throws {
        try? progress?.record("runtime.cleanup-started")
        var failures: [String] = []
        do {
            try await stopContainer()
        } catch {
            failures.append("stop container: \(error)")
        }
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
            do {
                try await context.run(
                    "sudo",
                    [
                        "--non-interactive",
                        "umount",
                        mountPoint.path,
                    ])
            } catch {
                failures.append(
                    "unmount \(mountPoint.path): \(error)")
            }
        }
        if binderMounted {
            do {
                try await context.run(
                    "sudo",
                    [
                        "--non-interactive",
                        "umount",
                        layout.binder.path,
                    ])
                binderMounted = false
            } catch {
                failures.append(
                    "unmount \(layout.binder.path): \(error)")
            }
        }
        if FileManager.default.fileExists(atPath: layout.instance.path) {
            do {
                try await context.run(
                    "sudo",
                    [
                        "--non-interactive",
                        "rm",
                        "--recursive",
                        "--force",
                        "--one-file-system",
                        layout.instance.path,
                    ])
            } catch {
                failures.append("remove \(layout.instance.path): \(error)")
            }
        }
        if FileManager.default.fileExists(atPath: layout.instance.path) {
            failures.append(
                "runtime instance remains at \(layout.instance.path)")
        }
        guard failures.isEmpty else {
            let message = failures.joined(separator: "\n")
            try? Data((message + "\n").utf8).write(
                to: layout.collectorErrors,
                options: .atomic)
            try? progress?.record(
                "runtime.cleanup-failed",
                fields: ["failures": message])
            throw AndroidRuntimeFailure(
                "Android runtime cleanup failed: \(message)")
        }
        try? progress?.record("runtime.cleanup-completed")
    }

    public func printFailureDiagnostics() async {
        writeStandardError(
            "Android runtime diagnostics: "
                + layout.diagnostics.path + "\n")
        for log in [
            layout.androidKernelLog,
            layout.androidLog,
            layout.gfxstreamBrokerLog,
            layout.displayHostLog,
            layout.progressLog,
            layout.lxcLog,
            layout.hostAuditLog,
            layout.collectorErrors,
            layout.gfxstreamCoreMetadata,
            layout.gfxstreamCoreCollectorLog,
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
            output: .file(layout.hostAuditLog))
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


private struct AndroidFrameworkApex {
    let name: String
    let version: String
    let containerPath: String
    let payloadFileSystem: AndroidRuntimeApexPayloadFileSystem
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


private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
