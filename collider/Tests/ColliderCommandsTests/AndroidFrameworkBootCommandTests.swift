import Foundation
import Testing
@testable import ColliderCommands

@Test
func frameworkBootResolvesTheLoadedSwiftRuntime() throws {
    let runtime = try currentSwiftRuntime()

    #expect(
        FileManager.default.fileExists(
            atPath: runtime.loaderSearchDirectory
                .appendingPathComponent("libswiftCore.so")
                .path))
    for library in [
        "libc++.so.1",
        "libc++abi.so.1",
        "libunwind.so.1",
    ] {
        let path = runtime.loaderSearchDirectory
            .appendingPathComponent(library)
            .resolvingSymlinksInPath()
        #expect(
            path.path.hasPrefix(runtime.libraryRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}

@Test
func frameworkBootRunsLXCInADelegatedSystemScope() {
    let invocation = AndroidLXCStartInvocation(
        name: "nucleus-framework-1234",
        configuration: "/run/nucleus/lxc.conf",
        logFile: "/run/nucleus/lxc.log")

    #expect(invocation.executable == "sudo")
    #expect(invocation.arguments == [
        "--non-interactive",
        "systemd-run",
        "--scope",
        "--quiet",
        "--collect",
        "--unit",
        "nucleus-framework-1234",
        "--property",
        "Delegate=yes",
        "--",
        "lxc-start",
        "--foreground",
        "--name",
        "nucleus-framework-1234",
        "--rcfile",
        "/run/nucleus/lxc.conf",
        "--logfile",
        "/run/nucleus/lxc.log",
        "--logpriority",
        "TRACE",
    ])
}

@Test
func frameworkBootLogWindowFollowsBootDiagnosticStreams() {
    let invocation = AndroidBootLogWindowInvocation(
        kittyExecutable: "/opt/kitty",
        tailExecutable: "/usr/bin/tail",
        kernelLog: "/run/nucleus/android-kmsg.log",
        frameworkLog: "/run/nucleus/android-logcat.log",
        brokerLog: "/run/nucleus/android-gfxstream-broker.log",
        progressLog: "/run/nucleus/android-progress.jsonl")

    #expect(invocation.executable == "/opt/kitty")
    #expect(invocation.arguments == [
        "--class",
        "nucleus.android.boot-log",
        "--title",
        "Nucleus Android Boot Log",
        "--",
        "/usr/bin/tail",
        "--lines=200",
        "--follow=name",
        "--retry",
        "/run/nucleus/android-kmsg.log",
        "/run/nucleus/android-logcat.log",
        "/run/nucleus/android-gfxstream-broker.log",
        "/run/nucleus/android-progress.jsonl",
    ])
}

@Test
func frameworkBootDrainsEveryCompletedMountInReverseOrder() {
    let mounts = [
        URL(fileURLWithPath: "/run/nucleus/root"),
        URL(fileURLWithPath: "/run/nucleus/root/apex"),
        URL(fileURLWithPath: "/run/nucleus/root/apex/com.example"),
    ]
    var ledger = AndroidFrameworkMountLedger()
    for mount in mounts {
        ledger.record(mount)
    }

    #expect(ledger.takeInReverseOrder() == mounts.reversed())
    #expect(ledger.takeInReverseOrder().isEmpty)
}

@Test
func frameworkBootFailsOnARepeatedSurfaceFlingerCrash() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data((
        "<6>init: Service 'surfaceflinger' (pid 1) received SIGABRT\n"
    ).utf8).write(to: kernelLog)
    try Data().write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: kernelLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((
        "<6>init: Service 'surfaceflinger' (pid 2) received SIGABRT\n"
    ).utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootFailsWhenNativeFenceExportFails() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "SurfaceFlinger: failed to dup EGL native fence sync: 0x3000\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootFailsOnARepeatedZygoteKill() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data((
        "<6>init: Service 'zygote' (pid 230) received SIGKILL\n"
    ).utf8).write(to: kernelLog)
    try Data().write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: kernelLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((
        "<6>init: Service 'zygote' (pid 4575) received SIGKILL\n"
    ).utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootCountsEachZygoteProcessOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    let killed = "<6>init: Service 'zygote' (pid 230) received SIGKILL\n"
    try Data(killed.utf8).write(to: kernelLog)
    try Data().write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: kernelLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(killed.utf8))
    try handle.close()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
}

