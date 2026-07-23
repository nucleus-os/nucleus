// Xwayland process lifecycle.
//
// On first X11 client connection it creates a Wayland socketpair + a WM socketpair +
// a readiness pipe, adopts the Wayland parent end as a router client, then posix_spawn()s
// Xwayland with the other ends as -listenfd / -wm / -displayfd. The readiness pipe is
// polled by the compositor loop; when Xwayland writes the display number the WM fd is
// handed to the XWM.

import Glibc
import NucleusCompositorXcbC
import WaylandServer

@MainActor
final class XwaylandProcess {
    private unowned let host: RouterHost
    private(set) var pid: pid_t = 0
    private(set) var wmFd: Int32 = -1
    private(set) var displayPipeRd: Int32 = -1

    private var sockType: Int32 { Int32(SOCK_STREAM.rawValue) }
    private var cloexec: Int32 { Int32(SOCK_CLOEXEC.rawValue) }
    private var nonblock: Int32 { Int32(SOCK_NONBLOCK.rawValue) }

    init(host: RouterHost) {
        self.host = host
    }

    /// Spawn Xwayland on `displayNum` using the pre-bound listen fds. Returns false on
    /// failure. On success the wl parent end is adopted as a router client; the WM fd +
    /// readiness pipe are owned here until readiness / teardown.
    func spawn(displayNum: UInt8, abstractFd: Int32, fsFd: Int32) -> Bool {
        guard pid == 0 else { return false }

        var wlPair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, sockType | cloexec | nonblock, 0, &wlPair) != 0 {
            return false
        }
        var wmPair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, sockType | cloexec, 0, &wmPair) != 0 {
            close(wlPair[0]); close(wlPair[1])
            return false
        }
        var pipeFds: [Int32] = [-1, -1]
        if pipe2(&pipeFds, O_CLOEXEC) != 0 {
            close(wlPair[0]); close(wlPair[1])
            close(wmPair[0]); close(wmPair[1])
            return false
        }

        // Adopt the wl parent end as a router client (the router owns it on success;
        // libwayland destroys the client when Xwayland disconnects).
        guard host.runtime?.router.display.createClient(fd: wlPair[0]) != nil else {
            close(wlPair[0]); close(wlPair[1])
            close(wmPair[0]); close(wmPair[1])
            close(pipeFds[0]); close(pipeFds[1])
            return false
        }
        let wlChild = wlPair[1]
        let wmChild = wmPair[1]
        let dfChild = pipeFds[1]
        _ = nucleus_fd_clear_nonblock(wlChild)

        // The compositor is multithreaded by this point. Only posix_spawn may
        // cross the process boundary; a Swift fork child can deadlock before
        // exec on a runtime or allocator lock inherited from another thread.
        let sources = [wlChild, wmChild, dfChild, abstractFd, fsFd]
        var spawnSources: [Int32] = []
        for source in sources {
            let duplicate = fcntl(source, F_DUPFD_CLOEXEC, 64)
            guard duplicate >= 0 else {
                spawnSources.forEach { _ = close($0) }
                closeLaunchFailure(
                    wlChild: wlChild,
                    wmPair: wmPair,
                    pipeFds: pipeFds)
                return false
            }
            spawnSources.append(duplicate)
        }
        defer { spawnSources.forEach { _ = close($0) } }

        // Work from high-numbered duplicates so file actions cannot overwrite
        // another source while assigning the stable child descriptor contract.
        let childFDs: [Int32] = [3, 4, 5, 6, 7]
        var actions = posix_spawn_file_actions_t()
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeLaunchFailure(
                wlChild: wlChild,
                wmPair: wmPair,
                pipeFds: pipeFds)
            return false
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, target) in zip(spawnSources, childFDs) {
            guard posix_spawn_file_actions_adddup2(
                &actions, source, target) == 0
            else {
                closeLaunchFailure(
                    wlChild: wlChild,
                    wmPair: wmPair,
                    pipeFds: pipeFds)
                return false
            }
        }
        let logAction = "/tmp/nucleus-xwayland.log".withCString {
            posix_spawn_file_actions_addopen(
                &actions,
                STDOUT_FILENO,
                $0,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o644)
        }
        guard logAction == 0,
              posix_spawn_file_actions_adddup2(
                &actions, STDOUT_FILENO, STDERR_FILENO) == 0
        else {
            closeLaunchFailure(
                wlChild: wlChild,
                wmPair: wmPair,
                pipeFds: pipeFds)
            return false
        }

        var attributes = posix_spawnattr_t()
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeLaunchFailure(
                wlChild: wlChild,
                wmPair: wmPair,
                pipeFds: pipeFds)
            return false
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptyMask)
        for signal in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        guard posix_spawnattr_setsigdefault(
            &attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
        else {
            closeLaunchFailure(
                wlChild: wlChild,
                wmPair: wmPair,
                pipeFds: pipeFds)
            return false
        }

        let argv = buildArgv(displayNum: displayNum)
        defer { freeArgv(argv) }
        var child = pid_t()
        let spawnResult = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(
                &child,
                "/usr/bin/env",
                &actions,
                &attributes,
                UnsafeMutablePointer(mutating: buffer.baseAddress!),
                Glibc.environ)
        }
        guard spawnResult == 0 else {
            closeLaunchFailure(
                wlChild: wlChild,
                wmPair: wmPair,
                pipeFds: pipeFds)
            return false
        }

        // Parent: close child-only ends, keep the WM parent + readiness read.
        close(wlChild)
        close(wmPair[1])
        close(pipeFds[1])
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
        _ = buf.withUnsafeMutableBytes {
            read(displayPipeRd, $0.baseAddress, $0.count)
        }
        close(displayPipeRd)
        displayPipeRd = -1
        let fd = wmFd
        wmFd = -1
        return fd
    }

    func shutdown() {
        if displayPipeRd >= 0 { close(displayPipeRd); displayPipeRd = -1 }
        if wmFd >= 0 { close(wmFd); wmFd = -1 }
        guard pid > 0 else { return }

        let child = pid
        pid = 0
        _ = kill(child, SIGTERM)
        for _ in 0..<50 {
            let result = waitpid(child, nil, WNOHANG)
            if result == child || (result == -1 && errno == ECHILD) {
                return
            }
            usleep(10_000)
        }
        _ = kill(child, SIGKILL)
        while waitpid(child, nil, 0) == -1, errno == EINTR {}
    }

    private func closeLaunchFailure(
        wlChild: Int32,
        wmPair: [Int32],
        pipeFds: [Int32]
    ) {
        close(wlChild)
        close(wmPair[0]); close(wmPair[1])
        close(pipeFds[0]); close(pipeFds[1])
    }

    private func buildArgv(
        displayNum: UInt8
    ) -> [UnsafeMutablePointer<CChar>?] {
        let parts = [
            "/usr/bin/env", "-u", "DISPLAY",
            "WAYLAND_SOCKET=3", "WAYLAND_DEBUG=client",
            "Xwayland", "-rootless", "-terminate", "-core", "-verbose", "10",
            "-force-xrandr-emulation",
            "-listenfd", "6", "-listenfd", "7",
            "-wm", "4", "-displayfd", "5",
            ":\(displayNum)",
        ]
        var argv: [UnsafeMutablePointer<CChar>?] = parts.map { strdup($0) }
        argv.append(nil)
        return argv
    }

    private func freeArgv(_ argv: [UnsafeMutablePointer<CChar>?]) {
        for pointer in argv {
            if let pointer { Glibc.free(pointer) }
        }
    }
}
