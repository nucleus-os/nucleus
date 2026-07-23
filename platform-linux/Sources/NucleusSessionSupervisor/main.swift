import FoundationEssentials
import Glibc
import NucleusLinuxSession
import NucleusLinuxSessionC

private enum SupervisorFailure: Error, CustomStringConvertible {
    case usage(String)
    case system(String, Int32)
    case childExited(SessionProcessRole, Int32)
    case readinessClosed(SessionProcessRole)
    case invalidReadiness(SessionProcessRole)
    case startupTimedOut(SessionProcessRole)
    case interrupted(Int32)

    var description: String {
        switch self {
        case .usage(let message): message
        case .system(let operation, let error):
            "\(operation) failed: errno \(error)"
        case .childExited(let role, let status):
            "\(role) exited before the session became ready (status \(status))"
        case .readinessClosed(let role):
            "\(role) closed its readiness channel without reporting readiness"
        case .invalidReadiness(let role):
            "\(role) sent an invalid readiness record"
        case .startupTimedOut(let role):
            "\(role) did not become ready before the startup deadline"
        case .interrupted(let signal):
            "session received signal \(signal)"
        }
    }
}

private struct SupervisorArguments {
    var statusFile: String?
    var configuration: SessionConfiguration
    var shell: String
    var compositor: [String]
    var startupTimeoutMilliseconds: Int32 = 30_000

    static func parse(_ arguments: [String]) throws -> SupervisorArguments {
        var statusFile: String?
        var configuration = SessionConfiguration.defaults
        var shell: String?
        var startupTimeoutMilliseconds: Int32 = 30_000
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--status-file":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                statusFile = arguments[index]
            case "--shell":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                shell = arguments[index]
            case "--configuration":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                do {
                    configuration = try SessionConfiguration(
                        hexEncoded: arguments[index])
                } catch {
                    throw SupervisorFailure.usage(
                        "invalid session configuration: \(error)")
                }
            case "--startup-timeout-seconds":
                guard index + 1 < arguments.count,
                      let seconds = Int32(arguments[index + 1]),
                      seconds > 0,
                      seconds <= 600
                else {
                    throw SupervisorFailure.usage(
                        "--startup-timeout-seconds must be between 1 and 600")
                }
                index += 1
                startupTimeoutMilliseconds = seconds * 1_000
            case "--":
                let compositor = Array(arguments.dropFirst(index + 1))
                guard let shell, !shell.isEmpty, !compositor.isEmpty else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                return SupervisorArguments(
                    statusFile: statusFile,
                    configuration: configuration,
                    shell: shell,
                    compositor: compositor,
                    startupTimeoutMilliseconds: startupTimeoutMilliseconds)
            case "-h", "--help":
                throw SupervisorFailure.usage(Self.usage)
            default:
                throw SupervisorFailure.usage(Self.usage)
            }
            index += 1
        }
        throw SupervisorFailure.usage(Self.usage)
    }

    static let usage = """
    usage: nucleus-session-supervisor [--status-file PATH] [--configuration HEX] [--startup-timeout-seconds N] --shell PATH -- COMMAND [ARGS...]
    """
}

private struct SupervisedChild {
    let role: SessionProcessRole
    let processID: pid_t
    let readinessDescriptor: Int32
}

private struct UnexpectedSessionExit {
    let role: SessionProcessRole
    let status: Int32
}

private struct SessionStatusPublisher {
    let path: String?

    func publish(_ message: SessionReadinessMessage) throws {
        guard let path else { return }
        try Data(message.encoded).write(
            to: URL(fileURLWithPath: path),
            options: .atomic)
    }
}

private final class SessionSupervisor {
    private static let childReadinessDescriptor: Int32 = 198
    private static let childConfigurationDescriptor: Int32 = 197

    private let arguments: SupervisorArguments
    private let statusPublisher: SessionStatusPublisher
    private let signalDescriptor: Int32

    init(arguments: SupervisorArguments) throws {
        self.arguments = arguments
        statusPublisher = SessionStatusPublisher(path: arguments.statusFile)

        let descriptor = nucleus_session_create_signal_fd()
        guard descriptor >= 0 else {
            throw SupervisorFailure.system("signalfd", errno)
        }
        signalDescriptor = descriptor
    }

