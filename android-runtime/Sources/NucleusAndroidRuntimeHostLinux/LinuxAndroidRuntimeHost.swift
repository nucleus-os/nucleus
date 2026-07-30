import Dispatch
import Foundation
import Glibc
import NucleusAndroidRuntimeCore
import NucleusAndroidRuntimePlatformC
import Synchronization

public struct LinuxAndroidRuntimeHostFailure:
    Error, CustomStringConvertible, Sendable
{
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

public final class LinuxAndroidRuntimeRunningProcess:
    AndroidRuntimeRunningProcess, @unchecked Sendable
{
    private struct State: Sendable {
        var status: Int32?
        var waiters: [
            CheckedContinuation<AndroidRuntimeProcessResult, Never>
        ] = []
    }

    private let process: Process
    private let state = Mutex(State())
    private let retainedOutput: FileHandle?

    convenience init(
        command: AndroidRuntimeCommand,
        environment: [String: String]
    ) throws {
        let process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(
                fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        process.currentDirectoryURL = command.directory
        process.environment = environment.merging(
            command.environmentOverrides
        ) { _, override in
            override
        }

        let outputHandle: FileHandle?
        switch command.output {
        case .file(let path):
            _ = FileManager.default.createFile(
                atPath: path.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            outputHandle = handle
        case .inherited, nil:
            outputHandle = nil
        }
        try self.init(
            preparedProcess: process,
            retainedOutput: outputHandle)
    }

    private init(
        preparedProcess process: Process,
        retainedOutput: FileHandle?
    ) throws {
        self.process = process
        self.retainedOutput = retainedOutput
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(status: process.terminationStatus)
        }
        do {
            try launchAndroidRuntimeProcess(process)
        } catch {
            try? retainedOutput?.close()
            throw LinuxAndroidRuntimeHostFailure(
                "start process failed: \(error)")
        }
    }

    public var processIdentifier: Int32? {
        get async {
            process.processIdentifier > 0
                ? process.processIdentifier
                : nil
        }
    }

    public var isRunning: Bool {
        get async {
            state.withLock { $0.status == nil }
        }
    }

    public func waitUntilReady() async throws {
        if let status = state.withLock({ $0.status }) {
            throw LinuxAndroidRuntimeHostFailure(
                "process exited during startup with status \(status)")
        }
    }

    public func waitForExit() async throws -> AndroidRuntimeProcessResult {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if let status = state.status {
                    continuation.resume(
                        returning: AndroidRuntimeProcessResult(
                            status: status))
                } else {
                    state.waiters.append(continuation)
                }
            }
        }
    }

    func stop() async {
        if await isRunning {
            process.terminate()
        }
        _ = try? await waitForExit()
    }

    private func didTerminate(status: Int32) {
        let waiters = state.withLock { state -> [
            CheckedContinuation<AndroidRuntimeProcessResult, Never>
        ] in
            guard state.status == nil else {
                return []
            }
            state.status = status
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        try? retainedOutput?.close()
        let result = AndroidRuntimeProcessResult(status: status)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

func launchAndroidRuntimeProcess(_ process: Process) throws {
    var emptyMask = sigset_t()
    var inheritedMask = sigset_t()
    guard unsafe sigemptyset(&emptyMask) == 0 else {
        throw LinuxAndroidRuntimeHostFailure(
            "create clean child signal mask failed with errno \(errno)")
    }
    let clearStatus = unsafe pthread_sigmask(
        SIG_SETMASK,
        &emptyMask,
        &inheritedMask)
    guard clearStatus == 0 else {
        throw LinuxAndroidRuntimeHostFailure(
            "clear child signal mask failed with status \(clearStatus)")
    }
    defer {
        _ = unsafe pthread_sigmask(
            SIG_SETMASK,
            &inheritedMask,
            nil)
    }
    try process.run()
}

public final class LinuxAndroidRuntimeKernelLog:
    AndroidRuntimeKernelLog, @unchecked Sendable
{
    private struct State: Sendable {
        var stopped = false
        var failure: LinuxAndroidRuntimeHostFailure?
    }

    public let slavePath: String

    private let state = Mutex(State())
    private let completion = DispatchGroup()
    private let master: Int32
    private let output: Int32

    init(output path: URL) throws {
        var slavePathBytes = [CChar](repeating: 0, count: 4_096)
        let master = unsafe nucleus_android_runtime_open_raw_pseudo_terminal(
                &slavePathBytes,
                slavePathBytes.count
            )
        guard master >= 0 else {
            throw LinuxAndroidRuntimeHostFailure(
                "create Android kernel-log pseudo-terminal failed "
                    + "with errno \(errno)")
        }
        let output = unsafe open(
            path.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            mode_t(0o600))
        guard output >= 0 else {
            let code = errno
            _ = close(master)
            throw LinuxAndroidRuntimeHostFailure(
                "open Android kernel log failed with errno \(code)")
        }
        let pathEnd =
            slavePathBytes.firstIndex(of: 0) ?? slavePathBytes.endIndex
        slavePath = String(
            decoding: slavePathBytes[..<pathEnd].map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self)
        self.master = master
        self.output = output
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            drain()
        }
    }

    deinit {
        stop()
    }

    public func checkHealth() throws {
        if let failure = state.withLock({ $0.failure }) {
            throw failure
        }
    }

    public func stop() {
        state.withLock { $0.stopped = true }
        completion.wait()
    }

    private func drain() {
        defer {
            _ = fsync(output)
            _ = close(output)
            _ = close(master)
            completion.leave()
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                unsafe read(master, $0.baseAddress, $0.count)
            }
            if count > 0 {
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes {
                        unsafe write(
                            output,
                            $0.baseAddress?.advanced(by: offset),
                            count - offset)
                    }
                    guard written > 0 else {
                        recordFailure(
                            "write Android kernel log failed with "
                                + "errno \(errno)")
                        return
                    }
                    offset += written
                }
                continue
            }
            if state.withLock({ $0.stopped }) {
                return
            }
            if count < 0,
                errno != EAGAIN,
                errno != EWOULDBLOCK,
                errno != EIO,
                errno != EINTR
            {
                recordFailure(
                    "read Android kernel pseudo-terminal failed with "
                        + "errno \(errno)")
                return
            }
            var descriptor = pollfd(
                fd: master,
                events: Int16(POLLIN),
                revents: 0)
            _ = unsafe poll(&descriptor, 1, 100)
        }
    }

    private func recordFailure(_ description: String) {
        state.withLock {
            if $0.failure == nil {
                $0.failure = LinuxAndroidRuntimeHostFailure(description)
            }
        }
    }
}

