import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

@Test func asyncExecutionPreservesTypedRuntimeFailures() async {
    let runID = RunID(rawValue: "fixture")
    await #expect(throws: RunRegistryFailure.self) {
        try await Task<Void, any Error> {
            throw RunRegistryFailure.resumptionIdentityChanged(runID)
        }.value
    }
}

@Test
func capturedCommandsKeepDiagnosticsOutOfMachineReadableOutput() async throws {
    let context = WorkspaceContext(
        root: FilePath(FileManager.default.currentDirectoryPath),
        environment: ProcessInfo.processInfo.environment,
        runtime: ColliderRuntime())

    let output = try await context.run(
        "sh",
        ["-c", "printf 'binary-directory\\n'; printf 'lock diagnostic\\n' >&2"],
        capture: true)

    #expect(output == "binary-directory")
    await context.runtime.shutdown()
}

@Test
func commandEnvironmentPreservesExplicitWaylandDisplay() async throws {
    let context = WorkspaceContext(
        root: FilePath(FileManager.default.currentDirectoryPath),
        environment: ProcessInfo.processInfo.environment,
        runtime: ColliderRuntime())

    let output = try await context.run(
        "sh",
        ["-c", "printf '%s' \"$WAYLAND_DISPLAY\""],
        capture: true,
        environmentOverrides: ["WAYLAND_DISPLAY": "wayland-nucleus"])

    #expect(output == "wayland-nucleus")
    await context.runtime.shutdown()
}

@Test
func commandRunnerCanAcceptInteractiveSIGINTTermination() async throws {
    let context = WorkspaceContext(
        root: FilePath(FileManager.default.currentDirectoryPath),
        environment: ProcessInfo.processInfo.environment,
        runtime: ColliderRuntime())

    try await context.run(
        "sh",
        ["-c", "kill -INT $$"],
        acceptedExitStatuses: [0, interruptedProcessExitStatus])

    await context.runtime.shutdown()
}

@Test
func runningCommandScopeReapsChildAfterSuccessfulBody() async throws {
    let fixture = try RunningCommandFixture()
    defer { fixture.remove() }
    let context = fixture.context()

    let value = try await context.withRunningCommand(
        "sh",
        fixture.longRunningArguments(
            ready: fixture.ready("child"),
            terminated: fixture.terminated("child")),
        output: .captured(limit: 1_024)
    ) { child in
        try await child.waitUntilReady()
        let processIdentifier = await child.processIdentifier
        #expect(processIdentifier != nil)
        #expect((processIdentifier ?? 0) > 0)
        try await fixture.waitForFile(fixture.ready("child"))
        return 42
    }

    #expect(value == 42)
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.terminated("child").path))
    await context.runtime.shutdown()
}

private enum RunningCommandFixtureFailure: Error {
    case expected
}

@Test
func runningCommandScopeReapsChildAfterBodyFailure() async throws {
    let fixture = try RunningCommandFixture()
    defer { fixture.remove() }
    let context = fixture.context()

    await #expect(throws: RunningCommandFixtureFailure.self) {
        try await context.withRunningCommand(
            "sh",
            fixture.longRunningArguments(
                ready: fixture.ready("child"),
                terminated: fixture.terminated("child")),
            output: .captured(limit: 1_024)
        ) { child in
            try await child.waitUntilReady()
            try await fixture.waitForFile(fixture.ready("child"))
            throw RunningCommandFixtureFailure.expected
        }
    }

    #expect(
        FileManager.default.fileExists(
            atPath: fixture.terminated("child").path))
    await context.runtime.shutdown()
}

