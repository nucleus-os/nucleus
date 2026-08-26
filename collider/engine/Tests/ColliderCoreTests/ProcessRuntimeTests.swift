import ColliderCore
import ColliderPersistence
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func commandOutputSinkPersistsBeforePresentationAndScrubsFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-output-sink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["fixture"])
    let logging = CommandLogging(registry: registry, run: run)
    let stage = TaskID(rawValue: "fixture.output")
    let stageLog = await registry.stageLogPath(for: stage, in: run)
    let file = FilePath(directory.appendingPathComponent("output.txt").path)
    let persistedBeforePresentation = Mutex(false)
    let sink = try CommandOutputSink(
        logging: logging,
        stage: stage,
        file: file,
        presentation: .default,
        observer: TaskOutputObserver(output: { event in
            guard case .chunk = event,
                let data = try? Data(contentsOf: URL(fileURLWithPath: stageLog.string)),
                String(decoding: data, as: UTF8.self).contains("token=<redacted>")
            else { return }
            persistedBeforePresentation.withLock { $0 = true }
        }))

    try await sink.write(
        Array("token=secret\n".utf8),
        stream: .standardOutput)
    try await sink.finish()

    #expect(persistedBeforePresentation.withLock { $0 })
    #expect(try String(contentsOfFile: file.string, encoding: .utf8) == "token=<redacted>\n")
}

@Test func rawTerminalExecutionBracketsUnmodifiedInheritedDescriptors() async throws {
    let callbacks = Mutex((willBegin: 0, didEnd: 0))
    let runtime = ColliderRuntime(
        taskOutputObserver: TaskOutputObserver(
            terminalWillBegin: {
                callbacks.withLock { $0.willBegin += 1 }
            },
            terminalDidEnd: {
                callbacks.withLock { $0.didEnd += 1 }
            }))
    let result = try await runtime.execute(
        CommandSpec(
            executable: .named("true"),
            arguments: [],
            workingDirectory: FilePath(FileManager.default.temporaryDirectory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ],
            input: .terminal,
            output: .captured(limit: 1_024)))

    #expect(result.status == 0)
    #expect(callbacks.withLock { $0.willBegin } == 1)
    #expect(callbacks.withLock { $0.didEnd } == 1)
}

@Test func runtimeTransportsDeclaredStandardInputBytesLiterally() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-input-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Array("literal $HOME `uname` ' \" \n bytes".utf8)
    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .named("cat"),
            arguments: [],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ],
            input: .bytes(payload),
            output: .captured(limit: 1_024)))
    #expect(Array(result.standardOutput.utf8) == payload)
}

@Test func streamedOutputIsTeeedIntoRunAndStageLogs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-stream-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "fixture"])
    let runtime = ColliderRuntime(logging: CommandLogging(registry: registry, run: run))
    let result = try await runtime.execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: ["-c", "printf stdout-value; printf stderr-value >&2"],
            workingDirectory: FilePath(directory.path),
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
            output: .captured(limit: 1_024)),
        stage: TaskID(rawValue: "fixture.output"))
    #expect(result.standardOutput == "stdout-value")
    let runLog = try String(
        contentsOf: directory.appendingPathComponent("runs/\(run.id.rawValue)/run.log"),
        encoding: .utf8)
    let stageLog = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/stages/fixture-output.log"),
        encoding: .utf8)
    for log in [runLog, stageLog] {
        #expect(log.contains("stdout-value"))
        #expect(log.contains("stderr-value"))
    }
}

