import Foundation
import Glibc
@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorOverlayScene
import NucleusTextBackend
import NucleusUI
import Testing
@testable import NucleusCompositorShell
@testable import NucleusLinuxAccessibility

private struct BusctlResult {
    var status: Int32
    var standardOutput: String
    var standardError: String
}

private enum AccessibilityFixtureError: Error {
    case daemonAddress
    case registryUnavailable
    case commandTimeout
    case applicationUnavailable
}

private final class PrivateAccessibilityBus {
    let address: String

    private let daemon: Process
    private let registry: Process
    private let daemonOutput: Pipe
    private let daemonError: Pipe
    private let registryOutput: Pipe
    private let registryError: Pipe
    private var stopped = false

    init() throws {
        let daemon = Process()
        let daemonOutput = Pipe()
        let daemonError = Pipe()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/dbus-daemon")
        daemon.arguments = [
            "--session",
            "--nofork",
            "--nopidfile",
            "--print-address=1",
        ]
        daemon.standardOutput = daemonOutput
        daemon.standardError = daemonError
        try daemon.run()
        guard let address = Self.readLine(
            from: daemonOutput.fileHandleForReading.fileDescriptor),
            !address.isEmpty
        else {
            Self.stop(daemon)
            throw AccessibilityFixtureError.daemonAddress
        }

        let registry = Process()
        let registryOutput = Pipe()
        let registryError = Pipe()
        registry.executableURL = URL(
            fileURLWithPath: "/usr/libexec/at-spi2-registryd")
        var environment = ProcessInfo.processInfo.environment
        environment["DBUS_SESSION_BUS_ADDRESS"] = address
        environment["AT_SPI_BUS_ADDRESS"] = address
        registry.environment = environment
        registry.standardOutput = registryOutput
        registry.standardError = registryError
        do {
            try registry.run()
        } catch {
            Self.stop(daemon)
            throw error
        }

        self.daemon = daemon
        self.registry = registry
        self.daemonOutput = daemonOutput
        self.daemonError = daemonError
        self.registryOutput = registryOutput
        self.registryError = registryError
        self.address = address

        guard waitForRegistryName() else {
            stop()
            throw AccessibilityFixtureError.registryUnavailable
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        Self.stop(registry)
        Self.stop(daemon)
    }

    @MainActor
    func waitForApplication(
        pumping pump: @escaping () -> Void
    ) throws -> (name: String, listing: String) {
        for _ in 0..<40 {
            let result = try registryApplications(pumping: pump)
            if result.status == 0,
                let name = Self.firstUniqueName(in: result.standardOutput)
            {
                return (name, result.standardOutput)
            }
            pump()
            usleep(10_000)
        }
        throw AccessibilityFixtureError.applicationUnavailable
    }

    @MainActor
    func registryApplications(
        pumping pump: (() -> Void)?
    ) throws -> BusctlResult {
        try call(
            destination: "org.a11y.atspi.Registry",
            path: "/org/a11y/atspi/accessible/root",
            interface: "org.a11y.atspi.Accessible",
            member: "GetChildren",
            pumping: pump)
    }

    @MainActor
    func call(
        destination: String,
        path: String,
        interface: String,
        member: String,
        signature: String? = nil,
        arguments: [String] = [],
        pumping pump: (() -> Void)?
    ) throws -> BusctlResult {
        var command = [
            "--address=\(address)",
            "--no-pager",
            "--timeout=2",
            "--",
            "call",
            destination,
            path,
            interface,
            member,
        ]
        if let signature {
            command.append(signature)
            command.append(contentsOf: arguments)
        }
        return try runBusctl(command, pumping: pump)
    }

    @MainActor
    private func runBusctl(
        _ arguments: [String],
        pumping pump: (() -> Void)?
    ) throws -> BusctlResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()

        for _ in 0..<10_000 where process.isRunning {
            pump?()
            usleep(250)
        }
        guard !process.isRunning else {
            Self.stop(process)
            throw AccessibilityFixtureError.commandTimeout
        }
        process.waitUntilExit()
        return BusctlResult(
            status: process.terminationStatus,
            standardOutput: Self.availableText(
                from: output.fileHandleForReading),
            standardError: Self.availableText(
                from: error.fileHandleForReading))
    }

