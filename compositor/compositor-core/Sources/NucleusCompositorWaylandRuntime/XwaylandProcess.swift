// Xwayland process lifecycle.
//
// On first X11 client connection it creates a Wayland socketpair + a WM socketpair +
// a readiness pipe, adopts the Wayland parent end as a router client, then fork()s and
// execvp's Xwayland with the other ends as -listenfd / -wm / -displayfd. The readiness
// pipe is polled by the compositor loop; when Xwayland writes the display number the
// WM fd is handed to the XWM.

import Glibc
import NucleusCompositorXcbC

@MainActor
final class XwaylandProcess {
    private(set) var pid: pid_t = 0
    private(set) var wmFd: Int32 = -1
    private(set) var displayPipeRd: Int32 = -1

    private var sockType: Int32 { Int32(SOCK_STREAM.rawValue) }
    private var cloexec: Int32 { Int32(SOCK_CLOEXEC.rawValue) }
    private var nonblock: Int32 { Int32(SOCK_NONBLOCK.rawValue) }

    /// Spawn Xwayland on `displayNum` using the pre-bound listen fds. Returns false on
    /// failure. On success the wl parent end is adopted as a router client; the WM fd +
    /// readiness pipe are owned here until readiness / teardown.
    func spawn(displayNum: UInt8, abstractFd: Int32, fsFd: Int32) -> Bool {
        guard pid == 0 else { return false }

        var wlPair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, sockType | cloexec | nonblock, 0, &wlPair) != 0 { return false }
        var wmPair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, sockType | cloexec, 0, &wmPair) != 0 {
            close(wlPair[0]); close(wlPair[1]); return false
        }
        var pipeFds: [Int32] = [-1, -1]
        if pipe2(&pipeFds, O_CLOEXEC) != 0 {
            close(wlPair[0]); close(wlPair[1]); close(wmPair[0]); close(wmPair[1]); return false
        }

        // Adopt the wl parent end as a router client (the router owns it on success;
        // libwayland destroys the client when Xwayland disconnects).
        guard RouterHost.shared.runtime?.router.display.createClient(fd: wlPair[0]) != nil else {
            close(wlPair[0]); close(wlPair[1]); close(wmPair[0]); close(wmPair[1])
            close(pipeFds[0]); close(pipeFds[1]); return false
        }
        let wlChild = wlPair[1]
        let wmChild = wmPair[1]
        let dfChild = pipeFds[1]

        // Pre-build argv + env C strings before fork — no Swift allocation in the child.
        let argv = buildArgv(displayNum: displayNum, wmChild: wmChild, dfChild: dfChild, absFd: abstractFd, fsFd: fsFd)
        let env = ChildEnv(waylandSocket: wlChild)

        let child = fork()
        if child < 0 {
            close(wlChild); close(wmPair[0]); close(wmPair[1]); close(pipeFds[0]); close(pipeFds[1])
            freeArgv(argv); env.free()
            return false
        }
        if child == 0 {
            childExec(wlChild: wlChild, wmChild: wmChild, dfChild: dfChild, absFd: abstractFd, fsFd: fsFd, argv: argv, env: env)
            _exit(127)  // unreachable on success
        }

        // Parent: close child-only ends, keep the WM parent + readiness read.
        close(wlChild)
        close(wmPair[1])
        close(pipeFds[1])
        freeArgv(argv); env.free()
        pid = child
        wmFd = wmPair[0]
        displayPipeRd = pipeFds[0]
        return true
    }

    func readyFd() -> Int32? { displayPipeRd >= 0 ? displayPipeRd : nil }

    /// Drain the readiness pipe and surrender the WM fd to the XWM (ownership
    /// transferred). Returns -1 if not ready.
    func takeWmFdOnReady() -> Int32 {
        guard displayPipeRd >= 0 else { return -1 }
        var buf = [UInt8](repeating: 0, count: 16)
        _ = buf.withUnsafeMutableBytes { read(displayPipeRd, $0.baseAddress, $0.count) }
        close(displayPipeRd)
        displayPipeRd = -1
        let fd = wmFd
        wmFd = -1
        return fd
    }

    func shutdown() {
        if displayPipeRd >= 0 { close(displayPipeRd); displayPipeRd = -1 }
        if wmFd >= 0 { close(wmFd); wmFd = -1 }
        if pid > 0 {
            _ = kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            pid = 0
        }
    }

    // ── child side ──────────────────────────────────────────────────────────────

    /// Pre-built env C strings, freed in the parent after fork.
    private final class ChildEnv {
        let nameWaylandSocket = strdup("WAYLAND_SOCKET")!
        let valWaylandSocket: UnsafeMutablePointer<CChar>
        let nameWaylandDebug = strdup("WAYLAND_DEBUG")!
        let valClient = strdup("client")!
        let nameDisplay = strdup("DISPLAY")!
        let logPath = strdup("/tmp/nucleus-xwayland.log")!

        init(waylandSocket: Int32) { valWaylandSocket = strdup(String(waylandSocket))! }
        func free() {
            Glibc.free(nameWaylandSocket); Glibc.free(valWaylandSocket)
            Glibc.free(nameWaylandDebug); Glibc.free(valClient)
            Glibc.free(nameDisplay); Glibc.free(logPath)
        }
    }

    private func childExec(
        wlChild: Int32, wmChild: Int32, dfChild: Int32, absFd: Int32, fsFd: Int32,
        argv: [UnsafeMutablePointer<CChar>?], env: ChildEnv
    ) {
        _ = nucleus_fd_clear_cloexec(wlChild)
        _ = nucleus_fd_clear_nonblock(wlChild)
        _ = nucleus_fd_clear_cloexec(wmChild)
        _ = nucleus_fd_clear_cloexec(dfChild)
        _ = nucleus_fd_clear_cloexec(absFd)
        _ = nucleus_fd_clear_cloexec(fsFd)

        setenv(env.nameWaylandSocket, env.valWaylandSocket, 1)
        setenv(env.nameWaylandDebug, env.valClient, 1)
        unsetenv(env.nameDisplay)

        // Redirect Xwayland stdout/stderr to a log file (a DRM tty session has no
        // recoverable console).
        let logFd = nucleus_open3(env.logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if logFd >= 0 {
            _ = dup2(logFd, 1)
            _ = dup2(logFd, 2)
            close(logFd)
        }
        argv.withUnsafeBufferPointer { buf in
            _ = execvp(buf.baseAddress!.pointee!, buf.baseAddress!)  // returns only on failure
        }
    }

    private func buildArgv(displayNum: UInt8, wmChild: Int32, dfChild: Int32, absFd: Int32, fsFd: Int32) -> [UnsafeMutablePointer<CChar>?] {
        let parts = [
            "Xwayland", "-rootless", "-terminate", "-core", "-verbose", "10",
            "-force-xrandr-emulation",
            "-listenfd", String(absFd), "-listenfd", String(fsFd),
            "-wm", String(wmChild), "-displayfd", String(dfChild),
            ":\(displayNum)",
        ]
        var argv: [UnsafeMutablePointer<CChar>?] = parts.map { strdup($0) }
        argv.append(nil)
        return argv
    }

    private func freeArgv(_ argv: [UnsafeMutablePointer<CChar>?]) {
        for p in argv { if let p { Glibc.free(p) } }
    }
}
