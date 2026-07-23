import Foundation // FileHandle provides descriptor-backed captured output.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum WorkspaceFailure: Error, CustomStringConvertible {
    case message(String)
    case process([String], Int32)

    var description: String {
        switch self {
        case .message(let value): value
        case .process(let command, let status):
            "command failed with exit \(status): \(command.joined(separator: " "))"
        }
    }
}

struct WorkspaceContext: Sendable {
    let root: URL
    let environment: [String: String]

    static func load() throws -> WorkspaceContext {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["NUCLEUS_WORKSPACE_ROOT"], !root.isEmpty else {
            throw WorkspaceFailure.message("NUCLEUS_WORKSPACE_ROOT is not set; invoke through tools/nucleus")
        }
        return WorkspaceContext(root: URL(fileURLWithPath: root), environment: environment)
    }

    func repository(_ name: String) -> URL { root.appendingPathComponent(name) }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        capture: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) throws -> String {
        let command = [executable] + arguments
        var fileActions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            throw WorkspaceFailure.message("could not initialize process launch state")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let workingDirectory = (directory ?? root).path
        guard posix_spawn_file_actions_addchdir_np(
            &fileActions, workingDirectory) == 0
        else {
            throw WorkspaceFailure.message(
                "could not set child working directory: \(workingDirectory)")
        }

        // Foundation.Process attempts to reset glibc's reserved signals 32 and
        // 33 and emits a warning for every launch. Define only the dispositions
        // an ordinary command child must reset, and unblock its signal mask.
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptyMask)
        for signal in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
        else {
            throw WorkspaceFailure.message("could not configure child signal state")
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        if capture {
            let pipeResult = descriptors.withUnsafeMutableBufferPointer {
                pipe($0.baseAddress!)
            }
            guard pipeResult == 0 else {
                throw WorkspaceFailure.message(
                    "could not create process output pipe: errno \(errno)")
            }
            guard posix_spawn_file_actions_adddup2(
                &fileActions, descriptors[1], STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_addclose(
                    &fileActions, descriptors[0]) == 0,
                  posix_spawn_file_actions_addclose(
                    &fileActions, descriptors[1]) == 0
            else {
                close(descriptors[0])
                close(descriptors[1])
                throw WorkspaceFailure.message("could not configure process output capture")
            }
        }

        let argvStorage: [UnsafeMutablePointer<CChar>?] =
            (["/usr/bin/env"] + command).map {
                $0.withCString { strdup($0) }
            } + [nil]
        let childEnvironment = environment.merging(environmentOverrides) { _, override in
            override
        }
        let environmentStrings = childEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let environmentStorage: [UnsafeMutablePointer<CChar>?] =
            environmentStrings.map {
                $0.withCString { strdup($0) }
            } + [nil]
        defer {
            for pointer in argvStorage {
                if let pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
            for pointer in environmentStorage {
                if let pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
        }

        var processID = pid_t()
        let launchStatus = argvStorage.withUnsafeBufferPointer { argv in
            environmentStorage.withUnsafeBufferPointer { environment in
                posix_spawn(
                    &processID,
                    "/usr/bin/env",
                    &fileActions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argv.baseAddress!),
                    UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard launchStatus == 0 else {
            if capture {
                close(descriptors[0])
                close(descriptors[1])
            }
            throw WorkspaceFailure.message(
                "could not launch \(executable): error \(launchStatus)")
        }

        let capturedData: Data
        if capture {
            close(descriptors[1])
            let output = FileHandle(
                fileDescriptor: descriptors[0],
                closeOnDealloc: true)
            // Drain while the child runs so verbose generators cannot fill the
            // pipe and deadlock before waitpid observes termination.
            capturedData = output.readDataToEndOfFile()
            try? output.close()
        } else {
            capturedData = Data()
        }

        var waitStatus: Int32 = 0
        while waitpid(processID, &waitStatus, 0) == -1 {
            if errno == EINTR { continue }
            throw WorkspaceFailure.message(
                "waitpid failed for \(executable): errno \(errno)")
        }
        let signal = waitStatus & 0x7f
        let terminationStatus: Int32 = signal == 0
            ? (waitStatus >> 8) & 0xff
            : 128 + signal
        let value = capture
            ? String(decoding: capturedData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard terminationStatus == 0 else {
            throw WorkspaceFailure.process(command, terminationStatus)
        }
        return value
    }

    func withExclusiveVerification<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        let directory = root
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("nucleus-workflow-locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let lock = try WorkspaceFileLock(
            path: directory.appendingPathComponent("verification.lock").path,
            purpose: "workspace verification")
        return try withExtendedLifetime(lock) {
            try body()
        }
    }
}

final class WorkspaceFileLock {
    private let descriptor: Int32

    init(
        path: String,
        purpose: String,
        waitForExistingOwner: Bool = true
    ) throws {
        let openedDescriptor = open(path, O_CREAT | O_RDWR, mode_t(0o644))
        guard openedDescriptor >= 0 else {
            throw WorkspaceFailure.message(
                "could not open \(purpose) lock: errno \(errno)")
        }

        let operation = LOCK_EX | (waitForExistingOwner ? 0 : LOCK_NB)
        guard flock(openedDescriptor, operation) == 0 else {
            let code = errno
            _ = close(openedDescriptor)
            if !waitForExistingOwner && (code == EWOULDBLOCK || code == EAGAIN) {
                throw WorkspaceFailure.message("\(purpose) is already running")
            }
            throw WorkspaceFailure.message(
                "could not acquire \(purpose) lock: errno \(code)")
        }
        descriptor = openedDescriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
