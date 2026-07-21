import Foundation
import Glibc
@testable import NucleusLinuxAccessibility

struct BusctlResult {
    var status: Int32
    var standardOutput: String
    var standardError: String
}

/// Process-owned D-Bus daemon and AT-SPI registry for live transport tests.
final class PrivateAccessibilityBus {
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
            daemon.terminate()
            daemon.waitUntilExit()
            throw AtSPIServiceError(
                operation: "reading private accessibility bus address",
                code: -EIO)
        }

        let registry = Process()
        let registryOutput = Pipe()
        let registryError = Pipe()
        registry.executableURL = URL(
            fileURLWithPath: "/usr/libexec/at-spi2-registryd")
        registry.arguments = []
        var environment = ProcessInfo.processInfo.environment
        environment["DBUS_SESSION_BUS_ADDRESS"] = address
        environment["AT_SPI_BUS_ADDRESS"] = address
        registry.environment = environment
        registry.standardOutput = registryOutput
        registry.standardError = registryError
        do {
            try registry.run()
        } catch {
            daemon.terminate()
            daemon.waitUntilExit()
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
            let detail = Self.availableText(
                from: registryError.fileHandleForReading)
            stop()
            throw AtSPIServiceError(
                operation: detail.isEmpty
                    ? "waiting for private AT-SPI registry"
                    : "private AT-SPI registry: \(detail)",
                code: -ETIMEDOUT)
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
    func call(
        adapter: AtSPIService?,
        destination: String,
        path: String,
        interface: String,
        member: String,
        signature: String? = nil,
        arguments: [String] = []
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
        return try runBusctl(command, pumping: adapter)
    }

    @MainActor
    func waitUntilReady(
        _ service: AtSPIService,
        maximumIterations: Int = 10_000
    ) throws {
        for _ in 0..<maximumIterations {
            _ = service.process()
            if service.isReady { return }
            usleep(250)
        }
        throw AtSPIServiceError(
            operation: "waiting for AT-SPI service readiness",
            code: -ETIMEDOUT)
    }

    @MainActor
    func registryApplications(
        pumping adapter: AtSPIService?
    ) throws -> BusctlResult {
        try call(
            adapter: adapter,
            destination: "org.a11y.atspi.Registry",
            path: "/org/a11y/atspi/accessible/root",
            interface: "org.a11y.atspi.Accessible",
            member: "GetChildren")
    }

    @MainActor
    func monitorSignals(
        adapter: AtSPIService,
        count: Int,
        interface: String? = nil,
        member: String? = nil,
        trigger: () throws -> Void
    ) throws -> BusctlResult {
        precondition(count > 0)
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        var match = "type='signal',sender='\(adapter.applicationBusName)'"
        if let interface {
            match += ",interface='\(interface)'"
        }
        if let member {
            match += ",member='\(member)'"
        }
        process.arguments = [
            "--address=\(address)",
            "--no-pager",
            "--limit-messages=\(count)",
            "--match=\(match)",
            "monitor",
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()

        // Establish the monitor connection before the trigger publishes. The
        // adapter pump keeps the production connection live while busctl
        // completes its Hello exchange.
        for _ in 0..<40 {
            _ = adapter.process()
            usleep(250)
        }
        do {
            try trigger()
        } catch {
            Self.stop(process)
            throw error
        }

        var iterations = 0
        while process.isRunning, iterations < 10_000 {
            _ = adapter.process()
            usleep(250)
            iterations += 1
        }
        guard !process.isRunning else {
            process.terminate()
            Self.waitForExit(process)
            throw AtSPIServiceError(
                operation: "waiting for AT-SPI signals",
                code: -ETIMEDOUT)
        }
        process.waitUntilExit()
        return BusctlResult(
            status: process.terminationStatus,
            standardOutput: Self.availableText(
                from: output.fileHandleForReading),
            standardError: Self.availableText(
                from: error.fileHandleForReading))
    }

    @MainActor
    func runBusctl(
        _ arguments: [String],
        pumping adapter: AtSPIService?
    ) throws -> BusctlResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()

        var iterations = 0
        while process.isRunning, iterations < 10_000 {
            if let adapter {
                _ = adapter.process()
            }
            usleep(250)
            iterations += 1
        }
        guard !process.isRunning else {
            process.terminate()
            Self.waitForExit(process)
            throw AtSPIServiceError(
                operation: "waiting for busctl",
                code: -ETIMEDOUT)
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
        while process.isRunning {
            usleep(250)
        }
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

struct ScopedEnvironmentVariable {
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
