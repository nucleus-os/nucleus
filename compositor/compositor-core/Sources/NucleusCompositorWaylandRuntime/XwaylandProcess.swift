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
    private let launchConfiguration: XwaylandLaunchConfiguration
    private let runtimeDirectory: XwaylandRuntimeDirectory
    private let traceEnabled: Bool
    private(set) var pid: pid_t = 0
    private(set) var wmFd: Int32 = -1
    private(set) var displayPipeRd: Int32 = -1
    private(set) var tracePipeRd: Int32 = -1
    private var traceSink: XwaylandTraceSink?

    private var sockType: Int32 { Int32(SOCK_STREAM.rawValue) }
    private var cloexec: Int32 { Int32(SOCK_CLOEXEC.rawValue) }
    private var nonblock: Int32 { Int32(SOCK_NONBLOCK.rawValue) }

    init(
        host: RouterHost,
        executablePath: String,
        runtimeDirectory: XwaylandRuntimeDirectory,
        traceEnabled: Bool
    ) {
        self.host = host
        self.launchConfiguration = XwaylandLaunchConfiguration(
            executablePath: executablePath,
            displayNumber: 0)
        self.runtimeDirectory = runtimeDirectory
        self.traceEnabled = traceEnabled
    }

    /// Spawn Xwayland on `displayNum` using the pre-bound listen fds. Returns false on
    /// failure. On success the wl parent end is adopted as a router client; the WM fd +
    /// readiness pipe are owned here until readiness / teardown.
    func spawn(displayNum: UInt8, abstractFd: Int32, fsFd: Int32) -> Bool {
        guard pid == 0 else { return false }
        let ownedDescriptors = XwaylandOwnedFileDescriptors()
        let launch = XwaylandLaunchConfiguration(
            executablePath: launchConfiguration.executablePath,
            displayNumber: displayNum)
        guard launch.executableIsValid else { return false }

        var tracePair: [Int32] = [-1, -1]
        var useTrace = false
        if traceEnabled,
           unsafe pipe2(&tracePair, O_CLOEXEC | O_NONBLOCK) == 0
        {
            useTrace = true
            ownedDescriptors.insert(contentsOf: tracePair)
        }

        var wlPair: [Int32] = [-1, -1]
        if unsafe socketpair(AF_UNIX, sockType | cloexec | nonblock, 0, &wlPair) != 0 {
            return false
        }
        ownedDescriptors.insert(contentsOf: wlPair)
        var wmPair: [Int32] = [-1, -1]
        if unsafe socketpair(AF_UNIX, sockType | cloexec, 0, &wmPair) != 0 {
            return false
        }
        ownedDescriptors.insert(contentsOf: wmPair)
        var pipeFds: [Int32] = [-1, -1]
        if unsafe pipe2(&pipeFds, O_CLOEXEC) != 0 {
            return false
        }
        ownedDescriptors.insert(contentsOf: pipeFds)

        let wlChild = wlPair[1]
        let wmChild = wmPair[1]
        let dfChild = pipeFds[1]
        _ = nucleus_fd_clear_nonblock(wlChild)

        // The compositor is multithreaded by this point. Only posix_spawn may
        // cross the process boundary; a Swift fork child can deadlock before
        // exec on a runtime or allocator lock inherited from another thread.
        let sources = [wlChild, wmChild, dfChild, abstractFd, fsFd]
            + (useTrace ? [tracePair[1]] : [])
        var spawnSources: [Int32] = []
        for source in sources {
            let duplicate = fcntl(source, F_DUPFD_CLOEXEC, 64)
            guard duplicate >= 0 else {
                return false
            }
            spawnSources.append(duplicate)
            ownedDescriptors.insert(duplicate)
        }

        // Work from high-numbered duplicates so file actions cannot overwrite
        // another source while assigning the stable child descriptor contract.
        let childFDs: [Int32] = [3, 4, 5, 6, 7]
            + (useTrace ? [Int32(STDOUT_FILENO)] : [])
        var actions = unsafe posix_spawn_file_actions_t()
        guard unsafe posix_spawn_file_actions_init(&actions) == 0 else {
            return false
        }
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        for (source, target) in zip(spawnSources, childFDs) {
            guard unsafe posix_spawn_file_actions_adddup2(
                &actions, source, target) == 0
            else {
                return false
            }
        }
        let outputAction: Int32
        if useTrace {
            outputAction = 0
        } else {
            outputAction = "/dev/null".withCString {
                unsafe posix_spawn_file_actions_addopen(
                    &actions,
                    STDOUT_FILENO,
                    $0,
                    O_WRONLY,
                    0)
            }
        }
        guard outputAction == 0,
              unsafe posix_spawn_file_actions_adddup2(
                &actions, STDOUT_FILENO, STDERR_FILENO) == 0
        else {
            return false
        }
        for source in spawnSources {
            guard unsafe posix_spawn_file_actions_addclose(
                &actions, source) == 0
            else {
                return false
            }
        }
        let stableChildDescriptors = Set(
            childFDs + [Int32(STDERR_FILENO)])
        let inheritedDescriptors = [
            wlPair[0], wlPair[1],
            wmPair[0], wmPair[1],
            pipeFds[0], pipeFds[1],
            abstractFd, fsFd,
            tracePair[0], tracePair[1],
        ]
        for descriptor in Set(inheritedDescriptors)
        where descriptor >= 0
            && !stableChildDescriptors.contains(descriptor)
        {
            guard unsafe posix_spawn_file_actions_addclose(
                &actions, descriptor) == 0
            else {
                return false
            }
        }

        var attributes = posix_spawnattr_t()
        guard unsafe posix_spawnattr_init(&attributes) == 0 else {
            return false
        }
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        unsafe sigemptyset(&defaultSignals)
        unsafe sigemptyset(&emptyMask)
        for signal in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            unsafe sigaddset(&defaultSignals, signal)
        }
        guard unsafe posix_spawnattr_setsigdefault(
            &attributes, &defaultSignals) == 0,
              unsafe posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              unsafe posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
        else {
            return false
        }

        let argv = unsafe makeCStringVector(launch.arguments)
        defer { unsafe freeArgv(argv) }
        let environment = unsafe makeCStringVector(launch.environment)
        defer { unsafe freeArgv(environment) }
        var child = pid_t()
        let spawnResult = argv.withUnsafeBufferPointer { buffer in
            environment.withUnsafeBufferPointer { environmentBuffer in
                unsafe posix_spawn(
                    &child,
                    launch.executablePath,
                    &actions,
                    &attributes,
                    unsafe UnsafeMutablePointer(mutating: buffer.baseAddress!),
                    unsafe UnsafeMutablePointer(
                        mutating: environmentBuffer.baseAddress!))
            }
        }
        guard spawnResult == 0 else {
            return false
        }

        // Adopt only after spawn succeeds. This keeps every file-action failure
        // descriptor-only and prevents a failed launch from leaving a live
        // server-side Wayland client behind.
        guard unsafe host.runtime?.router.display.createClient(fd: wlPair[0]) != nil else {
            terminateFailedSpawn(child)
            return false
        }
        ownedDescriptors.relinquish(wlPair[0])

        // Parent: close child-only ends, keep the WM parent + readiness read.
        ownedDescriptors.close(wlChild)
        ownedDescriptors.close(wmPair[1])
        ownedDescriptors.close(pipeFds[1])
        pid = child
        wmFd = wmPair[0]
        ownedDescriptors.relinquish(wmFd)
        displayPipeRd = pipeFds[0]
        ownedDescriptors.relinquish(displayPipeRd)
        if useTrace {
            ownedDescriptors.close(tracePair[1])
            tracePipeRd = tracePair[0]
            ownedDescriptors.relinquish(tracePipeRd)
            traceSink = XwaylandTraceSink(
                directoryFD: runtimeDirectory.fileDescriptor)
        }
        return true
    }

    func readyFd() -> Int32? { displayPipeRd >= 0 ? displayPipeRd : nil }
    func traceFd() -> Int32? { tracePipeRd >= 0 ? tracePipeRd : nil }
    var traceDroppedBytes: UInt64 {
        traceSink?.droppedBytes ?? 0
    }

    func drainTrace() -> Bool {
        guard tracePipeRd >= 0, let traceSink else { return false }
        let remainsOpen = traceSink.drain(tracePipeRd)
        if !remainsOpen {
            _ = close(tracePipeRd)
            tracePipeRd = -1
        }
        return remainsOpen
    }

    /// Drain the readiness pipe and surrender the WM fd to the XWM (ownership
    /// transferred). Returns -1 if not ready.
    func takeWmFdOnReady() -> Int32 {
        guard displayPipeRd >= 0 else { return -1 }
        var buf = [UInt8](repeating: 0, count: 16)
        _ = buf.withUnsafeMutableBytes {
            unsafe read(displayPipeRd, $0.baseAddress, $0.count)
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
        if tracePipeRd >= 0 { close(tracePipeRd); tracePipeRd = -1 }
        traceSink = nil
        guard pid > 0 else { return }

        let child = pid
        pid = 0
        XwaylandChildReaper.terminate(child, gracefully: true)
    }

    private func terminateFailedSpawn(_ child: pid_t) {
        XwaylandChildReaper.terminate(child, gracefully: false)
    }

    @unsafe private func makeCStringVector(
        _ parts: [String]
    ) -> [UnsafeMutablePointer<CChar>?] {
        var argv: [UnsafeMutablePointer<CChar>?] = unsafe parts.map { unsafe strdup($0) }
        unsafe argv.append(nil)
        return unsafe argv
    }

    @unsafe private func freeArgv(_ argv: [UnsafeMutablePointer<CChar>?]) {
        var index = 0
        while unsafe index < argv.count {
            if let pointer = unsafe argv[index] {
                unsafe Glibc.free(pointer)
            }
            index += 1
        }
    }
}

