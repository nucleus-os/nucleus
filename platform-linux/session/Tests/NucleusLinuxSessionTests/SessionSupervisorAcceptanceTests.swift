import Foundation
import Glibc
import NucleusControlClient
import NucleusControlProtocol
import NucleusIPCTransport
import NucleusSessionProtocol
import Testing

private struct SupervisorFixture {
    let directory: URL
    let supervisor: URL
    let configService: URL
    let controlService: URL
    let controlCLI: URL
    let child: URL
    let statusFile: URL
    let configuration: SessionConfiguration
    let sessionID: String

    init(configuration: SessionConfiguration = .defaults) throws {
        let products = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let supervisor = products.appendingPathComponent(
            "NucleusSessionSupervisor")
        let child = products.appendingPathComponent("NucleusSessionFixture")
        let configService = products.appendingPathComponent(
            "NucleusConfigService")
        let controlService = products.appendingPathComponent(
            "NucleusControlService")
        let controlCLI = products.appendingPathComponent("nucleus")
        guard FileManager.default.isExecutableFile(atPath: supervisor.path),
              FileManager.default.isExecutableFile(atPath: child.path),
              FileManager.default.isExecutableFile(atPath: configService.path),
              FileManager.default.isExecutableFile(atPath: controlService.path),
              FileManager.default.isExecutableFile(atPath: controlCLI.path)
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
        self.configService = configService
        self.controlService = controlService
        self.controlCLI = controlCLI
        self.child = child
        self.statusFile = directory.appendingPathComponent("status.bin")
        self.configuration = configuration
        sessionID = String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(8))
    }

    func launch(
        compositorMode: String = "ready-wait",
        shellMode: String = "ready-wait",
        capability: SessionCapabilityDeclaration? = nil,
        capabilityMode: String = "ready-wait",
        startupTimeoutSeconds: Int = 3
    ) throws -> Process {
        let process = Process()
        process.executableURL = supervisor
        var arguments = [
            "--status-file", statusFile.path,
            "--configuration", configuration.hexEncoded,
            "--startup-timeout-seconds", String(startupTimeoutSeconds),
            "--config-service", configService.path,
            "--control-service", controlService.path,
            "--shell", child.path,
        ]
        if let capability {
            let manifest = directory.appendingPathComponent(
                "capability.json")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(capability).write(
                to: manifest,
                options: .atomic)
            arguments += ["--capability-manifest", manifest.path]
        }
        arguments += ["--", child.path]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NUCLEUS_SESSION_FIXTURE_DIRECTORY"] = directory.path
        environment["NUCLEUS_SESSION_FIXTURE_COMPOSITOR_MODE"] = compositorMode
        environment["NUCLEUS_SESSION_FIXTURE_SHELL_MODE"] = shellMode
        environment["NUCLEUS_SESSION_FIXTURE_CAPABILITY_MODE"] =
            capabilityMode
        environment["XDG_RUNTIME_DIR"] = directory.path
        environment["NUCLEUS_SESSION_ID"] = sessionID
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

    var controlSocketPath: String {
        directory
            .appendingPathComponent("nucleus-\(sessionID)")
            .appendingPathComponent("control.sock").path
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

    func childProcessID(
        of supervisor: pid_t,
        executableNamed name: String
    ) throws -> pid_t {
        let children = try String(
            contentsOfFile:
                "/proc/\(supervisor)/task/\(supervisor)/children",
            encoding: .utf8)
        for field in children.split(whereSeparator: \.isWhitespace) {
            guard let processID = pid_t(field),
                  let commandLine = try? Data(
                    contentsOf: URL(
                        fileURLWithPath: "/proc/\(processID)/cmdline")),
                  let terminator = commandLine.firstIndex(of: 0)
            else { continue }
            let executable = String(
                decoding: commandLine[..<terminator], as: UTF8.self)
            if URL(fileURLWithPath: executable).lastPathComponent == name {
                return processID
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    func controlSocketIdentity() throws -> (device: UInt64, inode: UInt64) {
        var metadata = stat()
        guard unsafe lstat(controlSocketPath, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
    }

    func status() -> SessionReadinessMessage? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return SessionReadinessMessage(encoded: Array(data))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func runCLI(_ arguments: [String]) throws -> (
        status: Int32,
        stdout: String,
        stderr: String
    ) {
        let process = Process()
        process.executableURL = controlCLI
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NUCLEUS_CONTROL_SOCKET"] = controlSocketPath
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding:
                    output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self),
            String(
                decoding:
                    errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self))
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
    @Test func optionalCapabilityStartsAfterCoreReadinessAndSharesLifetime()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let declaration = try SessionCapabilityDeclaration(
            identifier: "fixture.optional",
            executable: fixture.child.path,
            restartPolicy: .never,
            maximumRestarts: 0)
        let process = try fixture.launch(capability: declaration)
        #expect(fixture.waitForFile("capability-pid"))
        #expect(fixture.waitForFile("capability-started"))
        #expect(fixture.status() == SessionReadinessMessage(
            role: .shell,
            milestone: .shellReady))
        let identifier = try String(
            contentsOf: fixture.path("capability-identifier"),
            encoding: .utf8)
        #expect(identifier == declaration.identifier)
        let capabilityPID = try #require(pid_t(String(
            contentsOf: fixture.path("capability-pid"),
            encoding: .utf8)))

        _ = kill(process.processIdentifier, SIGTERM)
        #expect(waitForExit(process))
        #expect(process.terminationStatus == 128 + SIGTERM)
        #expect(processIsGone(capabilityPID))
    }

    @Test func capabilityReceivesItsDeclaredGracefulShutdownInterval() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let declaration = try SessionCapabilityDeclaration(
            identifier: "fixture.delayed-shutdown",
            executable: fixture.child.path,
            restartPolicy: .never,
            maximumRestarts: 0,
            shutdownTimeoutSeconds: 2)
        let process = try fixture.launch(
            capability: declaration,
            capabilityMode: "delayed-shutdown")
        #expect(fixture.waitForFile("capability-started"))

        _ = kill(process.processIdentifier, SIGTERM)
        #expect(waitForExit(process))
        #expect(fixture.waitForFile("capability-shutdown-complete"))
    }

    @Test func failedCapabilityRestartsWithoutFailingCoreSession() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let declaration = try SessionCapabilityDeclaration(
            identifier: "fixture.restart",
            executable: fixture.child.path,
            restartPolicy: .onFailure,
            maximumRestarts: 1)
        let process = try fixture.launch(
            capability: declaration,
            capabilityMode: "exit-once-nonzero")
        defer { stop(process) }
        #expect(fixture.waitForFile("capability-restarted"))
        let firstPID = try #require(pid_t(String(
            contentsOf: fixture.path("capability-first-pid"),
            encoding: .utf8)))
        let activePID = try #require(pid_t(String(
            contentsOf: fixture.path("capability-pid"),
            encoding: .utf8)))
        #expect(firstPID != activePID)
        #expect(processIsGone(firstPID))
        #expect(!processIsGone(activePID))
        #expect(process.isRunning)
        #expect(fixture.waitForFile("shell-ready"))
    }

    @Test func cleanCapabilityExitIsNotRestartedByOnFailurePolicy()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let declaration = try SessionCapabilityDeclaration(
            identifier: "fixture.clean-exit",
            executable: fixture.child.path,
            restartPolicy: .onFailure,
            maximumRestarts: 3)
        let process = try fixture.launch(
            capability: declaration,
            capabilityMode: "exit-zero")
        defer { stop(process) }
        #expect(fixture.waitForFile("capability-exited-zero"))
        usleep(100_000)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.path("capability-restarted").path))
        #expect(process.isRunning)
        #expect(fixture.waitForFile("shell-ready"))
    }

    @Test func unavailableOptionalCapabilityDoesNotFailCoreSession()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let declaration = try SessionCapabilityDeclaration(
            identifier: "fixture.unavailable",
            executable: "/does/not/exist/nucleus-capability",
            restartPolicy: .onFailure,
            maximumRestarts: 3)
        let process = try fixture.launch(capability: declaration)
        defer { stop(process) }
        #expect(fixture.waitForFile("shell-ready"))
        usleep(100_000)
        #expect(process.isRunning)
        #expect(fixture.status() == SessionReadinessMessage(
            role: .shell,
            milestone: .shellReady))
    }

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
        let compositorLive = try String(
            contentsOf: fixture.path("compositor-live-configuration"),
            encoding: .utf8)
        let shellLive = try String(
            contentsOf: fixture.path("shell-live-configuration"),
            encoding: .utf8)
        #expect(compositorLive == shellLive)
        #expect(compositorLive.hasSuffix(":1"))
        let compositorDisplay = try String(
            contentsOf: fixture.path("compositor-wayland-display"),
            encoding: .utf8)
        let shellDisplay = try String(
            contentsOf: fixture.path("shell-wayland-display"),
            encoding: .utf8)
        #expect(compositorDisplay != "<missing>")
        #expect(shellDisplay == compositorDisplay)

        let client = ControlClient(path: fixture.controlSocketPath)
        guard case .version(let version) = try client.send(.version) else {
            Issue.record("expected version response")
            return
        }
        #expect(version.configurationService.available)
        #expect(version.configurationService.version
            == "nucleus-configuration-schema 1")
        #expect(version.renderServer.version == "fixture-render-server 1")
        guard case .configuration(let current) =
                try client.send(.configuration)
        else {
            Issue.record("expected configuration response")
            return
        }
        #expect(current.configuredGeneration == 1)
        #expect(current.renderServerAppliedGeneration == 1)
        #expect(current.canonicalSource.contains("\"config_version\""))
        let outputResponse = try client.send(.outputs)
        guard case .outputs(let outputs) = outputResponse else {
            let log = (try? String(
                contentsOf: fixture.path("supervisor.log"),
                encoding: .utf8)) ?? "<unavailable>"
            Issue.record(
                "expected outputs response, got \(outputResponse); log: \(log)")
            return
        }
        #expect(outputs.outputs.map(\.name) == ["fixture-output"])
        #expect(outputs.appliedConfigurationGeneration == 1)
        guard case .binds(let binds) = try client.send(.binds) else {
            Issue.record("expected binds response")
            return
        }
        #expect(!binds.binds.isEmpty)
        #expect(binds.appliedConfigurationGeneration == 1)
        #expect(try client.send(.action(.closeWindow)) == .completed)
    }

    @Test func malformedAndUnauthorizedPeersCannotDisruptTheBroker() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch()
        defer { stop(process) }
        #expect(fixture.waitForFile("shell-ready"))

        let garbage = try PacketConnection.connect(
            path: fixture.controlSocketPath)
        try garbage.send(Array("not json".utf8))
        #expect(throws: (any Error).self) {
            _ = try garbage.receive(
                maximumBytes: 64 * 1024,
                maximumDescriptors: 0)
        }

        let oversized = try PacketConnection.connect(
            path: fixture.controlSocketPath)
        try oversized.send([UInt8](repeating: 0x7b, count: 64 * 1024 + 1))
        #expect(throws: (any Error).self) {
            _ = try oversized.receive(
                maximumBytes: 64 * 1024,
                maximumDescriptors: 0)
        }

        let descriptorBearing = try PacketConnection.connect(
            path: fixture.controlSocketPath)
        let descriptorEnvelope = ControlRequestEnvelope(
            requestID: ControlRequestID(rawValue: 91),
            request: .version)
        let duplicate = dup(STDIN_FILENO)
        defer { if duplicate >= 0 { _ = close(duplicate) } }
        try descriptorBearing.send(
            ControlCoding.packet(descriptorEnvelope),
            descriptors: [duplicate])
        let descriptorReply = try descriptorBearing.receive(
            maximumBytes: 64 * 1024,
            maximumDescriptors: 0)
        let decodedDescriptorReply = try ControlCoding.decoder().decode(
            ControlResponseEnvelope.self,
            from: Data(descriptorReply.bytes))
        #expect(decodedDescriptorReply.response == .error(ControlFailure(
            code: .invalidRequest,
            message: "request carried unexpected descriptors")))

        let unsupported = try PacketConnection.connect(
            path: fixture.controlSocketPath)
        try unsupported.send(ControlCoding.packet(ControlRequestEnvelope(
            protocolVersion: ControlProtocolVersion.current + 1,
            requestID: ControlRequestID(rawValue: 92),
            request: .version)))
        let unsupportedReply = try unsupported.receive(
            maximumBytes: 64 * 1024,
            maximumDescriptors: 0)
        let decodedUnsupported = try ControlCoding.decoder().decode(
            ControlResponseEnvelope.self,
            from: Data(unsupportedReply.bytes))
        guard case .error(let unsupportedFailure) =
                decodedUnsupported.response
        else {
            Issue.record("expected unsupported-version failure")
            return
        }
        #expect(unsupportedFailure.code == .unsupportedVersion)

        let client = ControlClient(path: fixture.controlSocketPath)
        #expect(try client.send(.replaceConfiguration("{}"))
            == .error(ControlFailure(
                code: .unauthorized,
                message: "request requires an elevated capability")))
        guard case .version = try client.send(.version) else {
            Issue.record("broker stopped after invalid peer traffic")
            return
        }
    }

    @Test func supervisorGrantedCapabilityAuthorizesOneMutationPath() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(shellMode: "elevated-replace")
        defer { stop(process) }
        #expect(fixture.waitForFile("elevated-replace-result"))
        let result = try String(
            contentsOf: fixture.path("elevated-replace-result"),
            encoding: .utf8)
        #expect(result == "completed")

        let client = ControlClient(path: fixture.controlSocketPath)
        guard case .configuration(let snapshot) =
                try client.send(.configuration)
        else {
            Issue.record("expected configuration after elevated replacement")
            return
        }
        #expect(snapshot.configuredGeneration == 2)
        #expect(snapshot.renderServerAppliedGeneration == 1)
        #expect(snapshot.canonicalSource.contains("\"config_version\""))
    }

    @Test func commandLineClientIsAOneShotTypedPresentationClient() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch()
        defer { stop(process) }
        #expect(fixture.waitForFile("shell-ready"))

        let version = try fixture.runCLI(["msg", "version"])
        #expect(version.status == 0)
        #expect(version.stdout.contains("fixture-render-server 1"))
        #expect(version.stderr.isEmpty)

        let configuration = try fixture.runCLI(["msg", "config"])
        #expect(configuration.status == 0)
        #expect(configuration.stdout.contains("\"config_version\""))

        let action = try fixture.runCLI(["msg", "close-window"])
        #expect(action.status == 0)
        #expect(action.stdout.isEmpty)
    }

    @Test func shellExitRestartsTheShellWithoutReplacingTheBroker()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(
            shellMode: "exit-after-session-ready-once")
        defer { stop(process) }
        #expect(fixture.waitForFile("compositor-pid"))
        let compositorPID = try fixture.processID("compositor")
        #expect(fixture.waitForFile("shell-restarted"))
        var attachmentCount = 0
        for _ in 0..<500 {
            if let source = try? String(
                contentsOf: fixture.path("shell-attachment-count"),
                encoding: .utf8),
               let count = Int(source),
               count >= 2
            {
                attachmentCount = count
                break
            }
            usleep(10_000)
        }
        #expect(attachmentCount >= 2)
        #expect(try fixture.processID("compositor") == compositorPID)
        let replacementShellPID = try fixture.processID("shell")
        #expect(fixture.waitForFile(
            "shell-policy-endpoint-\(replacementShellPID)"))
        #expect(process.isRunning)
        guard case .version = try ControlClient(
            path: fixture.controlSocketPath).send(.version)
        else {
            Issue.record("control broker did not survive shell restart")
            return
        }
    }

    @Test func compositorExitReattachesANewRenderOwner() throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch(
            compositorMode:
                "exit-after-session-ready-once-with-restart-delay")
        defer { stop(process) }
        #expect(fixture.waitForFile("compositor-exited-once"))
        let socketIdentity = try fixture.controlSocketIdentity()
        var observedAbsence = false
        for _ in 0..<100 {
            let response = try ControlClient(
                path: fixture.controlSocketPath).send(.outputs)
            if case .error(let failure) = response,
               failure.code == .ownerUnavailable
            {
                observedAbsence = true
                break
            }
            usleep(2_000)
        }
        #expect(observedAbsence)
        let restarted = fixture.waitForFile("compositor-restarted")
        if !restarted {
            let log = (try? String(
                contentsOf: fixture.path("supervisor.log"),
                encoding: .utf8)) ?? "<unavailable>"
            Issue.record("render owner did not restart; log: \(log)")
        }
        #expect(restarted)
        #expect(process.isRunning)
        let replacementSocketIdentity = try fixture.controlSocketIdentity()
        #expect(replacementSocketIdentity.device == socketIdentity.device)
        #expect(replacementSocketIdentity.inode == socketIdentity.inode)
        guard case .version(let version) = try ControlClient(
            path: fixture.controlSocketPath).send(.version)
        else {
            Issue.record("control broker did not survive render restart")
            return
        }
        #expect(version.renderServer.available)
    }

    @Test func configurationServiceRestartPreservesThePublicBroker()
        throws
    {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let process = try fixture.launch()
        defer { stop(process) }
        #expect(fixture.waitForFile("shell-ready"))

        let client = ControlClient(path: fixture.controlSocketPath)
        guard case .configuration(let initial) =
                try client.send(.configuration)
        else {
            Issue.record("expected initial configuration snapshot")
            return
        }
        let socketIdentity = try fixture.controlSocketIdentity()
        let configService = try fixture.childProcessID(
            of: process.processIdentifier,
            executableNamed: "NucleusConfigService")
        _ = kill(configService, SIGKILL)

        var replacement: ControlConfigurationSnapshot?
        for _ in 0..<500 {
            if case .configuration(let candidate) =
                    try? client.send(.configuration),
               candidate.configuredEpochHigh != initial.configuredEpochHigh
                || candidate.configuredEpochLow != initial.configuredEpochLow
            {
                replacement = candidate
                break
            }
            usleep(10_000)
        }
        #expect(replacement != nil)
        #expect(process.isRunning)
        let replacementSocketIdentity = try fixture.controlSocketIdentity()
        #expect(replacementSocketIdentity.device == socketIdentity.device)
        #expect(replacementSocketIdentity.inode == socketIdentity.inode)
        var recoveredVersion: ControlVersionInfo?
        for _ in 0..<500 {
            if case .version(let version) = try? client.send(.version),
               version.configurationService.available,
               version.renderServer.available
            {
                recoveredVersion = version
                break
            }
            usleep(10_000)
        }
        #expect(recoveredVersion != nil)
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