public struct LinuxAndroidRuntimeHost: AndroidRuntimeHost, Sendable {
    private let environment: [String: String]
    private let workingDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
    ) {
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func execute(
        _ command: AndroidRuntimeCommand
    ) async throws -> String {
        let capturePipe = command.capture ? Pipe() : nil
        let normalized = AndroidRuntimeCommand(
            executable: command.executable,
            arguments: command.arguments,
            directory: command.directory ?? workingDirectory,
            capture: command.capture,
            environmentOverrides: command.environmentOverrides,
            output: command.output,
            timeoutSeconds: command.timeoutSeconds)
        let process = try makeProcess(
            normalized,
            capturePipe: capturePipe)
        let result: AndroidRuntimeProcessResult
        if let timeoutSeconds = command.timeoutSeconds {
            result = try await withThrowingTaskGroup(
                of: AndroidRuntimeProcessResult.self
            ) { group in
                group.addTask {
                    try await process.waitForExit()
                }
                group.addTask {
                    try await ContinuousClock().sleep(
                        for: .seconds(timeoutSeconds))
                    await process.stop()
                    throw LinuxAndroidRuntimeHostFailure(
                        "\(command.executable) timed out")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } else {
            result = try await process.waitForExit()
        }
        let output = capturePipe.map {
            String(
                decoding: $0.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        guard result.status == 0 else {
            throw LinuxAndroidRuntimeHostFailure(
                "\(command.executable) exited with status \(result.status)")
        }
        return output
    }

    public func withRunningProcess<Value: Sendable>(
        _ command: AndroidRuntimeCommand,
        _ body: @escaping @Sendable (
            LinuxAndroidRuntimeRunningProcess
        ) async throws -> Value
    ) async throws -> Value {
        let process = try makeProcess(
            AndroidRuntimeCommand(
                executable: command.executable,
                arguments: command.arguments,
                directory: command.directory ?? workingDirectory,
                capture: command.capture,
                environmentOverrides: command.environmentOverrides,
                output: command.output,
                timeoutSeconds: command.timeoutSeconds),
            capturePipe: nil)
        do {
            let value = try await body(process)
            await process.stop()
            return value
        } catch {
            await process.stop()
            throw error
        }
    }

    public func makeKernelLog(
        output: URL
    ) throws -> LinuxAndroidRuntimeKernelLog {
        try LinuxAndroidRuntimeKernelLog(output: output)
    }

    public func addBinderDevice(
        control: URL,
        name: String
    ) throws -> AndroidRuntimeBinderDeviceNumber {
        guard !name.isEmpty,
            name.utf8.count <= 255,
            name.allSatisfy({
                $0.isASCII
                    && ($0.isLowercase || $0.isNumber || $0 == "-")
            })
        else {
            throw LinuxAndroidRuntimeHostFailure(
                "invalid binderfs device name: \(name)")
        }
        var major: UInt32 = 0
        var minor: UInt32 = 0
        let status = control.path.withCString { controlPath in
            name.withCString { deviceName in
                unsafe nucleus_android_runtime_binderfs_add_device(
                    controlPath,
                    deviceName,
                    &major,
                    &minor)
            }
        }
        guard status == 0 else {
            throw LinuxAndroidRuntimeHostFailure(
                "create binderfs device \(name) failed with errno \(errno)")
        }
        return AndroidRuntimeBinderDeviceNumber(
            major: major,
            minor: minor)
    }

    private func makeProcess(
        _ command: AndroidRuntimeCommand,
        capturePipe: Pipe?
    ) throws -> LinuxAndroidRuntimeRunningProcess {
        if let capturePipe {
            let process = Process()
            if command.executable.contains("/") {
                process.executableURL = URL(
                    fileURLWithPath: command.executable)
                process.arguments = command.arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command.executable] + command.arguments
            }
            process.currentDirectoryURL = command.directory
            process.environment = environment.merging(
                command.environmentOverrides
            ) { _, override in
                override
            }
            process.standardOutput = capturePipe
            process.standardError = capturePipe
            return try LinuxAndroidRuntimeRunningProcess(
                process: process)
        }
        return try LinuxAndroidRuntimeRunningProcess(
            command: command,
            environment: environment)
    }
}

extension LinuxAndroidRuntimeRunningProcess {
    convenience init(process: Process) throws {
        try self.init(process: process, retainedOutput: nil)
    }

    convenience init(
        process: Process,
        retainedOutput: FileHandle?
    ) throws {
        try self.init(
            preparedProcess: process,
            retainedOutput: retainedOutput)
    }
}
