import AndroidRuntimeColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import NucleusAndroidContainerContract
import NucleusAndroidRuntimeCore
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
    let enableVulkanValidation: Bool
    let brokerSanitizer: AndroidFrameworkBrokerSanitizer?

    func run() async throws {
        guard getuid() != 0 else {
            throw AndroidRuntimeFailure(
                "run Collider as the workspace user, not as root")
        }
        try await ComponentRegistry(context: context).buildAndroidRuntimeHost()
        let brokerLaunch = try await buildBrokerLaunch()
        let swiftPM = try context.swiftPMInvocation()
        let installation = try await RuntimeInstaller(context: context).install(
            prefix: context.layout.installPrefix)
        let runDirectory =
            context.environment["NUCLEUS_RUN_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? context.layout.androidFrameworkFallbackRun
        let layout = AndroidRuntimeLayout(
            androidRoot: context.layout.androidRuntime,
            runDirectory: runDirectory,
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
        let frameworkSession = AndroidRuntimeSession(
            context: context,
            layout: layout,
            host: AndroidRuntimeHostConfiguration(
                userID: UInt32(host.userID),
                groupID: UInt32(host.groupID),
                kernelConfiguration: host.kernelConfiguration,
                subordinateUID: host.subordinateUID,
                subordinateGID: host.subordinateGID,
                subordinateUIDCount: host.subordinateUIDCount,
                subordinateGIDCount: host.subordinateGIDCount),
            privilegedHelperExecutable:
                swiftPM.executable(
                    "nucleus-android-runtime-privileged"
                ).string,
            swiftRuntime: try currentSwiftRuntime(),
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
            throw AndroidRuntimeFailure(
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
            throw AndroidRuntimeFailure(
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
                    throw AndroidRuntimeFailure(
                        "Nucleus session startup failed: "
                            + (reason.map(String.init(describing:))
                                ?? "reason \(message.detail)"))
                }
            }
            guard await session.isRunning else {
                throw AndroidRuntimeFailure(
                    "Nucleus session exited before Android startup "
                        + "(status \(await session.terminationStatus ?? -1))")
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        throw AndroidRuntimeFailure(
            "Nucleus session did not become ready before the startup deadline")
    }

    private func loadAndValidateImages(
        layout: AndroidRuntimeLayout
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
            throw AndroidRuntimeFailure(
                "signed Android image provenance does not satisfy the "
                    + "contained framework-boot contract")
        }
        for image in provenance.images {
            let path = layout.images.appendingPathComponent(image.name)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: path.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value
            guard size == image.size else {
                throw AndroidRuntimeFailure(
                    "\(image.name) size does not match image provenance")
            }
            let digest = try ArtifactHasher.digest(
                file: FilePath(path.path)
            ).sha256Hex
            guard digest == image.sha256 else {
                throw AndroidRuntimeFailure(
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
        layout: AndroidRuntimeLayout
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
            throw AndroidRuntimeFailure(
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
            throw AndroidRuntimeFailure(
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
            throw AndroidRuntimeFailure(
                "SWIFT_TOOLCHAIN is required to run the sanitized "
                    + "gfxstream broker")
        }
        let symbolizer = URL(fileURLWithPath: toolchain)
            .appendingPathComponent("bin/llvm-symbolizer")
        guard FileManager.default.isExecutableFile(
            atPath: symbolizer.path)
        else {
            throw AndroidRuntimeFailure(
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
            throw AndroidRuntimeFailure(
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
            throw AndroidRuntimeFailure(
                "sanitized gfxstream host backend is missing: "
                    + library.path)
        }
        return library
    }

    private func validateHost(
        layout: AndroidRuntimeLayout
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
        for module in androidRuntimeRequiredKernelModules {
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
            throw AndroidRuntimeFailure(
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

func currentSwiftRuntime() throws -> AndroidSwiftRuntime {
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
        throw AndroidRuntimeFailure(
            "the dynamic loader returned an invalid Swift runtime path: "
                + library.path)
    }
    return try AndroidSwiftRuntime(
        libraryRoot: libraryRoot,
        loaderSearchDirectory: loaderSearchDirectory)
    #else
    throw AndroidRuntimeFailure(
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

extension ArtifactDigest {
    fileprivate var sha256Hex: String {
        String(description.dropFirst("sha256:".count))
    }
}
