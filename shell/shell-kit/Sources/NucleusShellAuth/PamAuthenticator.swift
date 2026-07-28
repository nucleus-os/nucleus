import Dispatch
import NucleusShellAuthWire
import NucleusShellProcessC
public import NucleusShellProduct
public import NucleusUI
#if canImport(Glibc)
import Glibc
#endif

@MainActor
public final class PamAuthenticator: LockAuthenticator {
    public enum PollSource: Sendable, Equatable {
        case response
        case process
    }

    public struct PollDescriptor: Sendable {
        public var source: PollSource
        public var fileDescriptor: Int32
    }

    public var service: String = "login"
    private let helperPath: String
    private let pollSetDidChange: @MainActor () -> Void
    private let attemptTimeoutNanoseconds: UInt64
    private let exitGraceNanoseconds: UInt64
    private let openPidFD: @Sendable (pid_t) -> Int32

    private struct Attempt {
        var responseFD: Int32
        var pidFD: Int32
        var pid: pid_t
        var parser = PamHelperWire.ResponseParser()
        var response: LockAuthenticationOutcome?
        var exitCode: Int32?
        var attemptDeadline: UInt64
        var exitDeadline: UInt64?
        var didKill = false
        var completion: (LockAuthenticationOutcome) -> Void
    }

    private var attempt: Attempt?

    public init(
        helperPath: String? = nil,
        attemptTimeoutNanoseconds: UInt64 = 30_000_000_000,
        exitGraceNanoseconds: UInt64 = 1_000_000_000,
        pidFDOpen: @escaping @Sendable (pid_t) -> Int32 = {
            nucleus_shell_pidfd_open($0)
        },
        pollSetDidChange: @escaping @MainActor () -> Void = {}
    ) {
        self.helperPath = helperPath ?? Self.defaultHelperPath()
        self.attemptTimeoutNanoseconds = attemptTimeoutNanoseconds
        self.exitGraceNanoseconds = exitGraceNanoseconds
        openPidFD = pidFDOpen
        self.pollSetDidChange = pollSetDidChange
    }

    public var pollDescriptors: [PollDescriptor] {
        guard let attempt else { return [] }
        return [
            PollDescriptor(source: .response, fileDescriptor: attempt.responseFD),
            PollDescriptor(source: .process, fileDescriptor: attempt.pidFD),
        ]
    }

    public func nanosecondsUntilDeadline(nowNanoseconds: UInt64) -> UInt64? {
        guard let attempt else { return nil }
        let deadline = min(attempt.attemptDeadline, attempt.exitDeadline ?? .max)
        return deadline > nowNanoseconds ? deadline - nowNanoseconds : 0
    }

    public func authenticate(
        password: consuming SecureBytes,
        completion: @escaping (LockAuthenticationOutcome) -> Void
    ) {
        guard attempt == nil else {
            completion(.unavailable("An attempt is already in progress"))
            return
        }
        let serviceBytes = Array(service.utf8)
        guard serviceBytes.count <= PamHelperWire.maximumServiceBytes else {
            completion(.unavailable("PAM service name is too long"))
            return
        }
        guard password.count <= PamHelperWire.maximumPasswordBytes else {
            completion(.rejected("Password too long"))
            return
        }

        var request: PamCredentialRequest?
        unsafe password.withUnsafeBytes {
            request = unsafe PamCredentialRequest(
                service: serviceBytes,
                password: $0)
        }
        guard var request = consume request else {
            completion(.unavailable("Authentication request is too large"))
            return
        }

        guard let spawned = spawnHelper() else {
            request.scrub()
            completion(.unavailable("Could not start the authentication helper"))
            return
        }
        let pidFD = openPidFD(spawned.pid)
        guard pidFD >= 0,
              nucleus_shell_set_nonblocking(spawned.responseFD) == 0
        else {
            if pidFD >= 0 { close(pidFD) }
            close(spawned.responseFD)
            close(spawned.requestFD)
            kill(spawned.pid, SIGKILL)
            reapOffMain(spawned.pid)
            request.scrub()
            completion(.unavailable("pidfd is unavailable"))
            return
        }

        let wrote = writeAtomic(request.storage, to: spawned.requestFD)
        request.scrub()
        close(spawned.requestFD)
        guard wrote else {
            close(spawned.responseFD)
            close(pidFD)
            kill(spawned.pid, SIGKILL)
            reapOffMain(spawned.pid)
            completion(.unavailable("Could not reach the authentication helper"))
            return
        }

        attempt = Attempt(
            responseFD: spawned.responseFD,
            pidFD: pidFD,
            pid: spawned.pid,
            attemptDeadline: clampedAdd(monotonicNow(), attemptTimeoutNanoseconds),
            completion: completion)
        pollSetDidChange()
    }

    public func process(
        _ source: PollSource,
        nowNanoseconds: UInt64
    ) {
        guard attempt != nil else { return }
        switch source {
        case .response:
            drainResponse(nowNanoseconds: nowNanoseconds)
        case .process:
            reapProcess()
        }
        finishIfReady()
    }

    public func processDeadline(nowNanoseconds: UInt64) {
        guard var current = attempt else { return }
        let expired = nowNanoseconds >= current.attemptDeadline
            || current.exitDeadline.map { nowNanoseconds >= $0 } == true
        guard expired else { return }
        if !current.didKill {
            _ = kill(current.pid, SIGKILL)
            current.didKill = true
        }
        current.response = .unavailable("Authentication helper timed out")
        attempt = current
        reapProcess()
        finishIfReady()
    }