@Test
func runningCommandScopeReapsChildWhenOwnerDeadlineExpires() async throws {
    let fixture = try RunningCommandFixture()
    defer { fixture.remove() }
    let context = fixture.context()

    await #expect(throws: WorkspaceFailure.self) {
        try await context.withRunningCommand(
            "sh",
            fixture.longRunningArguments(
                ready: fixture.ready("child"),
                terminated: fixture.terminated("child")),
            output: .captured(limit: 1_024)
        ) { child in
            try await child.waitUntilReady()
            try await fixture.waitForFile(fixture.ready("child"))
            try await ContinuousClock().sleep(for: .milliseconds(20))
            throw WorkspaceFailure.message("owner deadline expired")
        }
    }

    #expect(
        FileManager.default.fileExists(
            atPath: fixture.terminated("child").path))
    await context.runtime.shutdown()
}

@Test
func nestedRunningCommandScopesReapEveryChildOnCancellation() async throws {
    let fixture = try RunningCommandFixture()
    defer { fixture.remove() }
    let context = fixture.context()
    let operation = Task {
        try await context.withRunningCommand(
            "sh",
            fixture.longRunningArguments(
                ready: fixture.ready("outer"),
                terminated: fixture.terminated("outer")),
            output: .captured(limit: 1_024)
        ) { outer in
            try await outer.waitUntilReady()
            try await fixture.waitForFile(fixture.ready("outer"))
            return try await context.withRunningCommand(
                "sh",
                fixture.longRunningArguments(
                    ready: fixture.ready("inner"),
                    terminated: fixture.terminated("inner")),
                output: .captured(limit: 1_024)
            ) { inner in
                try await inner.waitUntilReady()
                try await fixture.waitForFile(fixture.ready("inner"))
                try await ContinuousClock().sleep(for: .seconds(60))
                return ()
            }
        }
    }
    try await fixture.waitForFile(fixture.ready("inner"))

    operation.cancel()
    await #expect(throws: CancellationError.self) {
        try await operation.value
    }

    for name in ["inner", "outer"] {
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.terminated(name).path))
    }
    await context.runtime.shutdown()
}

@Test
func runningCommandExposesNaturalTerminationStatus() async throws {
    let fixture = try RunningCommandFixture()
    defer { fixture.remove() }
    let context = fixture.context()

    let status = try await context.withRunningCommand(
        "sh",
        ["-c", "exit 7"],
        output: .captured(limit: 1_024)
    ) { child in
        try await child.wait().status
    }

    #expect(status == 7)
    await context.runtime.shutdown()
}

@Test
func workflowLockExcludesAnotherFileDescription() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-workflow-lock-test-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workflow.lock").path

    var owner: WorkspaceFileLock? = try WorkspaceFileLock(
        path: path,
        purpose: "test workflow")
    do {
        _ = try WorkspaceFileLock(
            path: path,
            purpose: "test workflow",
            waitForExistingOwner: false)
        Issue.record("a second file description acquired an owned workflow lock")
    } catch {
        #expect(String(describing: error) == "test workflow is already running")
    }

    owner = nil
    let replacement = try WorkspaceFileLock(
        path: path,
        purpose: "test workflow",
        waitForExistingOwner: false)
    withExtendedLifetime(replacement) {}
    _ = owner
}

private struct RunningCommandFixture: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nucleus-running-command-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    func context() -> WorkspaceContext {
        WorkspaceContext(
            root: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin"
            ],
            runtime: ColliderRuntime())
    }

    func ready(_ name: String) -> URL {
        directory.appendingPathComponent("\(name)-ready")
    }

    func terminated(_ name: String) -> URL {
        directory.appendingPathComponent("\(name)-terminated")
    }

    func longRunningArguments(
        ready: URL,
        terminated: URL
    ) -> [String] {
        [
            "-c",
            "trap 'printf terminated > \"$2\"; exit 0' TERM; "
                + "printf ready > \"$1\"; "
                + "while :; do sleep 0.05; done",
            "sh",
            ready.path,
            terminated.path,
        ]
    }

    func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: file.path),
            ContinuousClock.now < deadline
        {
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw WorkspaceFailure.message(
                "timed out waiting for \(file.lastPathComponent)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
