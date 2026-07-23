import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderRuntime

@Test func runtimeTransportsDeclaredStandardInputBytesLiterally() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-input-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Array("literal $HOME `uname` ' \" \n bytes".utf8)
    let result = try await ColliderRuntime().execute(CommandSpec(
        executable: .named("cat"),
        arguments: [],
        workingDirectory: FilePath(directory.path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
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
    let runtime = ColliderRuntime()
    let result = try await runtime.execute(CommandSpec(
        executable: .named("sh"),
        arguments: [
            "-c",
            "trap 'printf terminated > \"$1\"; exit 0' TERM; while :; do sleep 0.05; done",
            "sh", marker.path,
        ],
        workingDirectory: FilePath(directory.path),
        environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
        output: .captured(limit: 1_024),
        timeoutNanoseconds: 1_000_000_000))
    #expect(result.timedOut)
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func runtimeForwardsSignalsToTheActiveProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-signal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("terminated")
    let cancellation = RuntimeCancellation()
    let runtime = ColliderRuntime(cancellation: cancellation)
    let operation = Task {
        try await runtime.execute(CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c",
                "trap 'printf terminated > \"$1\"; exit 0' TERM; while :; do sleep 0.05; done",
                "sh", marker.path,
            ],
            workingDirectory: FilePath(directory.path),
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
            output: .captured(limit: 1_024)))
    }
    let registrationDeadline = ContinuousClock().now.advanced(by: .seconds(5))
    while !(await cancellation.hasActiveProcessGroups()),
          ContinuousClock().now < registrationDeadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    try #require(await cancellation.hasActiveProcessGroups())
    let forwarding = await cancellation.forward(signal: 15)
    #expect(forwarding.attemptedProcessGroups == 1)
    #expect(forwarding.failures.isEmpty)
    let result = try await operation.value
    #expect(result.status == 0)
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func runtimeUsesOnlyTheDeclaredChildEnvironment() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ColliderRuntime().execute(CommandSpec(
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

@Test func runtimePreservesNonzeroChildStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await ColliderRuntime().execute(CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "exit 23"],
        workingDirectory: FilePath(directory.path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
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
    let result = try await ColliderRuntime().execute(CommandSpec(
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
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ],
        output: .logged,
        timeoutNanoseconds: 10_000_000_000))
    #expect(result.status == 0)
}

@Test func runtimeEnforcesCapturedOutputLimits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-output-limit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: RuntimeFailure.self) {
        try await ColliderRuntime().execute(CommandSpec(
            executable: .named("sh"),
            arguments: ["-c", "printf '0123456789abcdef'"],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ],
            output: .captured(limit: 8)))
    }
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
        try await runtime.execute(CommandSpec(
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
                    ?? "/usr/bin:/bin",
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
    let baseline = try openDescriptorCount()
    for _ in 0..<40 {
        let result = try await runtime.execute(CommandSpec(
            executable: .named("true"),
            arguments: [],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ],
            output: .captured(limit: 1)))
        #expect(result.status == 0)
    }
    #expect(try openDescriptorCount() <= baseline + 2)
}

private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(
        atPath: "/proc/self/fd").count
}
