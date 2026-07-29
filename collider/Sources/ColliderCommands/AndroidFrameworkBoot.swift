import AndroidRuntimeColliderRecipe
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

private let androidFrameworkKernelModules = [
    "binder_linux",
    "erofs",
    // Android netd uses the legacy xtables ABI inside the container network
    // namespace. Load its table and rule modules from the initial namespace:
    // an unprivileged user namespace cannot trigger host module autoloading.
    "ip_tables",
    "ip6_tables",
    "iptable_filter",
    "ip6table_filter",
    "iptable_mangle",
    "ip6table_mangle",
    "iptable_raw",
    "ip6table_raw",
    "iptable_nat",
    "ip6table_nat",
    "xt_connmark",
    "xt_conntrack",
    "xt_CT",
    "xt_state",
    "xt_mark",
    "xt_NFLOG",
    "nfnetlink_log",
    "ipt_REJECT",
    "ip6t_REJECT",
    "xt_TCPMSS",
    "xt_u32",
    "xt_tcpudp",
    "xt_multiport",
    "xt_owner",
    "xt_policy",
    "xt_quota",
    "ipt_rpfilter",
    "ip6t_rpfilter",
    "xt_bpf",
    "xt_IDLETIMER",
    "xt_MASQUERADE",
    "xt_socket",
    "xt_comment",
    "xt_limit",
]

struct AndroidFrameworkBootCommand {
    let context: WorkspaceContext
    let timeoutSeconds: UInt32
    let enableVulkanValidation: Bool
    let brokerSanitizer: AndroidFrameworkBrokerSanitizer?