    public func cancelPendingAttempt() {
        guard let current = attempt else { return }
        attempt = nil
        _ = kill(current.pid, SIGKILL)
        close(current.responseFD)
        close(current.pidFD)
        reapOffMain(current.pid)
        pollSetDidChange()
        current.completion(.unavailable("Authentication cancelled"))
    }

    public func failPendingAttempt(_ message: String) {
        failAndKill(message)
    }

    private func failAndKill(_ message: String) {
        guard var current = attempt else { return }
        current.response = .unavailable(message)
        if !current.didKill {
            _ = kill(current.pid, SIGKILL)
            current.didKill = true
        }
        attempt = current
        reapProcess()
        finishIfReady()
        pollSetDidChange()
    }

    private struct Spawned {
        var pid: pid_t
        var responseFD: Int32
        var requestFD: Int32
    }

    private func spawnHelper() -> Spawned? {
        var toHelper: [Int32] = [-1, -1]
        var fromHelper: [Int32] = [-1, -1]
        guard unsafe nucleus_shell_pipe(&toHelper) == 0 else { return nil }
        guard unsafe nucleus_shell_pipe(&fromHelper) == 0 else {
            close(toHelper[0]); close(toHelper[1])
            return nil
        }
        var actions = unsafe posix_spawn_file_actions_t()
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        unsafe posix_spawn_file_actions_adddup2(&actions, toHelper[0], STDIN_FILENO)
        unsafe posix_spawn_file_actions_adddup2(&actions, fromHelper[1], STDOUT_FILENO)
        for descriptor in [toHelper[1], fromHelper[0], toHelper[0], fromHelper[1]] {
            unsafe posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = unsafe [strdup(helperPath), nil]
        defer { unsafe argv.forEach { pointer in unsafe free(pointer) } }
        let result = argv.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return unsafe posix_spawn(
                &pid, helperPath, &actions, nil,
                UnsafeMutablePointer(mutating: base), environ)
        }
        close(toHelper[0])
        close(fromHelper[1])
        guard result == 0 else {
            close(toHelper[1]); close(fromHelper[0])
            return nil
        }
        return Spawned(pid: pid, responseFD: fromHelper[0], requestFD: toHelper[1])
    }

    private func drainResponse(nowNanoseconds: UInt64) {
        guard var current = attempt, current.response == nil else { return }
        var scratch = [UInt8](repeating: 0, count: 1024)
        drainLoop: while true {
            let count = scratch.withUnsafeMutableBytes {
                unsafe read(current.responseFD, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let state = scratch.withUnsafeBytes {
                    unsafe current.parser.append(
                        UnsafeRawBufferPointer(rebasing: $0[..<count]))
                }
                switch state {
                case .incomplete:
                    continue
                case .complete(let verdict, let message):
                    current.response = outcome(verdict, message: message)
                    current.exitDeadline = clampedAdd(
                        nowNanoseconds, exitGraceNanoseconds)
                    continue
                case .malformed:
                    current.response = .unavailable(
                        "Authentication helper sent an invalid response")
                    _ = kill(current.pid, SIGKILL)
                    current.didKill = true
                    break drainLoop
                }
            }
            if count == 0 {
                if current.response == nil {
                    current.response = .unavailable(
                        "Authentication helper did not respond")
                }
                break
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            current.response = .unavailable(
                "Authentication helper response failed")
            _ = kill(current.pid, SIGKILL)
            current.didKill = true
            break
        }
        attempt = current
    }

    private func reapProcess() {
        guard var current = attempt, current.exitCode == nil else { return }
        var exitCode: Int32 = -1
        let result = unsafe nucleus_shell_reap_nohang(current.pid, &exitCode)
        if result == 1 {
            current.exitCode = exitCode
        } else if result < 0 {
            current.exitCode = -1
        }
        attempt = current
    }

    private func finishIfReady() {
        guard let current = attempt,
              let response = current.response,
              let exitCode = current.exitCode
        else { return }
        attempt = nil
        close(current.responseFD)
        close(current.pidFD)
        pollSetDidChange()
        if case .accepted = response, exitCode != PamHelperWire.exitAccepted {
            current.completion(.unavailable("Authentication helper failed"))
        } else {
            current.completion(response)
        }
    }

    private func outcome(
        _ verdict: PamHelperWire.Outcome,
        message: String
    ) -> LockAuthenticationOutcome {
        switch verdict {
        case .accepted: .accepted
        case .rejected: .rejected(message.isEmpty ? "Incorrect password" : message)
        case .unavailable:
            .unavailable(message.isEmpty ? "Authentication unavailable" : message)
        }
    }

    private func writeAtomic(_ bytes: [UInt8], to fd: Int32) -> Bool {
        func attemptWrite() -> Int {
            bytes.withUnsafeBytes { unsafe write(fd, $0.baseAddress, $0.count) }
        }
        var count = attemptWrite()
        if count < 0 && errno == EINTR { count = attemptWrite() }
        return count == bytes.count
    }

    private func reapOffMain(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var exitCode: Int32 = -1
            while unsafe nucleus_shell_reap_nohang(pid, &exitCode) == 0 {
                usleep(1_000)
            }
        }
    }

    private func monotonicNow() -> UInt64 {
        var time = timespec()
        unsafe clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
    }

    private func clampedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }

    private static func defaultHelperPath() -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return unsafe readlink("/proc/self/exe", base, pointer.count - 1)
        }
        guard count > 0 else { return "NucleusShellPamHelper" }
        let executable = String(
            decoding: buffer[..<count].map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        guard let slash = executable.lastIndex(of: "/") else {
            return "NucleusShellPamHelper"
        }
        return String(executable[..<slash]) + "/../libexec/NucleusShellPamHelper"
    }
}
