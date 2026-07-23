import Glibc
import FoundationEssentials

// Compositor-side session-runtime isolation, Swift-owned. Production session
// construction lives in the launcher/user unit; this only validates a
// launcher-provided runtime dir or
// creates a direct-run fallback for the Wayland socket, and exports
// XDG_RUNTIME_DIR. The async runtime entry runs it before bring-up and tears it
// down after the reactor loop returns.

struct SessionIsolationConfig {
    var xdgRuntimeDir: String?
    var sessionRuntimeDir: String?
    var sessionId: String?
    var launchedSession: Bool

    /// Build the config from the process environment.
    static func fromEnvironment() -> SessionIsolationConfig {
        let sessionRuntimeDir = envString("NUCLEUS_SESSION_RUNTIME_DIR")
        let sessionId = envString("NUCLEUS_SESSION_ID")
        return SessionIsolationConfig(
            xdgRuntimeDir: envString("XDG_RUNTIME_DIR"),
            sessionRuntimeDir: sessionRuntimeDir,
            sessionId: sessionId,
            launchedSession: sessionId != nil || sessionRuntimeDir != nil)
    }
}

enum SessionIsolationError: Error, Equatable {
    case missingXdgRuntimeDir
    case invalidRuntimeDir
    case sessionRuntimeMismatch
    case invalidSessionId
    case notDirectory
    case mkdirFailed
    case chmodFailed
    case setenvFailed
}

final class SessionIsolation {
    let runtimeDir: String
    private let ownsRuntimeDir: Bool

    private init(runtimeDir: String, ownsRuntimeDir: Bool) {
        self.runtimeDir = runtimeDir
        self.ownsRuntimeDir = ownsRuntimeDir
    }

    /// Validate a launcher-provided runtime dir, or create + export a direct-run
    /// fallback.
    static func start(_ config: SessionIsolationConfig) throws -> SessionIsolation {
        if config.launchedSession {
            guard let runtimeDir = config.xdgRuntimeDir else {
                throw SessionIsolationError.missingXdgRuntimeDir
            }
            try validateLaunchedRuntime(runtimeDir, config.sessionRuntimeDir, config.sessionId)
            try ensureExistingDir(runtimeDir)
            logSession("using launcher-provided runtime=\(runtimeDir)")
            return SessionIsolation(runtimeDir: runtimeDir, ownsRuntimeDir: false)
        }

        let parent = resolveParentRuntimeDir(config.xdgRuntimeDir)
        let runtimeDir = try makeRuntimeDir(parent)
        guard runtimeDir.withCString({ setenv("XDG_RUNTIME_DIR", $0, 1) }) == 0 else {
            deleteTreeBestEffort(runtimeDir)
            throw SessionIsolationError.setenvFailed
        }
        logSession("created direct-run runtime=\(runtimeDir)")
        return SessionIsolation(runtimeDir: runtimeDir, ownsRuntimeDir: true)
    }

    /// Remove the runtime dir if this owns it (the direct-run fallback).
    func shutdown() {
        if ownsRuntimeDir {
            Self.deleteTreeBestEffort(runtimeDir)
        }
    }

    // MARK: - Helpers

    private static func resolveParentRuntimeDir(_ maybeRuntimeDir: String?) -> String {
        if let runtimeDir = maybeRuntimeDir, !runtimeDir.isEmpty {
            return runtimeDir
        }
        return "/run/user/\(getuid())"
    }

    private static func makeRuntimeDir(_ parentRuntimeDir: String) throws -> String {
        let path = "\(parentRuntimeDir)/nucleus-\(getpid())"
        if mkdirMode700(path) != 0 {
            if errno == EEXIST {
                deleteTreeBestEffort(path)
                if mkdirMode700(path) != 0 { throw SessionIsolationError.mkdirFailed }
            } else {
                throw SessionIsolationError.mkdirFailed
            }
        }
        return path
    }

    private static func validateLaunchedRuntime(
        _ runtimeDir: String, _ sessionRuntimeDir: String?, _ sessionId: String?
    ) throws {
        guard let first = runtimeDir.first, first == "/" else {
            throw SessionIsolationError.invalidRuntimeDir
        }
        if let expected = sessionRuntimeDir, runtimeDir != expected {
            throw SessionIsolationError.sessionRuntimeMismatch
        }

        let base = runtimeDir.split(separator: "/").last.map(String.init) ?? ""
        let prefix = "nucleus-"
        guard base.hasPrefix(prefix), base.count > prefix.count else {
            throw SessionIsolationError.invalidRuntimeDir
        }
        let runtimeSessionId = String(base.dropFirst(prefix.count))
        if let id = sessionId {
            if id.isEmpty || id.contains("/") { throw SessionIsolationError.invalidSessionId }
            if id != runtimeSessionId { throw SessionIsolationError.sessionRuntimeMismatch }
        }
    }

    private static func ensureExistingDir(_ path: String) throws {
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw SessionIsolationError.notDirectory }
        defer { close(fd) }
        if fchmod(fd, 0o700) != 0 { throw SessionIsolationError.chmodFailed }
    }

    private static func mkdirMode700(_ path: String) -> Int32 {
        path.withCString { mkdir($0, 0o700) }
    }

    private static func deleteTreeBestEffort(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func envString(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

private func logSession(_ message: String) {
    let line = "session runtime: \(message)\n"
    line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
}