    func run() async throws {
        guard getuid() != 0 else {
            throw WorkspaceFailure.message(
                "run Collider as the workspace user, not as root")
        }
        try await ComponentRegistry(context: context).buildAndroidRuntimeHost()
        let brokerLaunch = try await buildBrokerLaunch()
        let swiftPM = try context.swiftPMInvocation()
        let installation = try await RuntimeInstaller(context: context).install(
            prefix: context.layout.installPrefix)
        let layout = AndroidFrameworkBootLayout(
            context: context,
            gfxstreamBrokerExecutable: brokerLaunch.executable,
            displayHostExecutable: URL(
                fileURLWithPath: swiftPM.executable(
                    "nucleus-android-display-host").string))
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
            host: host,
            dataProvenanceKey:
                provenance.sourceManifestSHA256
                + "-"
                + provenance.productTreeSHA256,
            gfxstreamBrokerEnvironment: brokerLaunch.environment)
        try await frameworkSession.initializeDiagnostics()
        let statusFile = layout.diagnostics.appendingPathComponent(
            "session-status.bin")
        var environment = context.environment
        if enableVulkanValidation {
            let layer = try VulkanValidationLayer.resolve(
                environment: environment)
            layer.applying(to: &environment)
        }
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
                    "--configuration", try SessionConfiguration(
                        enableVulkanValidation: enableVulkanValidation,
                        xwaylandExecutablePath: resolveXwaylandExecutable(
                            environment: context.environment)).hexEncoded,
                    "--", installation.compositor.path,
                ],
                environmentOverrides: environment
            ) { compositorSession in
                try await compositorSession.waitUntilReady()
                try await waitForSessionReadiness(
                    compositorSession,
                    statusFile: statusFile)
                let logWindow = AndroidBootLogWindowInvocation(
                    kittyExecutable: host.kittyExecutable.path,
                    tailExecutable: host.tailExecutable.path,
                    kernelLog: layout.androidKernelLog.path,
                    frameworkLog: layout.androidLog.path,
                    brokerLog: layout.gfxstreamBrokerLog.path,
                    progressLog: layout.progressLog.path)
                try await context.withRunningCommand(
                    logWindow.executable,
                    logWindow.arguments,
                    environmentOverrides: [
                        "XDG_RUNTIME_DIR": compositorRuntime.directory.path,
                        "WAYLAND_DISPLAY": "wayland-0",
                    ],
                    output: .file(FilePath(layout.kittyLog.path))
                ) { kitty in
                    try await kitty.waitUntilReady()
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
        let parentValues = try? parent.resourceValues(forKeys: [.isDirectoryKey])
        guard parent.path != "/",
              parentValues?.isDirectory == true
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
        try validateImageFreshness(
            provenance,
            layout: layout)
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

    private func validateImageFreshness(
        _ image: AndroidImageProvenance,
        layout: AndroidFrameworkBootLayout
    ) throws {
        let decoder = JSONDecoder()
        let source = try decoder.decode(
            AndroidSourceProvenance.self,
            from: Data(contentsOf: layout.sourceProvenance))
        let patchManifest = try decoder.decode(
            AndroidPatchManifest.self,
            from: Data(contentsOf: layout.patchManifest))
        let sourceLock = try decoder.decode(
            AndroidSourceLock.self,
            from: Data(contentsOf: layout.sourceLock))
        let productLock = try decoder.decode(
            AndroidProductLock.self,
            from: Data(contentsOf: layout.productLock))

        var patchDigests: [String] = []
        for repository in patchManifest.repositories {
            for patch in repository.patches {
                patchDigests.append(
                    try ArtifactHasher.digest(
                        file: FilePath(
                            layout.androidRoot.appendingPathComponent(patch)
                                .path)
                    ).sha256Hex)
            }
        }
        let productTreeSHA256 =
            try androidFrameworkProductDefinitionDigest(
                androidRoot: layout.androidRoot).sha256Hex
        if let reason = androidImageStalenessReason(
            image: image,
            source: source,
            patchManifest: patchManifest,
            patchDigests: patchDigests,
            sourceManifestCommit: sourceLock.platform.manifestCommit,
            productLock: productLock,
            productTreeSHA256: productTreeSHA256)
        {
            throw WorkspaceFailure.message(
                "published Android image is stale: \(reason); "
                    + "run 'collider android-runtime image'")
        }
    }

    private func buildBrokerLaunch() async throws
        -> AndroidFrameworkBrokerLaunch
    {
        guard let brokerSanitizer else {
            let swiftPM = try context.swiftPMInvocation()
            return AndroidFrameworkBrokerLaunch(
                executable: URL(
                    fileURLWithPath: swiftPM.executable(
                        "nucleus-android-gfxstream-broker").string),
                environment: [:])
        }
        let gfxstreamHostLibrary =
            try await buildAddressSanitizedGfxstreamHost()
        let buildEnvironment = [
            "NUCLEUS_GFXSTREAM_HOST_LIBRARY":
                gfxstreamHostLibrary.path,
        ]
        let swiftPM = try context.swiftPMInvocation(
            sanitizer: brokerSanitizer.rawValue)
        let arguments = swiftPM.commandArguments([
            "build",
            "--product", "nucleus-android-gfxstream-broker",
        ])
        print(
            "==> build Android framework broker "
                + "sanitizer=\(brokerSanitizer.rawValue) "
                + "scratch=\(swiftPM.scratchPath)")
        try await context.run(
            "swift",
            arguments,
            directory: context.layout.androidRuntime,
            environmentOverrides: swiftPM.commandEnvironment(
                context.taskEnvironment.merging(buildEnvironment) {
                    _, selected in selected
                }))
        let executable = URL(
            fileURLWithPath: swiftPM.executable(
                "nucleus-android-gfxstream-broker").string)
        guard FileManager.default.isExecutableFile(
            atPath: executable.path)
        else {
            throw WorkspaceFailure.message(
                "sanitized Android gfxstream broker is missing: "
                    + executable.path)
        }
        var environment = RuntimeSanitizer.address.runtimeEnvironment
        environment["ASAN_OPTIONS", default: ""] +=
            ":symbolize=1:fast_unwind_on_malloc=0"
            + ":handle_segv=2:handle_sigbus=2"
            + ":disable_coredump=0"
        guard let toolchain = context.environment["SWIFT_TOOLCHAIN"],
              !toolchain.isEmpty
        else {
            throw WorkspaceFailure.message(
                "SWIFT_TOOLCHAIN is required to run the sanitized "
                    + "gfxstream broker")
        }
        let symbolizer = URL(fileURLWithPath: toolchain)
            .appendingPathComponent("bin/llvm-symbolizer")
        guard FileManager.default.isExecutableFile(
            atPath: symbolizer.path)
        else {
            throw WorkspaceFailure.message(
                "the active Swift toolchain has no llvm-symbolizer: "
                    + symbolizer.path)
        }
        environment["ASAN_SYMBOLIZER_PATH"] = symbolizer.path
        environment["NUCLEUS_ADDRESS_SANITIZER_SCOPE"] =
            "broker,gfxstream-host"
        environment["LSAN_OPTIONS", default: ""] +=
            ":suppressions="
            + context.layout.tools.appendingPathComponent(
                "lsan-suppressions.txt").path
        return AndroidFrameworkBrokerLaunch(
            executable: executable,
            environment: environment)
    }

    private func buildAddressSanitizedGfxstreamHost() async throws -> URL {
        guard let toolchain = context.environment["SWIFT_TOOLCHAIN"],
              !toolchain.isEmpty
        else {
            throw WorkspaceFailure.message(
                "SWIFT_TOOLCHAIN is required to build the sanitized "
                    + "gfxstream host backend")
        }
        let build = context.layout.nativeSanitizerBuilds
            .appendingPathComponent("address", isDirectory: true)
            .appendingPathComponent(
                "android-framework-gfxstream-host",
                isDirectory: true)
        let source = context.root
            .appendingPathComponent(
                "third-party/gfxstream",
                isDirectory: true)
        let library = build.appendingPathComponent(
            "host/libgfxstream_backend.a")
        let environment = [
            "CC": "\(toolchain)/bin/clang",
            "CXX": "\(toolchain)/bin/clang++",
            "LDFLAGS":
                "-Wl,-rpath,\(toolchain)/lib"
                + (context.environment["LDFLAGS"].map { " \($0)" } ?? ""),
        ]
        let configured = FileManager.default.fileExists(
            atPath: build.appendingPathComponent("build.ninja").path)
        print(
            "==> build Android framework gfxstream host "
                + "sanitizer=address build=\(build.path)")
        try await context.run(
            "meson",
            ["setup"]
                + (configured ? ["--reconfigure"] : [])
                + [
                    build.path,
                    source.path,
                    "-Dbuildtype=debugoptimized",
                    "-Ddefault_library=static",
                    "-Db_sanitize=address",
                    "-Db_lundef=false",
                    "-Ddecoders=gles,vulkan,composer",
                    "-Dgfxstream-build=host",
                ],
            directory: source,
            environmentOverrides: environment)
        try await context.run(
            "meson",
            [
                "compile",
                "-C", build.path,
                "gfxstream_backend",
            ],
            environmentOverrides: environment)
        guard FileManager.default.isReadableFile(atPath: library.path) else {
            throw WorkspaceFailure.message(
                "sanitized gfxstream host backend is missing: "
                    + library.path)
        }
        return library
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
        var requiredTools = [
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
            "uname",
            "journalctl",
            "fsverity",
            "kitty",
            "tail",
        ]
        if brokerSanitizer != nil {
            requiredTools.append("coredumpctl")
        }
        for tool in requiredTools
        where resolveExecutable(tool, environment: context.environment) == nil {
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
        for module in androidFrameworkKernelModules {
            do {
                _ = try await context.run(
                    "modinfo",
                    [module],
                    capture: true)
            } catch {
                failures.append(
                    "kernel does not provide required Android module: \(module)")
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
        let kernelRelease: String?
        do {
            kernelRelease = try await context.run(
                "uname",
                ["--kernel-release"],
                capture: true
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            kernelRelease = nil
            failures.append("could not determine the running kernel release")
        }
        let hostKernelConfiguration = kernelRelease.flatMap {
            resolveHostKernelConfiguration(kernelRelease: $0)
        }
        if hostKernelConfiguration == nil {
            failures.append(
                "the running kernel configuration is unavailable; expected "
                    + "/proc/config.gz or /boot/config-\(kernelRelease ?? "<release>")")
        }
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
            let gidRange,
            let hostKernelConfiguration,
            let kittyExecutable = resolveExecutable(
                "kitty",
                environment: context.environment),
            let tailExecutable = resolveExecutable(
                "tail",
                environment: context.environment)
        else {
            throw WorkspaceFailure.message(
                "contained Android framework boot prerequisites failed:\n"
                    + failures.map { "  - \($0)" }.joined(separator: "\n"))
        }
        return AndroidFrameworkBootHost(
            userID: getuid(),
            groupID: getgid(),
            kernelConfiguration: hostKernelConfiguration,
            kittyExecutable: kittyExecutable,
            tailExecutable: tailExecutable,
            subordinateUID: uidRange.start,
            subordinateGID: gidRange.start,
            subordinateUIDCount: uidRange.count,
            subordinateGIDCount: gidRange.count)
    }
}

func androidFrameworkProductDefinitionDigest(
    androidRoot: URL
) throws -> ArtifactDigest {
    try aospProductDefinitionDigest(
        productSource: FilePath(
            androidRoot.appendingPathComponent(
                "aosp/device/nucleus/nucleus_x86_64",
                isDirectory: true
            ).path),
        sourceOverlays:
            AndroidRuntimeColliderRecipe.aospProductSourceOverlays(
                root: FilePath(androidRoot.path)))
}

struct AndroidFrameworkBrokerLaunch {
    let executable: URL
    let environment: [String: String]
}

private actor AndroidFrameworkBootSession {
    let context: WorkspaceContext
    let layout: AndroidFrameworkBootLayout
    let host: AndroidFrameworkBootHost
    let persistentData: URL
    let gfxstreamBrokerEnvironment: [String: String]
    var mounts = AndroidFrameworkMountLedger()
    var binderMounted = false
    var containerStarted = false
    var kernelLog: PseudoTerminalLog?
    var frameworkHealth = AndroidFrameworkHealthMonitor()
    var progress: AndroidFrameworkProgressRecorder?
    var trackedHostProcesses: [String: Int32] = [:]
    var binderDevices: [AndroidContainerDevice] = []
    let startedAt = Date()

    init(
        context: WorkspaceContext,
        layout: AndroidFrameworkBootLayout,
        host: AndroidFrameworkBootHost,
        dataProvenanceKey: String,
        gfxstreamBrokerEnvironment: [String: String]
    ) {
        self.context = context
        self.layout = layout
        self.host = host
        self.persistentData = layout.androidRoot
            .appendingPathComponent(".runtime-data", isDirectory: true)
            .appendingPathComponent(dataProvenanceKey, isDirectory: true)
        self.gfxstreamBrokerEnvironment = gfxstreamBrokerEnvironment
    }

    func initializeDiagnostics() throws {
        try FileManager.default.createDirectory(
            at: layout.diagnostics,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: layout.diagnosticTombstones,
            withIntermediateDirectories: true)
        progress = try AndroidFrameworkProgressRecorder(
            output: layout.progressLog)
        try progress?.record("session.initialized")
        for log in [
            layout.lxcLog,
            layout.androidKernelLog,
            layout.androidLog,
            layout.gfxstreamBrokerLog,
            layout.displayHostLog,
            layout.hostAuditLog,
            layout.gfxstreamCoreCollectorLog,
        ] {
            try Data().write(to: log, options: .atomic)
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
    }

    func prepare() async throws {
        for module in androidFrameworkKernelModules {
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
                try currentColliderAndroidPrivilegedExecutable(),
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
            throw WorkspaceFailure.message(
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
        try await qualifyPersistentDataFileSystem()
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

    private func qualifyPersistentDataFileSystem() async throws {
        let probe = persistentData.appendingPathComponent(
            ".nucleus-fsverity-probe")
        try Data("nucleus-fsverity\n".utf8).write(
            to: probe,
            options: .atomic)
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try await context.run(
                "fsverity",
                ["enable", probe.path])
            _ = try await context.run(
                "fsverity",
                ["digest", probe.path],
                capture: true)
        } catch {
            throw WorkspaceFailure.message(
                "persistent Android data filesystem does not support "
                    + "fs-verity: \(persistentData.path)")
        }
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

        let helperExecutable =
            try currentColliderAndroidPrivilegedExecutable()
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
                helperExecutable: helperExecutable,
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
            persistentData: layout.persistentDataMountPoint.path,
            gfxstreamSocketDirectory:
                layout.gfxstreamBrokerDirectory.path,
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
                ]),
            startHostHook: AndroidContainerMountHook(
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
                    androidCgroupDelegateCommandName,
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

    func runProcesses(
        timeoutSeconds: UInt32,
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async throws {
        try progress?.record("services.starting")
        let invocation = AndroidBPFBrokerInvocation(
            helperExecutable:
                try currentColliderAndroidPrivilegedExecutable(),
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
                output: .file(FilePath(
                    self.layout.gfxstreamBrokerLog.path))
            ) { gfxstreamBroker in
                try await gfxstreamBroker.waitUntilReady()
                guard let gfxstreamBrokerPID =
                    await gfxstreamBroker.processIdentifier
                else {
                    throw WorkspaceFailure.message(
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
                        ],
                        environmentOverrides: [
                            "XDG_RUNTIME_DIR": waylandRuntimeDirectory.path,
                        ],
                        output: .file(FilePath(
                            self.layout.displayHostLog.path))
                    ) { displayHost in
                        try await displayHost.waitUntilReady()
                        guard let displayHostPID =
                            await displayHost.processIdentifier
                        else {
                            throw WorkspaceFailure.message(
                                "Android display host started without a "
                                    + "process identifier")
                        }
                        await self.trackHostProcess(
                            "display-host",
                            processIdentifier: displayHostPID)
                        try await self.waitForDisplayHostReady(displayHost)
                        try await self.recordProgress("display-host.ready")
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
                                try await self.waitForBPFDelegation(
                                    broker: broker,
                                    container: container)
                                try await self.waitForFramework(
                                    container: container,
                                    displayHost: displayHost,
                                    gfxstreamBroker: gfxstreamBroker,
                                    timeoutSeconds: timeoutSeconds,
                                    waylandRuntimeDirectory:
                                        waylandRuntimeDirectory,
                                    waylandSocket: waylandSocket)
                            } catch {
                                await self.stopContainer()
                                throw error
                            }
                            await self.stopContainer()
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
                throw WorkspaceFailure.message(
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
                let primaryFailure = androidLXCPrimaryFailure(
                    logFile: layout.lxcLog)
                throw WorkspaceFailure.message(
                    "Android container exited during LXC setup, before BPF "
                        + "delegation (lxc-start status \(status))"
                        + (primaryFailure.map { "; primary LXC failure: \($0)" }
                            ?? "")
                        + "; "
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
        displayHost: RunningCommand,
        gfxstreamBroker: RunningCommand,
        timeoutSeconds: UInt32,
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async throws {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(Int64(timeoutSeconds)))
        while ContinuousClock.now < deadline {
            try kernelLog?.checkHealth()
            try frameworkHealth.check(
                kernelLog: layout.androidKernelLog,
                frameworkLog: layout.androidLog,
                diagnostics: layout.diagnostics)
            try await checkGraphicsServices(
                displayHost: displayHost,
                gfxstreamBroker: gfxstreamBroker)
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
                try progress?.record("android.logd.ready")
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
                    try await self.recordProgress("android.logcat.ready")
                    try await self.waitForFrameworkBoot(
                        container: container,
                        logcat: logcat,
                        displayHost: displayHost,
                        gfxstreamBroker: gfxstreamBroker,
                        deadline: deadline,
                        waylandRuntimeDirectory:
                            waylandRuntimeDirectory,
                        waylandSocket: waylandSocket)
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
        displayHost: RunningCommand,
        gfxstreamBroker: RunningCommand,
        deadline: ContinuousClock.Instant,
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async throws {
        var frameworkBooted = false
        var synchronizedFramePresented = false
        while ContinuousClock.now < deadline {
            try progress?.recordHostSample(
                cgroup: containerCgroup,
                processIdentifiers: trackedHostProcesses)
            try kernelLog?.checkHealth()
            try await checkGraphicsServices(
                displayHost: displayHost,
                gfxstreamBroker: gfxstreamBroker)
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
                if !frameworkBooted {
                    try progress?.record("android.boot-completed")
                }
                frameworkBooted = true
            }
            let presented =
                displayHostPresentedPhysicalFrame()
            if presented && !synchronizedFramePresented {
                synchronizedFramePresented = true
                try progress?.record(
                    "composer.frame-physically-presented")
            }
            if frameworkBooted && presented {
                try progress?.record("framework.ready")
                await captureCompositorScreenshot(
                    waylandRuntimeDirectory: waylandRuntimeDirectory,
                    waylandSocket: waylandSocket)
                await captureFrameworkScreenshot()
                return
            }
            try frameworkHealth.check(
                kernelLog: layout.androidKernelLog,
                frameworkLog: layout.androidLog,
                diagnostics: layout.diagnostics)
            try await ContinuousClock().sleep(for: .seconds(1))
        }
        throw WorkspaceFailure.message(
            frameworkBooted
                ? "Android framework booted without a synchronized, "
                    + "physically presented Composer3 frame; diagnostics: "
                    + layout.diagnostics.path
                : "Android framework did not publish sys.boot_completed=1; "
                + "diagnostics: \(layout.diagnostics.path)")
    }

    private func checkGraphicsServices(
        displayHost: RunningCommand,
        gfxstreamBroker: RunningCommand
    ) async throws {
        if !(await displayHost.isRunning) {
            let status = try await displayHost.wait().status
            throw WorkspaceFailure.message(
                "Android display host failed during framework boot "
                    + "(status \(status)); diagnostics: "
                    + layout.diagnostics.path)
        }
        if !(await gfxstreamBroker.isRunning) {
            let status = try await gfxstreamBroker.wait().status
            throw WorkspaceFailure.message(
                "Android gfxstream broker failed during framework boot "
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
            throw WorkspaceFailure.message(
                "Android gfxstream graphics synchronization failed; "
                    + "diagnostics: \(layout.diagnostics.path)")
        }
    }

    private func displayHostPresentedPhysicalFrame() -> Bool {
        guard let log = try? String(
            contentsOf: layout.displayHostLog,
            encoding: .utf8)
        else { return false }
        return log.contains(
            "\"stage\":\"presentation.committed\"")
            && log.contains("\"hasAcquireFence\":1")
            && log.contains(
                "\"stage\":\"presentation.physically-presented\"")
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
            let duration = AndroidFrameworkProgressRecorder.milliseconds(
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
            let duration = AndroidFrameworkProgressRecorder.milliseconds(
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

    private func captureFrameworkScreenshot() async {
        do {
            try await context.withRunningCommand(
                "sudo",
                [
                    "--non-interactive",
                    "lxc-attach",
                    "--name",
                    layout.name,
                    "--",
                    "/system/bin/screencap",
                    "-p",
                ],
                output: .file(FilePath(layout.androidScreenshot.path))
            ) { command in
                try await command.waitUntilReady()
                let status = try await command.wait().status
                guard status == 0 else {
                    throw WorkspaceFailure.message(
                        "Android screencap exited with status \(status)")
                }
            }
            try progress?.record(
                "android.screenshot.captured",
                fields: ["path": layout.androidScreenshot.path])
        } catch {
            try? progress?.record(
                "android.screenshot.failed",
                fields: ["error": "\(error)"])
        }
    }

    private func captureCompositorScreenshot(
        waylandRuntimeDirectory: URL,
        waylandSocket: String
    ) async {
        do {
            try await context.run(
                "grim",
                [layout.compositorScreenshot.path],
                environmentOverrides: [
                    "XDG_RUNTIME_DIR": waylandRuntimeDirectory.path,
                    "WAYLAND_DISPLAY": waylandSocket,
                ],
                timeoutSeconds: 10)
            try progress?.record(
                "compositor.screenshot.captured",
                fields: ["path": layout.compositorScreenshot.path])
        } catch {
            try? progress?.record(
                "compositor.screenshot.failed",
                fields: ["error": "\(error)"])
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
            layout.progressLog,
            layout.kittyLog,
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

func androidPersistentDataMountPoint(instance: URL) -> URL {
    instance.appendingPathComponent(
        "persistent-data",
        isDirectory: true)
}

func androidLXCPrimaryFailure(logFile: URL) -> String? {
    guard let contents = try? String(
        contentsOf: logFile,
        encoding: .utf8)
    else { return nil }
    let lines = contents.split(separator: "\n").map(String.init)
    if let hookLoaderFailure = lines.first(where: {
        $0.contains("produced output:")
            && $0.contains("error while loading shared libraries:")
    }) {
        return hookLoaderFailure
    }
    return lines.first { $0.contains(" ERROR ") }
}

private struct AndroidFrameworkBootLayout {
    let androidRoot: URL
    let name: String
    let runtime: URL
    let instance: URL
    let rootFileSystem: URL
    let persistentDataMountPoint: URL
    let binder: URL
    let bpfBrokerDirectory: URL
    let bpfBrokerSocket: URL
    let bpfHookExecutable: URL
    let gfxstreamBrokerDirectory: URL
    let gfxstreamBrokerSocket: URL
    let hostKernelConfigurationDirectory: URL
    let hostKernelConfiguration: URL
    let gfxstreamBrokerExecutable: URL
    let displayHostSocket: URL
    let displayHostExecutable: URL
    let swiftRuntime: URL
    let diagnostics: URL
    let configuration: URL
    let lxcLog: URL
    let androidKernelLog: URL
    let androidLog: URL
    let androidScreenshot: URL
    let compositorScreenshot: URL
    let gfxstreamBrokerLog: URL
    let displayHostLog: URL
    let progressLog: URL
    let kittyLog: URL
    let hostAuditLog: URL
    let collectorErrors: URL
    let gfxstreamCore: URL
    let gfxstreamCoreMetadata: URL
    let gfxstreamCoreCollectorLog: URL
    let containerTombstones: URL
    let diagnosticTombstones: URL
    let images: URL
    let provenance: URL
    let sourceProvenance: URL
    let patchManifest: URL
    let sourceLock: URL
    let productLock: URL
    let signingIdentity: URL
    let hostTools: URL
    let appArmorProfile: URL
    let seccompProfile: URL

    init(
        context: WorkspaceContext,
        gfxstreamBrokerExecutable: URL,
        displayHostExecutable: URL
    ) {
        name = "nucleus-framework-\(ProcessInfo.processInfo.processIdentifier)"
        runtime = URL(
            fileURLWithPath: "/run/nucleus/android",
            isDirectory: true)
        instance = runtime.appendingPathComponent(name, isDirectory: true)
        rootFileSystem = instance.appendingPathComponent(
            "rootfs",
            isDirectory: true)
        persistentDataMountPoint = androidPersistentDataMountPoint(
            instance: instance)
        binder = instance.appendingPathComponent(
            "binder",
            isDirectory: true)
        bpfBrokerDirectory = instance.appendingPathComponent(
            "bpf-broker",
            isDirectory: true)
        bpfBrokerSocket = bpfBrokerDirectory.appendingPathComponent(
            "broker.sock")
        bpfHookExecutable = bpfBrokerDirectory.appendingPathComponent(
            "collider-android-privileged")
        gfxstreamBrokerDirectory = instance.appendingPathComponent(
            "gfxstream-broker",
            isDirectory: true)
        gfxstreamBrokerSocket = gfxstreamBrokerDirectory
            .appendingPathComponent("gfxstream.sock")
        hostKernelConfigurationDirectory = instance.appendingPathComponent(
            "kernel-configuration",
            isDirectory: true)
        hostKernelConfiguration = hostKernelConfigurationDirectory
            .appendingPathComponent("host-kernel.config")
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
            ?? context.layout.androidFrameworkFallbackRun
        diagnostics = runDirectory.appendingPathComponent(
            "android-framework-boot",
            isDirectory: true)
        configuration = diagnostics.appendingPathComponent("lxc.conf")
        lxcLog = diagnostics.appendingPathComponent("lxc.log")
        androidKernelLog = diagnostics.appendingPathComponent(
            "android-kmsg.log")
        androidLog = diagnostics.appendingPathComponent(
            "android-logcat.log")
        androidScreenshot = diagnostics.appendingPathComponent(
            "android-screenshot.png")
        compositorScreenshot = diagnostics.appendingPathComponent(
            "compositor-screenshot.png")
        gfxstreamBrokerLog = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.log")
        displayHostLog = diagnostics.appendingPathComponent(
            "android-display-host.log")
        progressLog = diagnostics.appendingPathComponent(
            "android-progress.jsonl")
        kittyLog = diagnostics.appendingPathComponent(
            "android-boot-log-window.log")
        hostAuditLog = diagnostics.appendingPathComponent(
            "host-audit.log")
        collectorErrors = diagnostics.appendingPathComponent(
            "collector-errors.log")
        gfxstreamCore = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.core")
        gfxstreamCoreMetadata = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.coredump.json")
        gfxstreamCoreCollectorLog = diagnostics.appendingPathComponent(
            "android-gfxstream-broker-core-collector.log")
        diagnosticTombstones = diagnostics.appendingPathComponent(
            "tombstones",
            isDirectory: true)
        let android = context.layout.androidRuntime
        androidRoot = android
        self.gfxstreamBrokerExecutable = gfxstreamBrokerExecutable
        self.displayHostExecutable = displayHostExecutable
        images = android.appendingPathComponent(
            ".aosp-build/current/images",
            isDirectory: true)
        provenance = android.appendingPathComponent(
            ".aosp-build/current/signed/image-provenance.json")
        sourceProvenance = android.appendingPathComponent(
            ".aosp-source/.nucleus/source-provenance.json")
        patchManifest = android.appendingPathComponent("aosp/patches.json")
        sourceLock = android.appendingPathComponent("aosp.lock.json")
        productLock = android.appendingPathComponent(
            "aosp-product.lock.json")
        signingIdentity = android.appendingPathComponent(
            ".aosp-signing/local-development",
            isDirectory: true)
        hostTools = android.appendingPathComponent(
            ".aosp-build/current/out/host/linux-x86/bin",
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
    let libraryRootValues = try? libraryRoot.resourceValues(
        forKeys: [.isDirectoryKey])
    guard library.lastPathComponent == "libswiftCore.so",
        loaderSearchDirectory.lastPathComponent == "linux",
        swiftDirectory.lastPathComponent == "swift",
        FileManager.default.fileExists(
            atPath: library.path),
        libraryRootValues?.isDirectory == true
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
    let kernelConfiguration: URL
    let kittyExecutable: URL
    let tailExecutable: URL
    let subordinateUID: UInt32
    let subordinateGID: UInt32
    let subordinateUIDCount: UInt32
    let subordinateGIDCount: UInt32
}

struct AndroidBootLogWindowInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        kittyExecutable: String,
        tailExecutable: String,
        kernelLog: String,
        frameworkLog: String,
        brokerLog: String,
        progressLog: String
    ) {
        executable = kittyExecutable
        arguments = [
            "--class",
            "nucleus.android.boot-log",
            "--title",
            "Nucleus Android Boot Log",
            "--",
            tailExecutable,
            "--lines=200",
            "--follow=name",
            "--retry",
            kernelLog,
            frameworkLog,
            brokerLog,
            progressLog,
        ]
    }
}

private func resolveHostKernelConfiguration(
    kernelRelease: String
) -> URL? {
    guard !kernelRelease.isEmpty,
        !kernelRelease.contains("/"),
        !kernelRelease.contains("\0")
    else {
        return nil
    }
    for path in [
        "/proc/config.gz",
        "/boot/config-\(kernelRelease)",
    ] {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
            FileManager.default.isReadableFile(atPath: path),
            let data = try? Data(contentsOf: url),
            isValidHostKernelConfiguration(data)
        else {
            continue
        }
        return url
    }
    return nil
}

private func isValidHostKernelConfiguration(_ data: Data) -> Bool {
    guard !data.isEmpty else {
        return false
    }
    if data.count >= 2, data[data.startIndex] == 0x1f,
        data[data.index(after: data.startIndex)] == 0x8b
    {
        return true
    }
    guard let contents = String(data: data, encoding: .utf8) else {
        return false
    }
    return contents.split(whereSeparator: \.isNewline).contains {
        $0.hasPrefix("CONFIG_") || $0.hasPrefix("# CONFIG_")
    }
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