@Test func timeoutRunsDeclaredProcessGroupTeardown() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("terminated")
    let ready = directory.appendingPathComponent("ready")
    let runtime = ColliderRuntime()
    // The timeout has to outlast starting a shell, not merely exceed it. A
    // window sized to a quiet machine is spent on process startup on a busy
    // one, and the signal then arrives before the trap exists, so the child
    // dies to the default action and the teardown under test never runs.
    let result = try await runtime.execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c",
                "trap 'printf terminated > \"$1\"; exit 0' TERM; "
                    + "printf ready > \"$2\"; "
                    + "while :; do sleep 0.05; done",
                "sh", marker.path, ready.path,
            ],
            workingDirectory: FilePath(directory.path),
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
            output: .captured(limit: 1_024),
            timeoutNanoseconds: 5_000_000_000))
    #expect(result.timedOut)
    // Readiness is written after the trap is installed, so it separates a
    // child that could service the signal from one that never got that far.
    #expect(FileManager.default.fileExists(atPath: ready.path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func runtimeForwardsSignalsToTheActiveProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-signal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("terminated")
    let ready = directory.appendingPathComponent("ready")
    let cancellation = RuntimeCancellation()
    let runtime = ColliderRuntime(cancellation: cancellation)
    let operation = Task {
        try await runtime.execute(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c",
                    "trap 'printf terminated > \"$1\"; exit 0' TERM; "
                        + "printf ready > \"$2\"; "
                        + "while :; do sleep 0.05; done",
                    "sh", marker.path, ready.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                ],
                output: .captured(limit: 1_024)))
    }
    let readinessDeadline = ContinuousClock().now.advanced(by: .seconds(5))
    while ContinuousClock().now < readinessDeadline {
        let readyExists = FileManager.default.fileExists(atPath: ready.path)
        let processGroupIsActive = await cancellation.hasActiveProcessGroups()
        if readyExists && processGroupIsActive { break }
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: ready.path))
    try #require(await cancellation.hasActiveProcessGroups())
    let forwarding = await cancellation.forward(signal: 15)
    #expect(forwarding.attemptedProcessGroups == 1)
    #expect(forwarding.failures.isEmpty)
    let result = try await operation.value
    #expect(result.status == 0)
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func repeatedInterruptionEscalatesNativeProcessGroups() async {
    let cancellation = RuntimeCancellation()

    let graceful = await cancellation.handleInterruption(signal: 15)
    let forced = await cancellation.handleInterruption(signal: 15)

    #expect(graceful.signal == 15)
    #expect(forced.signal == 9)
    #expect(await cancellation.receivedInterruptionSignal() == 15)
}

@Test func runtimeUsesOnlyTheDeclaredChildEnvironment() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c",
                #"printf '%s|%s' "${COLLIDER_MARKER-unset}" "${HOME-unset}""#,
            ],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "COLLIDER_MARKER": "declared",
            ],
            output: .captured(limit: 1_024)))
    #expect(result.standardOutput == "declared|unset")
}

@Test func runtimeRejectsInvalidEnvironmentKeys() async {
    await #expect(throws: ExecutionFailure.self) {
        try await ColliderRuntime().execute(
            CommandSpec(
                executable: .named("true"),
                arguments: [],
                workingDirectory: FilePath("/"),
                environment: ["INVALID=KEY": "value"],
                output: .captured(limit: 1_024)))
    }
}

@Test func runtimePreservesNonzeroChildStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: ["-c", "exit 23"],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ],
            output: .captured(limit: 1_024)))
    #expect(result.status == 23)
}

@Test func runtimeDrainsConcurrentStdoutAndStderrWithoutBackpressureDeadlock()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-backpressure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 20000 ]; do "
                    + "printf 'stdout-payload-%08d\\n' \"$i\"; "
                    + "printf 'stderr-payload-%08d\\n' \"$i\" >&2; "
                    + "i=$((i + 1)); done",
            ],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ],
            output: .logged,
            timeoutNanoseconds: 10_000_000_000))
    #expect(result.status == 0)
}