@Test
func frameworkBootFailsOnARepeatedSystemServerCrash() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "2026-07-25 18:54:02.192601  1000   335   335 E "
            + "AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: frameworkLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((
        "2026-07-25 18:54:06.901308  1000   515   515 E "
            + "AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main\n"
    ).utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootCountsEachSystemServerProcessOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    let fatal =
        "2026-07-25 18:54:02.192601  1000   335   335 E "
        + "AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main\n"
    try Data(fatal.utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: frameworkLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(fatal.utf8))
    try handle.close()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
}

@Test
func frameworkBootFailsOnARepeatedNativeSystemServerCrash() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "2026-07-25 22:11:10.084322  1000   336   336 F libc    : "
            + "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 336 "
            + "(system_server), pid 336 (system_server)\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: frameworkLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((
        "2026-07-25 22:11:13.003872  1000  4254  4254 F libc    : "
            + "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 4254 "
            + "(system_server), pid 4254 (system_server)\n"
    ).utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootDeduplicatesJavaAndNativeFatalForOneSystemServer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "2026-07-25 22:11:10.084300  1000   336   336 E "
            + "AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main\n"
            + "2026-07-25 22:11:10.084322  1000   336   336 F libc    : "
            + "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 336 "
            + "(system_server), pid 336 (system_server)\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
}

@Test
func frameworkBootIgnoresAnApplicationFatalException() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "2026-07-25 18:54:02.192601  10123   335   335 E "
            + "AndroidRuntime: FATAL EXCEPTION: main\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
}

@Test
func frameworkBootFailsOnARepeatedHomeLauncherCrash() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    let crash =
        "2026-07-26 22:01:23.012356  1000   352  4345 I "
        + "am_crash: [User=4543,PID=0,"
        + "Process Name=com.android.launcher3,Recoverable=0]\n"
    try Data(crash.utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)

    let handle = try FileHandle(forWritingTo: frameworkLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(crash.utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(
            kernelLog: kernelLog,
            frameworkLog: frameworkLog,
            diagnostics: directory)
    }
}

@Test
func frameworkBootFailsOnSecurityBoundaryHealthSignals() throws {
    let signals = [
        "root 4701 F zygote64: at com.android.internal.os.Zygote."
            + "nativeSpecializeAppProcess(Native method)",
        "E KeyStore: android.os.DeadObjectException: Transaction failed on "
            + "small parcel; remote process probably died",
        "W PackageManager: Failed to create app data for com.android.systemui, "
            + "but trying to recover",
        "E KeyStore: Cannot connect to Keystore daemon.",
        "E odsign: Could not create keystore key: Failed to initialize "
            + "keystore key.",
        "I system_server_start: [start_count=2,uptime=100,elapse_time=100]",
    ]

    for signal in signals {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "collider-framework-health-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kernelLog = directory.appendingPathComponent("android-kmsg.log")
        let frameworkLog = directory.appendingPathComponent(
            "android-logcat.log")
        try Data().write(to: kernelLog)
        try Data((signal + "\n").utf8).write(to: frameworkLog)

        var monitor = AndroidFrameworkHealthMonitor()
        #expect(throws: WorkspaceFailure.self) {
            try monitor.check(
                kernelLog: kernelLog,
                frameworkLog: frameworkLog,
                diagnostics: directory)
        }
    }
}

@Test
func frameworkBootAcceptsTheFirstSystemServerStart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-framework-health-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernelLog = directory.appendingPathComponent("android-kmsg.log")
    let frameworkLog = directory.appendingPathComponent("android-logcat.log")
    try Data().write(to: kernelLog)
    try Data((
        "I system_server_start: "
            + "[start_count=1,uptime=100,elapse_time=100]\n"
    ).utf8).write(to: frameworkLog)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(
        kernelLog: kernelLog,
        frameworkLog: frameworkLog,
        diagnostics: directory)
}

