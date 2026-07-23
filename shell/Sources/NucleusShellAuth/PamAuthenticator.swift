import NucleusShellAuthWire
public import NucleusShellProduct
public import NucleusUI
#if canImport(Glibc)
import Glibc
#endif

/// Authenticates by spawning `nucleus-pam-helper` and reading its verdict.
///
/// The shell never loads a PAM module into its own address space. PAM `dlopen`s
/// whatever the system administrator configured, and those modules can crash or
/// call `exit()`; in the locker's process that would kill the locker, leaving the
/// compositor holding a permanently blank fail-closed session. Here the worst
/// case is a failed attempt.
///
/// `posix_spawn` rather than `fork` without `exec`: after a fork in a
/// multithreaded process the child may only call async-signal-safe functions,
/// and PAM goes well past that. The shell holds a Vulkan device and several
/// platform/runtime threads, so spawning a fresh image is the honest way to get a
/// single-threaded process to run PAM in.
///
/// Non-blocking by construction: the spawn returns immediately and the verdict
/// arrives on a pipe the shell's existing event loop polls. A lock screen that
/// froze for the duration of a deliberately-slow authentication would stop
/// blinking its caret and drop keystrokes.
@MainActor
public final class PamAuthenticator: LockAuthenticator {
    /// The PAM service to authenticate against. `login` is the conventional
    /// choice for a locker and exists on every system PAM is configured on.
    public var service: String = "login"

    /// Path to the helper. Resolved next to the running executable so a
    /// development build uses its own helper rather than an installed one.
    private let helperPath: String
    private let pollSetDidChange: @MainActor () -> Void

    private struct Attempt {
        var readFD: Int32
        var pid: pid_t
        var completion: (LockAuthenticationOutcome) -> Void
    }

    private var attempt: Attempt?

    public init(
        helperPath: String? = nil,
        pollSetDidChange: @escaping @MainActor () -> Void = {}
    ) {
        self.helperPath = helperPath ?? PamAuthenticator.defaultHelperPath()
        self.pollSetDidChange = pollSetDidChange
    }

    /// The fd carrying a verdict, for the host to poll. `nil` when idle.
    public var pendingFD: Int32? { attempt?.readFD }

    // MARK: - LockAuthenticator

    public func authenticate(
        password: consuming SecureBytes,
        completion: @escaping (LockAuthenticationOutcome) -> Void
    ) {
        guard attempt == nil else {
            // The caller already serializes attempts; refusing here too means a
            // second one can never silently displace the first's completion.
            completion(.unavailable("An attempt is already in progress"))
            return
        }
        guard password.count <= PamHelperWire.maximumPasswordBytes else {
            completion(.rejected("Password too long"))
            return
        }

        var request: [UInt8] = []
        PamHelperWire.encodeField(Array(service.utf8), into: &request)
        unsafe password.withUnsafeBytes { PamHelperWire.encodeField($0, into: &request) }

        guard let spawned = spawnHelper() else {
            scrub(&request)
            completion(.unavailable("Could not start the authentication helper"))
            return
        }

        let wrote = PamHelperWire.writeAll(request, to: spawned.writeFD)
        // The request held a copy of the credential; it does not outlive the write.
        scrub(&request)
        close(spawned.writeFD)

        guard wrote else {
            close(spawned.readFD)
            reap(spawned.pid)
            completion(.unavailable("Could not reach the authentication helper"))
            return
        }

        attempt = Attempt(readFD: spawned.readFD, pid: spawned.pid, completion: completion)
        pollSetDidChange()
    }

    /// Read the verdict and complete the attempt. Called by the host when
    /// `pendingFD` is readable, or when it decides to give up waiting.
    ///
    /// Reading here cannot block for long: the helper writes its whole response
    /// in one go immediately before exiting.
    public func drainPendingAttempt() {
        guard let attempt else { return }
        self.attempt = nil
        pollSetDidChange()

        let outcome = readOutcome(from: attempt.readFD)
        close(attempt.readFD)
        let status = reap(attempt.pid)

        // The exit status is the backstop: a helper killed by a signal, or one a
        // PAM module called `exit()` inside, must never read as success however
        // the pipe happened to end.
        if case .accepted = outcome, status != PamHelperWire.exitAccepted {
            attempt.completion(.unavailable("Authentication helper failed"))
            return
        }
        attempt.completion(outcome)
    }

