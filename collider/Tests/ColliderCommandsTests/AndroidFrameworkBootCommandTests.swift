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
