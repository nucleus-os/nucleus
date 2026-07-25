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
