// X11 display allocation + lazy socket binding.
//
// Picks a free :N display slot (scans /tmp/.X{n}-lock), creates the lock file with
// our PID, and binds both the abstract (@/tmp/.X11-unix/X{n}) and filesystem
// (/tmp/.X11-unix/X{n}) X11 sockets. The compositor loop polls both fds; the first
// client connection hands off to XwaylandProcess to spawn Xwayland. We never accept()
// — Xwayland inherits the listen fds via -listenfd.

import Glibc
import NucleusCompositorXcbC

private let maxDisplay: UInt8 = 32

@MainActor
final class XwaylandDisplay {
    let number: UInt8
    let lockPath: String
    let fsPath: String
    let abstractFd: Int32
    let fsFd: Int32
    private(set) var listening = false

    private init(number: UInt8, lockPath: String, fsPath: String, abstractFd: Int32, fsFd: Int32) {
        self.number = number
        self.lockPath = lockPath
        self.fsPath = fsPath
        self.abstractFd = abstractFd
        self.fsFd = fsFd
    }

    /// Scan for a free display slot, claim its lock, and bind both sockets.
    static func bind() -> XwaylandDisplay? {
        var n: UInt8 = 0
        while n < maxDisplay {
            defer { n += 1 }
            let lockPath = "/tmp/.X\(n)-lock"
            let lockFd = tryCreateLock(lockPath)
            if lockFd < 0 { continue }

            let fsPath = "/tmp/.X11-unix/X\(n)"
            _ = mkdir("/tmp/.X11-unix", 0o1777)
            _ = unlink(fsPath)  // remove stale fs socket (lock held ⇒ safe)

            guard let absFd = bindAbstract(fsPath) else {
                close(lockFd); _ = unlink(lockPath); continue
            }
            guard let fsFd = bindFilesystem(fsPath) else {
                close(absFd); close(lockFd); _ = unlink(lockPath); continue
            }
            close(lockFd)  // lock file remains; fd not needed
            return XwaylandDisplay(number: n, lockPath: lockPath, fsPath: fsPath, abstractFd: absFd, fsFd: fsFd)
        }
        return nil
    }

    func startListening() { listening = true }
    func stopListening() { listening = false }

    /// True if `fd` is one of our listen sockets and we were still listening (the
    /// first-client edge). Stops listening on that edge — the caller spawns Xwayland.
    func isFirstClient(_ fd: Int32) -> Bool {
        guard listening, fd == abstractFd || fd == fsFd else { return false }
        stopListening()
        return true
    }

    func shutdown() {
        stopListening()
        if abstractFd >= 0 { close(abstractFd) }
        if fsFd >= 0 { close(fsFd) }
        _ = unlink(fsPath)
        _ = unlink(lockPath)
    }
}

/// Atomically claim /tmp/.X{n}-lock. Returns the fd on success, -1 if held by a live
/// process, recovering from stale locks (ICCCM "%10d\n" PID format).
private func tryCreateLock(_ path: String) -> Int32 {
    while true {
        let fd = nucleus_open3(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o444)
        if fd >= 0 {
            // ICCCM lock format: 10-byte right-justified decimal PID + '\n'.
            let pidStr = String(getpid())
            let pad = pidStr.count < 10 ? String(repeating: " ", count: 10 - pidStr.count) : ""
            let bytes = Array((pad + pidStr + "\n").utf8)
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written != bytes.count {
                close(fd); _ = unlink(path); return -1
            }
            return fd
        }
        // EEXIST: probe the holder.
        let existing = nucleus_open2(path, O_RDONLY | O_CLOEXEC)
        if existing < 0 { return -1 }
        var buf = [UInt8](repeating: 0, count: 16)
        let n = buf.withUnsafeMutableBytes { read(existing, $0.baseAddress, $0.count) }
        close(existing)
        if n <= 0 { return -1 }
        let text = String(decoding: buf[0..<Int(n)], as: UTF8.self)
        let digits = String(text.filter { $0.isNumber })
        guard let pid = Int32(digits) else { return -1 }
        if kill(pid, 0) == 0 { return -1 }  // alive ⇒ held
        if unlink(path) != 0 { return -1 }  // stale ⇒ retry
    }
}

private func bindAbstract(_ fsPath: String) -> Int32? {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    if fd < 0 { return nil }
    let pathBytes = Array(fsPath.utf8)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // Abstract namespace: leading NUL then the path verbatim (offset 1 into sun_path).
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
    withUnsafeMutableBytes(of: &addr) { raw in
        for (i, b) in pathBytes.enumerated() { raw[pathOffset + 1 + i] = b }
    }
    let addrLen = socklen_t(pathOffset + 1 + pathBytes.count)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) == 0 }
    }
    if !ok || listen(fd, 1) != 0 { close(fd); return nil }
    return fd
}

private func bindFilesystem(_ fsPath: String) -> Int32? {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    if fd < 0 { return nil }
    let pathBytes = Array(fsPath.utf8)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
    withUnsafeMutableBytes(of: &addr) { raw in
        for (i, b) in pathBytes.enumerated() { raw[pathOffset + i] = b }
    }
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    if !ok || listen(fd, 1) != 0 { close(fd); return nil }
    return fd
}
