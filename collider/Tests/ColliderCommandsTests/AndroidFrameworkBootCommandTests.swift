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
    let log = directory.appendingPathComponent("android-kmsg.log")
    try Data((
        "<6>init: Service 'surfaceflinger' (pid 1) received SIGABRT\n"
    ).utf8).write(to: log)

    var monitor = AndroidFrameworkHealthMonitor()
    try monitor.check(log: log, diagnostics: directory)

    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((
        "<6>init: Service 'surfaceflinger' (pid 2) received SIGABRT\n"
    ).utf8))
    try handle.close()
    #expect(throws: WorkspaceFailure.self) {
        try monitor.check(log: log, diagnostics: directory)
    }
}