    private func waitForRegistryName() -> Bool {
        for _ in 0..<1_000 {
            if !registry.isRunning { return false }
            let result = try? Self.runToCompletion(
                executable: "/usr/bin/busctl",
                arguments: [
                    "--address=\(address)",
                    "--no-pager",
                    "status",
                    "org.a11y.atspi.Registry",
                ])
            if result?.status == 0 { return true }
            usleep(1_000)
        }
        return false
    }

    private static func firstUniqueName(in output: String) -> String? {
        let quoted = output.components(separatedBy: "\"")
        return quoted.first { $0.hasPrefix(":") }
    }

    private static func runToCompletion(
        executable: String,
        arguments: [String]
    ) throws -> BusctlResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        waitForExit(process)
        return BusctlResult(
            status: process.terminationStatus,
            standardOutput: availableText(
                from: output.fileHandleForReading),
            standardError: availableText(
                from: error.fileHandleForReading))
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<1_000 where process.isRunning {
            usleep(1_000)
        }
        if process.isRunning {
            _ = Glibc.kill(process.processIdentifier, SIGKILL)
        }
        waitForExit(process)
    }

    private static func waitForExit(_ process: Process) {
        while process.isRunning { usleep(250) }
        process.waitUntilExit()
    }

    private static func readLine(from descriptor: Int32) -> String? {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
        guard poll(&pollDescriptor, 1, 2_000) > 0 else { return nil }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while Glibc.read(descriptor, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func availableText(from handle: FileHandle) -> String {
        String(
            data: handle.availableData,
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ScopedEnvironmentVariable {
    private let name: String
    private let previousValue: String?

    init(name: String, value: String) {
        self.name = name
        previousValue = getenv(name).map { String(cString: $0) }
        setenv(name, value, 1)
    }

    func restore() {
        if let previousValue {
            setenv(name, previousValue, 1)
        } else {
            unsetenv(name)
        }
    }
}

@MainActor
@Suite(.serialized)
struct ShellServicesAccessibilityTests {
    @Test
    func overlayCompositionRegistersPublishesAndTearsDownOneApplication()
        throws
    {
        let privateBus = try PrivateAccessibilityBus()
        let environment = ScopedEnvironmentVariable(
            name: "AT_SPI_BUS_ADDRESS",
            value: privateBus.address)
        defer {
            environment.restore()
            privateBus.stop()
        }
        let baseline = AtSPIService.liveResourceCounts
        let textSystem = TextSystem()
        SkiaTextLayoutBackend.install(in: textSystem)
        let context = UIContext(services: UIHostServices(
            textSystem: textSystem,
            pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
            imageSourceResolver: .directResourcesOnly,
            diagnosticSink: { _ in }))

        try context.construct {
            _ = nucleus_compositor_overlay_runtime_clear_host()
            let shellServices = ShellServices()
            defer { shellServices.shutdown() }
            #expect(shellServices.installOverlay(
                commitSink: InMemoryCommitSink(),
                services: context.services))

            let application = try privateBus.waitForApplication {
                _ = shellServices.accessibilityReactorSource?.process()
            }
            #expect(application.listing.contains(
                "/org/a11y/atspi/accessible/root"))
            #expect(AtSPIService.liveResourceCounts == .init(
                connections: baseline.connections + 1,
                fallbackSlots: baseline.fallbackSlots + 1))

            let name = try privateBus.call(
                destination: application.name,
                path: "/org/a11y/atspi/accessible/root",
                interface: "org.freedesktop.DBus.Properties",
                member: "Get",
                signature: "ss",
                arguments: [
                    "org.a11y.atspi.Accessible",
                    "Name",
                ],
                pumping: {
                    _ = shellServices.accessibilityReactorSource?.process()
                })
            #expect(name.status == 0)
            #expect(name.standardOutput.contains("Nucleus Compositor"))

            publishGlobalShellOverlayScene()
            let role = try privateBus.call(
                destination: application.name,
                path: "/org/a11y/atspi/accessible/root",
                interface: "org.a11y.atspi.Accessible",
                member: "GetRole",
                pumping: {
                    _ = shellServices.accessibilityReactorSource?.process()
                })
            #expect(role.status == 0)

            shellServices.shutdown()
            shellServices.shutdown()
            #expect(AtSPIService.liveResourceCounts == baseline)
            let deregistered = try privateBus.registryApplications(
                pumping: nil)
            #expect(deregistered.status == 0)
            #expect(!deregistered.standardOutput.contains(application.name))
        }
        #expect(AtSPIService.liveResourceCounts == baseline)
    }
}
