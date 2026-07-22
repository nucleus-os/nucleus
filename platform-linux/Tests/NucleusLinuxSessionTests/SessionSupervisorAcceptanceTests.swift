import Foundation
import Glibc
import NucleusLinuxSession
import Testing

private struct SupervisorFixture {
    let directory: URL
    let supervisor: URL
    let child: URL
    let statusFile: URL
    let configuration: SessionConfiguration

    init(configuration: SessionConfiguration = .defaults) throws {
        let products = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let supervisor = products.appendingPathComponent(
            "NucleusSessionSupervisor")
        let child = products.appendingPathComponent("NucleusSessionFixture")
        guard FileManager.default.isExecutableFile(atPath: supervisor.path),
              FileManager.default.isExecutableFile(atPath: child.path)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-session-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        self.directory = directory
        self.supervisor = supervisor
        self.child = child
        self.statusFile = directory.appendingPathComponent("status.bin")
        self.configuration = configuration
    }

    func launch(
        compositorMode: String = "ready-wait",
        shellMode: String = "ready-wait",
        startupTimeoutSeconds: Int = 3
    ) throws -> Process {
        let process = Process()
        process.executableURL = supervisor
        process.arguments = [
            "--status-file", statusFile.path,
            "--configuration", configuration.hexEncoded,
            "--startup-timeout-seconds", String(startupTimeoutSeconds),
            "--shell", child.path,
            "--", child.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["NUCLEUS_SESSION_FIXTURE_DIRECTORY"] = directory.path
        environment["NUCLEUS_SESSION_FIXTURE_COMPOSITOR_MODE"] = compositorMode
        environment["NUCLEUS_SESSION_FIXTURE_SHELL_MODE"] = shellMode
        process.environment = environment
        let log = directory.appendingPathComponent("supervisor.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    func path(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func waitForFile(_ name: String, iterations: Int = 500) -> Bool {
        let path = path(name).path
        for _ in 0..<iterations {
            if FileManager.default.fileExists(atPath: path) { return true }
            usleep(10_000)
        }
        return false
    }

    func release(_ role: String) throws {
        try Data().write(to: path("release-\(role)"), options: .atomic)
    }

    func processID(_ role: String) throws -> pid_t {
        let value = try String(contentsOf: path("\(role)-pid"), encoding: .utf8)
        return try #require(pid_t(value))
    }

    func status() -> SessionReadinessMessage? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return SessionReadinessMessage(encoded: Array(data))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func waitForExit(_ process: Process, iterations: Int = 500) -> Bool {
    for _ in 0..<iterations {
        if !process.isRunning {
            process.waitUntilExit()
            return true
        }
        usleep(10_000)
    }
    return false
}

private func stop(_ process: Process) {
    guard process.isRunning else {
        process.waitUntilExit()
        return
    }
    _ = kill(process.processIdentifier, SIGTERM)
    if !waitForExit(process, iterations: 300) {
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

private func processIsGone(_ processID: pid_t) -> Bool {
    errno = 0
    return kill(processID, 0) != 0 && errno == ESRCH
}

@Suite struct SessionSupervisorAcceptanceTests {
    @Test func compositorReadinessGatesShellAndBothReceiveOneConfiguration()
        throws
    {
        let configuration = try SessionConfiguration(
            outputScale: 1.75,
            presentMode: .mailboxLatestWins,
            enableVulkanValidation: true,
            drmDevicePath: "/dev/dri/renderD129",
            wallpaperPath: "/tmp/acceptance-wallpaper.jpeg")
        let fixture = try SupervisorFixture(configuration: configuration)
        defer { fixture.remove() }
        let process = try fixture.launch(compositorMode: "wait-before-ready")
        defer { stop(process) }

        #expect(fixture.waitForFile("compositor-pid"))
        usleep(100_000)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.path("shell-pid").path))
        try fixture.release("compositor")
        #expect(fixture.waitForFile("shell-ready"))
        #expect(fixture.status() == SessionReadinessMessage(
            role: .shell,
            milestone: .shellReady))

        let compositorConfiguration = try String(
            contentsOf: fixture.path("compositor-configuration"),
            encoding: .utf8)
        let shellConfiguration = try String(
            contentsOf: fixture.path("shell-configuration"),
            encoding: .utf8)
        #expect(compositorConfiguration == configuration.hexEncoded)
        #expect(shellConfiguration == configuration.hexEncoded)
    }

    @Test func shellExitIsARequiredSiblingFailureAndRetiresCompositor()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(shellMode: "exit-after-ready")
        #expect(fixture.waitForFile("shell-ready"))
        let compositorPID = try fixture.processID("compositor")
        #expect(waitForExit(process))
        #expect(process.terminationStatus == 73)
        #expect(fixture.status()?.detail
            == SessionFailureReason.shellExitedAfterReady.rawValue)
        #expect(processIsGone(compositorPID))
    }

    @Test func compositorExitAfterSessionReadinessRetiresShell() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(
            compositorMode: "exit-after-peer-ready")
        #expect(fixture.waitForFile("shell-ready"))
        let shellPID = try fixture.processID("shell")
        #expect(waitForExit(process))
        #expect(process.terminationStatus == 72)
        #expect(fixture.status()?.detail
            == SessionFailureReason.compositorExitedAfterReady.rawValue)
        #expect(processIsGone(shellPID))
    }

    @Test func supervisorSignalRetiresBothProcessGroups() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch()
        #expect(fixture.waitForFile("shell-ready"))
        let compositorPID = try fixture.processID("compositor")
        let shellPID = try fixture.processID("shell")

        _ = kill(process.processIdentifier, SIGTERM)
        #expect(waitForExit(process))
        #expect(process.terminationStatus == 128 + SIGTERM)
        #expect(processIsGone(compositorPID))
        #expect(processIsGone(shellPID))
    }

    @Test func malformedReadinessFailsTheSessionWithoutOrphans() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(shellMode: "malformed-readiness")
        #expect(fixture.waitForFile("shell-pid"))
        let compositorPID = try fixture.processID("compositor")
        let shellPID = try fixture.processID("shell")
        #expect(waitForExit(process))
        #expect(process.terminationStatus == 1)
        #expect(fixture.status()?.milestone == .failed)
        #expect(fixture.status()?.detail
            == SessionFailureReason.shellReadinessInvalid.rawValue)
        #expect(processIsGone(compositorPID))
        #expect(processIsGone(shellPID))
    }

    @Test func startupDeadlinePreventsAnInfiniteCompositorStall() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(
            compositorMode: "wait-before-ready",
            startupTimeoutSeconds: 1)
        #expect(fixture.waitForFile("compositor-pid"))
        let compositorPID = try fixture.processID("compositor")
        #expect(waitForExit(process, iterations: 300))
        #expect(process.terminationStatus == 1)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.path("shell-pid").path))
        #expect(fixture.status()?.milestone == .failed)
        #expect(fixture.status()?.detail
            == SessionFailureReason.compositorStartupTimedOut.rawValue)
        #expect(processIsGone(compositorPID))
    }
}