    deinit { _ = close(signalDescriptor) }

    func run() -> Int32 {
        var children: [SupervisedChild] = []
        do {
            let compositor = try spawn(
                role: .compositor,
                command: arguments.compositor)
            children.append(compositor)
            let compositorReady = try waitForReadiness(
                compositor,
                milestone: .compositorReady,
                monitoring: children)
            try statusPublisher.publish(compositorReady)
            log("compositor ready pid=\(compositor.processID)")

            let shell = try spawn(role: .shell, command: [arguments.shell])
            children.append(shell)
            let shellReady = try waitForReadiness(
                shell,
                milestone: .shellReady,
                monitoring: children)
            try statusPublisher.publish(shellReady)
            log("shell ready pid=\(shell.processID)")

            let unexpectedExit = try waitForSessionExit(children)
            let reason: SessionFailureReason = unexpectedExit.role == .compositor
                ? .compositorExitedAfterReady
                : .shellExitedAfterReady
            try statusPublisher.publish(SessionReadinessMessage(
                role: .supervisor,
                milestone: .failed,
                detail: reason.rawValue))
            if unexpectedExit.role == .shell, unexpectedExit.status == 0 {
                log("shell exited while compositor was still running")
                return 1
            }
            return unexpectedExit.status
        } catch SupervisorFailure.interrupted(let signal) {
            try? statusPublisher.publish(SessionReadinessMessage(
                role: .supervisor,
                milestone: .terminating,
                detail: signal))
            terminate(children)
            return 128 + signal
        } catch {
            log("\(error)")
            try? statusPublisher.publish(SessionReadinessMessage(
                role: .supervisor,
                milestone: .failed,
                detail: failureReason(error).rawValue))
            terminate(children)
            return 1
        }
    }

    private func failureReason(_ error: any Error) -> SessionFailureReason {
        guard let failure = error as? SupervisorFailure else {
            return .internalFailure
        }
        switch failure {
        case .childExited(.compositor, _):
            return .compositorExitedBeforeReady
        case .childExited(.shell, _):
            return .shellExitedBeforeReady
        case .readinessClosed(.compositor):
            return .compositorReadinessClosed
        case .readinessClosed(.shell):
            return .shellReadinessClosed
        case .invalidReadiness(.compositor):
            return .compositorReadinessInvalid
        case .invalidReadiness(.shell):
            return .shellReadinessInvalid
        case .startupTimedOut(.compositor):
            return .compositorStartupTimedOut
        case .startupTimedOut(.shell):
            return .shellStartupTimedOut
        case .usage, .system, .interrupted,
             .childExited(.supervisor, _),
             .readinessClosed(.supervisor),
             .invalidReadiness(.supervisor),
             .startupTimedOut(.supervisor):
            return .internalFailure
        }
    }