    /// Abandon an attempt in flight — the lock was torn down, or the session
    /// ended. The helper is killed rather than left running with a credential.
    public func cancelPendingAttempt() {
        guard let attempt else { return }
        self.attempt = nil
        pollSetDidChange()
        kill(attempt.pid, SIGKILL)
        close(attempt.readFD)
        _ = reap(attempt.pid)
    }

    /// Fail a poll source that became invalid before producing a verdict.
    public func failPendingAttempt(_ message: String) {
        guard let attempt else { return }
        self.attempt = nil
        pollSetDidChange()
        kill(attempt.pid, SIGKILL)
        close(attempt.readFD)
        _ = reap(attempt.pid)
        attempt.completion(.unavailable(message))
    }

    // MARK: - Helper process

    private struct Spawned {
        var pid: pid_t
        var readFD: Int32
        var writeFD: Int32
    }

    private func spawnHelper() -> Spawned? {
        var toHelper: [Int32] = [-1, -1]
        var fromHelper: [Int32] = [-1, -1]
        guard pipe(&toHelper) == 0 else { return nil }
        guard pipe(&fromHelper) == 0 else {
            close(toHelper[0]); close(toHelper[1])
            return nil
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The helper reads the request on stdin and writes the verdict on stdout.
        posix_spawn_file_actions_adddup2(&actions, toHelper[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromHelper[1], 1)
        // The parent's ends must not survive into the child, or the read side
        // never sees EOF when the helper exits.
        posix_spawn_file_actions_addclose(&actions, toHelper[1])
        posix_spawn_file_actions_addclose(&actions, fromHelper[0])

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helperPath), nil]
        defer { argv.forEach { free($0) } }

        let result = argv.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return posix_spawn(
                &pid, helperPath, &actions, nil,
                UnsafeMutablePointer(mutating: base), environ)
        }

        close(toHelper[0])
        close(fromHelper[1])
        guard result == 0 else {
            close(toHelper[1]); close(fromHelper[0])
            return nil
        }
        return Spawned(pid: pid, readFD: fromHelper[0], writeFD: toHelper[1])
    }

    private func readOutcome(from fd: Int32) -> LockAuthenticationOutcome {
        guard let header = PamHelperWire.readExactly(1, from: fd),
              let outcome = PamHelperWire.Outcome(rawValue: header[0]),
              let length = PamHelperWire.readLength(
                from: fd, limit: PamHelperWire.maximumMessageBytes),
              let messageBytes = PamHelperWire.readExactly(length, from: fd)
        else {
            // A truncated or unreadable response is the machinery failing, not a
            // wrong password.
            return .unavailable("Authentication helper did not respond")
        }
        let message = String(decoding: messageBytes, as: UTF8.self)
        switch outcome {
        case .accepted: return .accepted
        case .rejected: return .rejected(message.isEmpty ? "Incorrect password" : message)
        case .unavailable:
            return .unavailable(message.isEmpty ? "Authentication unavailable" : message)
        }
    }

    @discardableResult
    private func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return -1 }
        }
        // Only a normal exit reports its own code; a signalled helper is a
        // failure whatever the signal was.
        guard status & 0x7f == 0 else { return -1 }
        return (status >> 8) & 0xff
    }

    private func scrub(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            explicit_bzero(base, raw.count)
        }
        bytes = []
    }

    /// Next to the running executable, so a build tree uses its own helper.
    private static func defaultHelperPath() -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return readlink("/proc/self/exe", base, pointer.count - 1)
        }
        guard count > 0 else { return "nucleus-pam-helper" }
        let executable = String(
            decoding: buffer[..<count].map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        guard let slash = executable.lastIndex(of: "/") else { return "nucleus-pam-helper" }
        return String(executable[..<slash]) + "/nucleus-pam-helper"
    }
}