@Test
func frameworkBootAcceptsImagesBuiltFromTheCurrentInputs() {
    let fixture = frameworkBootFreshnessFixture()

    #expect(androidImageStalenessReason(
        image: fixture.image,
        source: fixture.source,
        patchManifest: fixture.patchManifest,
        patchDigests: ["patch-digest"],
        sourceManifestCommit: "manifest-commit",
        productLock: fixture.productLock,
        productTreeSHA256: "product-tree") == nil)
}

@Test
func frameworkBootRejectsImagesBuiltFromOlderSource() {
    let fixture = frameworkBootFreshnessFixture()
    let staleImage = AndroidImageProvenance(
        status: fixture.image.status,
        product: fixture.image.product,
        release: fixture.image.release,
        variant: fixture.image.variant,
        buildNumber: fixture.image.buildNumber,
        buildTimestamp: fixture.image.buildTimestamp,
        platformSDK: fixture.image.platformSDK,
        vendorAPILevel: fixture.image.vendorAPILevel,
        sourceManifestCommit: fixture.image.sourceManifestCommit,
        sourceBaseManifestSHA256: fixture.image.sourceBaseManifestSHA256,
        sourceManifestSHA256: "older-source",
        sourceForwardPatches: fixture.image.sourceForwardPatches,
        productTreeSHA256: fixture.image.productTreeSHA256,
        images: fixture.image.images)

    #expect(androidImageStalenessReason(
        image: staleImage,
        source: fixture.source,
        patchManifest: fixture.patchManifest,
        patchDigests: ["patch-digest"],
        sourceManifestCommit: "manifest-commit",
        productLock: fixture.productLock,
        productTreeSHA256: "product-tree")
        == "published images do not match the current AOSP source")
}

@Test
func frameworkBootRejectsStaleCanonicalPatchDigest() {
    let fixture = frameworkBootFreshnessFixture()

    #expect(androidImageStalenessReason(
        image: fixture.image,
        source: fixture.source,
        patchManifest: fixture.patchManifest,
        patchDigests: ["changed-patch"],
        sourceManifestCommit: "manifest-commit",
        productLock: fixture.productLock,
        productTreeSHA256: "product-tree")
        == "current AOSP source provenance contains a stale patch digest")
}

private func frameworkBootFreshnessFixture() -> (
    image: AndroidImageProvenance,
    source: AndroidSourceProvenance,
    patchManifest: AndroidPatchManifest,
    productLock: AndroidProductLock
) {
    let patch = AndroidForwardPatch(
        path: "aosp/patches/platform-example/0001-example.patch",
        sha256: "patch-digest")
    let stack = AndroidForwardPatchStack(
        repositoryPath: "platform/example",
        baseCommit: "base",
        patchedCommit: "patched",
        patchedTree: "tree",
        patches: [patch])
    let source = AndroidSourceProvenance(
        status: "materialized",
        manifestCommit: "manifest-commit",
        baseResolvedManifestSHA256: "base-manifest",
        resolvedManifestSHA256: "resolved-manifest",
        forwardPatches: [stack])
    let productLock = AndroidProductLock(
        product: "nucleus_x86_64",
        release: "cp2a",
        variant: "userdebug",
        buildNumber: "nucleus-android17-r1",
        buildTimestamp: 1_781_652_681,
        platformSDK: 37,
        vendorAPILevel: 202_604)
    return (
        AndroidImageProvenance(
            status: "signed",
            product: productLock.product,
            release: productLock.release,
            variant: productLock.variant,
            buildNumber: productLock.buildNumber,
            buildTimestamp: productLock.buildTimestamp,
            platformSDK: productLock.platformSDK,
            vendorAPILevel: productLock.vendorAPILevel,
            sourceManifestCommit: source.manifestCommit,
            sourceBaseManifestSHA256: source.baseResolvedManifestSHA256,
            sourceManifestSHA256: source.resolvedManifestSHA256,
            sourceForwardPatches: source.forwardPatches,
            productTreeSHA256: "product-tree",
            images: []),
        source,
        AndroidPatchManifest(repositories: [
            .init(path: stack.repositoryPath, patches: [patch.path])
        ]),
        productLock)
}