    private func spawn(
        role: SessionProcessRole,
        command: [String]
    ) throws -> SupervisedChild {
        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeDescriptors) == 0 else {
            throw SupervisorFailure.system("pipe", errno)
        }
        guard fcntl(pipeDescriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipeDescriptors[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipeDescriptors[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(pipeDescriptors[1], F_SETFL, O_NONBLOCK) == 0
        else {
            let error = errno
            _ = close(pipeDescriptors[0])
            _ = close(pipeDescriptors[1])
            throw SupervisorFailure.system("readiness pipe flags", error)
        }
        let readDescriptor = pipeDescriptors[0]
        let writeDescriptor = pipeDescriptors[1]
        var configurationDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&configurationDescriptors) == 0 else {
            let error = errno
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            throw SupervisorFailure.system("configuration pipe", error)
        }
        guard fcntl(configurationDescriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(configurationDescriptors[1], F_SETFD, FD_CLOEXEC) == 0
        else {
            let error = errno
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            _ = close(configurationDescriptors[0])
            _ = close(configurationDescriptors[1])
            throw SupervisorFailure.system("configuration pipe flags", error)
        }

        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            _ = close(configurationDescriptors[0])
            _ = close(configurationDescriptors[1])
            throw SupervisorFailure.system("posix_spawn initialization", errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawn_file_actions_adddup2(
            &actions,
            writeDescriptor,
            Self.childReadinessDescriptor) == 0,
              posix_spawn_file_actions_addclose(
                &actions,
                readDescriptor) == 0,
              posix_spawn_file_actions_addclose(
                &actions,
                writeDescriptor) == 0,
              posix_spawn_file_actions_adddup2(
                &actions,
                configurationDescriptors[0],
                Self.childConfigurationDescriptor) == 0,
              posix_spawn_file_actions_addclose(
                &actions,
                configurationDescriptors[0]) == 0,
              posix_spawn_file_actions_addclose(
                &actions,
                configurationDescriptors[1]) == 0
        else {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            _ = close(configurationDescriptors[0])
            _ = close(configurationDescriptors[1])
            throw SupervisorFailure.system("readiness descriptor actions", errno)
        }

        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptyMask)
        for signal in [SIGCHLD, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        guard posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETSIGDEF
                        | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            _ = close(configurationDescriptors[0])
            _ = close(configurationDescriptors[1])
            throw SupervisorFailure.system("child signal attributes", errno)
        }

        let childArguments = [command[0],
            SessionProcessRole.argument,
            String(role.rawValue),
            SessionReadinessReporter.descriptorArgument,
            String(Self.childReadinessDescriptor),
            SessionConfiguration.descriptorArgument,
            String(Self.childConfigurationDescriptor),
        ] + command.dropFirst()
        let storage: [UnsafeMutablePointer<CChar>?] =
            childArguments.map { strdup($0) } + [nil]
        defer { storage.forEach { free($0) } }
        var processID = pid_t()
        let result = storage.withUnsafeBufferPointer { buffer in
            posix_spawnp(
                &processID,
                buffer[0]!,
                &actions,
                &attributes,
                UnsafeMutablePointer(mutating: buffer.baseAddress!),
                environ)
        }
        _ = close(writeDescriptor)
        _ = close(configurationDescriptors[0])
        guard result == 0 else {
            _ = close(readDescriptor)
            _ = close(configurationDescriptors[1])
            throw SupervisorFailure.system(
                "launching \(command[0])",
                Int32(result))
        }
        do {
            try Self.writeAll(
                arguments.configuration.encoded,
                to: configurationDescriptors[1])
        } catch {
            _ = close(configurationDescriptors[1])
            _ = close(readDescriptor)
            _ = kill(-processID, SIGKILL)
            while waitpid(processID, nil, 0) < 0, errno == EINTR {}
            throw error
        }
        _ = close(configurationDescriptors[1])
        log("spawned \(role) pid=\(processID)")
        return SupervisedChild(
            role: role,
            processID: processID,
            readinessDescriptor: readDescriptor)
    }

    private func waitForReadiness(
        _ child: SupervisedChild,
        milestone: SessionMilestone,
        monitoring children: [SupervisedChild]
    ) throws -> SessionReadinessMessage {
        defer { _ = close(child.readinessDescriptor) }
        let deadline = Self.monotonicNanoseconds()
            + UInt64(arguments.startupTimeoutMilliseconds) * 1_000_000
        while true {
            var descriptors = [
                pollfd(
                    fd: child.readinessDescriptor,
                    events: Int16(POLLIN),
                    revents: 0),
                pollfd(
                    fd: signalDescriptor,
                    events: Int16(POLLIN),
                    revents: 0),
            ]
            let now = Self.monotonicNanoseconds()
            guard now < deadline else {
                throw SupervisorFailure.startupTimedOut(child.role)
            }
            let remainingMilliseconds = max(
                1,
                Int32(min(
                    UInt64(Int32.max),
                    (deadline - now + 999_999) / 1_000_000)))
            let pollResult = poll(
                &descriptors,
                nfds_t(descriptors.count),
                remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SupervisorFailure.system("readiness poll", errno)
            }
            if pollResult == 0 {
                throw SupervisorFailure.startupTimedOut(child.role)
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                try processSignals(monitoring: children)
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](
                    repeating: 0,
                    count: SessionReadinessMessage.encodedSize)
                let count = read(
                    child.readinessDescriptor,
                    &bytes,
                    bytes.count)
                guard count == bytes.count,
                      let message = SessionReadinessMessage(encoded: bytes),
                      message.role == child.role,
                      message.milestone == milestone
                else {
                    throw SupervisorFailure.invalidReadiness(child.role)
                }
                return message
            }
            if descriptors[0].revents
                & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
            {
                throw SupervisorFailure.readinessClosed(child.role)
            }
        }
    }

    private func waitForSessionExit(_ children: [SupervisedChild]) throws
        -> UnexpectedSessionExit
    {
        while true {
            var descriptor = pollfd(
                fd: signalDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            let result = poll(&descriptor, 1, -1)
            if result < 0 {
                if errno == EINTR { continue }
                throw SupervisorFailure.system("session wait", errno)
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else { continue }
            let signals = drainSignals()
            if let signal = signals.first(where: {
                $0 == SIGINT || $0 == SIGTERM || $0 == SIGHUP
            }) {
                throw SupervisorFailure.interrupted(signal)
            }
            for child in children {
                var waitStatus: Int32 = 0
                let waited = waitpid(child.processID, &waitStatus, WNOHANG)
                guard waited == child.processID else { continue }
                let status = Self.exitStatus(waitStatus)
                // Include the exited root so any descendants that remained in
                // its process group are also retired.
                terminate(children)
                return UnexpectedSessionExit(
                    role: child.role,
                    status: status)
            }
        }
    }

    private func processSignals(monitoring children: [SupervisedChild]) throws {
        let signals = drainSignals()
        if let signal = signals.first(where: {
            $0 == SIGINT || $0 == SIGTERM || $0 == SIGHUP
        }) {
            throw SupervisorFailure.interrupted(signal)
        }
        guard signals.contains(SIGCHLD) else { return }
        for child in children {
            var waitStatus: Int32 = 0
            let waited = waitpid(child.processID, &waitStatus, WNOHANG)
            if waited == child.processID {
                throw SupervisorFailure.childExited(
                    child.role,
                    Self.exitStatus(waitStatus))
            }
        }
    }

    private func drainSignals() -> [Int32] {
        var values: [Int32] = []
        while true {
            let signal = nucleus_session_consume_signal(signalDescriptor)
            guard signal >= 0 else { break }
            values.append(signal)
        }
        return values
    }

    private func terminate(_ children: [SupervisedChild]) {
        let processGroups = Set(children.map(\.processID))
        var remaining = processGroups
        for processGroup in processGroups { _ = kill(-processGroup, SIGTERM) }

        let deadline = Self.monotonicNanoseconds() + 1_000_000_000
        while !remaining.isEmpty,
              Self.monotonicNanoseconds() < deadline
        {
            for processID in Array(remaining) {
                var waitStatus: Int32 = 0
                let waited = waitpid(processID, &waitStatus, WNOHANG)
                if waited == processID || (waited < 0 && errno == ECHILD) {
                    remaining.remove(processID)
                }
            }
            guard !remaining.isEmpty else { break }
            var descriptor = pollfd(
                fd: signalDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            _ = poll(&descriptor, 1, 20)
            _ = drainSignals()
        }
        // A root may have exited during the grace period while a descendant
        // ignored SIGTERM. Kill every original process group, not only roots
        // still visible to waitpid.
        for processGroup in processGroups {
            _ = kill(-processGroup, SIGKILL)
        }
        for processID in remaining {
            while waitpid(processID, nil, 0) < 0, errno == EINTR {}
        }
    }

    private static func exitStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0
            ? (waitStatus >> 8) & 0xff
            : 128 + signal
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes {
                write(
                    descriptor,
                    $0.baseAddress!.advanced(by: written),
                    bytes.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw SupervisorFailure.system("configuration write", errno)
        }
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000
            + UInt64(time.tv_nsec)
    }

    private func log(_ message: String) {
        let line = "nucleus-session-supervisor: \(message)\n"
        _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    }
}

let status: Int32
do {
    let arguments = try SupervisorArguments.parse(CommandLine.arguments)
    status = try SessionSupervisor(arguments: arguments).run()
} catch SupervisorFailure.usage(let usage) {
    print(usage)
    status = CommandLine.arguments.contains("--help") ? 0 : 64
} catch {
    let line = "nucleus-session-supervisor: \(error)\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    status = 1
}
exit(status)