@Test func runtimeOwnsStreamsAcrossConcurrentProcesses() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-concurrent-streams-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withThrowingTaskGroup(of: Int32.self) { group in
        for index in 0..<32 {
            group.addTask {
                let result = try await ColliderRuntime().execute(
                    CommandSpec(
                        executable: .named("sh"),
                        arguments: [
                            "-c",
                            "printf 'stdout-%s' \"$1\"; printf 'stderr-%s' \"$1\" >&2",
                            "collider-concurrent-streams",
                            String(index),
                        ],
                        workingDirectory: FilePath(directory.path),
                        environment: [
                            "PATH": ProcessInfo.processInfo.environment["PATH"]
                                ?? "/usr/bin:/bin"
                        ],
                        output: .logged))
                return result.status
            }
        }

        for try await status in group {
            #expect(status == 0)
        }
    }
}

@Test func runtimeRetainsUnboundedCommandOutputInAFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-file-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("android-logcat.log")

    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c",
                "printf stdout-value; printf stderr-value >&2",
            ],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin"
            ],
            output: .file(FilePath(output.path))))

    #expect(result.status == 0)
    let contents = try String(contentsOf: output, encoding: .utf8)
    #expect(contents.contains("stdout-value"))
    #expect(contents.contains("stderr-value"))
}

@Test func runtimeEnforcesCapturedOutputLimits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-output-limit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let completionMarker = directory.appendingPathComponent("completed")
    await #expect(throws: ExecutionFailure.self) {
        try await ColliderRuntime().execute(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c",
                    "printf '0123456789abcdef'; printf completed > \"$1\"",
                    "sh", completionMarker.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ],
                output: .captured(limit: 8)))
    }
    #expect(FileManager.default.fileExists(atPath: completionMarker.path))
}

@Test func runtimeCancellationTearsDownTheRegisteredProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("cancelled")
    let ready = directory.appendingPathComponent("ready")
    let cancellation = RuntimeCancellation()
    let runtime = ColliderRuntime(cancellation: cancellation)
    let operation = Task {
        try await runtime.execute(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c",
                    "trap 'printf cancelled > \"$1\"; exit 0' TERM; "
                        + "printf ready > \"$2\"; "
                        + "while :; do sleep 0.05; done",
                    "sh", marker.path, ready.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ],
                output: .captured(limit: 1_024)))
    }
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: ready.path),
        ContinuousClock().now < deadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    try #require(await cancellation.hasActiveProcessGroups())
    operation.cancel()
    await #expect(throws: CancellationError.self) {
        try await operation.value
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(!(await cancellation.hasActiveProcessGroups()))
}

@Test func repeatedCommandsCloseTheirRuntimeDescriptors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-descriptors-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = ColliderRuntime()
    _ = try await runtime.execute(
        CommandSpec(
            executable: .named("true"),
            arguments: [],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin"
            ],
            output: .captured(limit: 1)))
    let baseline = try openDescriptorCount()
    for _ in 0..<40 {
        let result = try await runtime.execute(
            CommandSpec(
                executable: .named("true"),
                arguments: [],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ],
                output: .captured(limit: 1)))
        #expect(result.status == 0)
    }
    #expect(try openDescriptorCount() <= baseline + 2)
}

@Test func concurrentCommandsCompleteWithoutPreExecDeadlock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-concurrent-processes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ]

    try await withThrowingTaskGroup(of: Int32.self) { group in
        for _ in 0..<32 {
            group.addTask {
                try await ColliderRuntime().execute(
                    CommandSpec(
                        executable: .named("true"),
                        arguments: [],
                        workingDirectory: FilePath(directory.path),
                        environment: environment,
                        output: .captured(limit: 1))
                )
                .status
            }
        }
        for try await status in group {
            #expect(status == 0)
        }
    }
}

private func openDescriptorCount() throws -> Int {
    #if os(Linux)
    let descriptorDirectory = "/proc/self/fd"
    #else
    let descriptorDirectory = "/dev/fd"
    #endif
    return try FileManager.default.contentsOfDirectory(
        atPath: descriptorDirectory
    ).count
}