enum XwaylandChildReaper {
    private enum PollResult {
        case pending
        case finished
    }

    /// Reaping is deliberately detached from the compositor main actor. Every
    /// wait is nonblocking, so an unresponsive child cannot stall protocol,
    /// input, rendering, or teardown ownership.
    @discardableResult
    nonisolated static func terminate(
        _ child: pid_t,
        gracefully: Bool
    ) -> Task<Void, Never> {
        Task.detached {
            if gracefully {
                _ = kill(child, SIGTERM)
                for _ in 0..<50 {
                    if unsafe poll(child) == .finished { return }
                    try? await ContinuousClock().sleep(
                        for: .milliseconds(10))
                }
            }

            _ = kill(child, SIGKILL)
            while unsafe poll(child) == .pending {
                try? await ContinuousClock().sleep(for: .milliseconds(10))
            }
        }
    }

    @unsafe private nonisolated static func poll(
        _ child: pid_t
    ) -> PollResult {
        while true {
            let result = waitpid(child, nil, WNOHANG)
            if result == child || (result == -1 && errno == ECHILD) {
                return .finished
            }
            if result == 0 {
                return .pending
            }
            if result == -1 && errno == EINTR {
                continue
            }
            return .finished
        }
    }
}

final class XwaylandOwnedFileDescriptors {
    private var descriptors: Set<Int32> = []

    func insert(_ descriptor: Int32) {
        if descriptor >= 0 {
            descriptors.insert(descriptor)
        }
    }

    func insert(contentsOf newDescriptors: [Int32]) {
        for descriptor in newDescriptors {
            insert(descriptor)
        }
    }

    func close(_ descriptor: Int32) {
        guard descriptors.remove(descriptor) != nil else { return }
        _ = Glibc.close(descriptor)
    }

    func relinquish(_ descriptor: Int32) {
        descriptors.remove(descriptor)
    }

    deinit {
        for descriptor in descriptors {
            _ = Glibc.close(descriptor)
        }
    }
}
