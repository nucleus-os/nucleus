import Foundation
import Glibc
import NucleusAndroidSurfaceProbeCore

public struct PresentationQualificationConfiguration: Sendable {
    public var brokerExecutable: String
    public var guestWorkloadExecutable: String
    public var expectedRenderDevice: String
    public var waylandSocket: String
    public var outputDirectory: URL
    public var supportBundle: URL
    public var frameCount: UInt64

    public init(
        brokerExecutable: String,
        guestWorkloadExecutable: String,
        expectedRenderDevice: String,
        waylandSocket: String = "wayland-0",
        outputDirectory: URL,
        supportBundle: URL,
        frameCount: UInt64
    ) {
        self.brokerExecutable = brokerExecutable
        self.guestWorkloadExecutable = guestWorkloadExecutable
        self.expectedRenderDevice = expectedRenderDevice
        self.waylandSocket = waylandSocket
        self.outputDirectory = outputDirectory
        self.supportBundle = supportBundle
        self.frameCount = frameCount
    }
}

public struct PresentationQualificationSummary: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var status: String
    public var generatedAt: String
    public var supportBundle: String
    public var requestedRenderDevice: String
    public var technicalPass: Bool
    public var brokerExitCode: Int32?
    public var failures: [String]
    public var presentation: SurfaceProbeReport?

    public init(
        status: String,
        generatedAt: String,
        supportBundle: String,
        requestedRenderDevice: String,
        technicalPass: Bool,
        brokerExitCode: Int32?,
        failures: [String],
        presentation: SurfaceProbeReport?
    ) {
        self.schemaVersion = 2
        self.status = status
        self.generatedAt = generatedAt
        self.supportBundle = supportBundle
        self.requestedRenderDevice = requestedRenderDevice
        self.technicalPass = technicalPass
        self.brokerExitCode = brokerExitCode
        self.failures = failures
        self.presentation = presentation
    }
}

public enum PresentationQualificationValidator {
    public static let requiredWaylandStages = Set([
        "wayland.buffer-import",
        "broker.guest-submission-accepted",
        "wayland.commit",
        "wayland.presented",
        "wayland.release-observed",
        "wayland.surface-teardown.complete",
    ])

    public static let requiredGuestStages = Set([
        "buffer.allocate-import.complete",
        "buffer.guest-submit.complete",
        "buffer.release-sync-file.export",
        "buffer.acquire-sync-file.import",
        "buffer.release-ready.reuse",
        "guest.workload-destruction.complete",
    ])

    public static func failures(
        report: SurfaceProbeReport?,
        expectedRenderDevice: String,
        frameCount: UInt64,
        brokerExitCode: Int32?,
        guestStages: Set<String>
    ) -> [String] {
        var failures: [String] = []
        guard let report else {
            failures.append("the Wayland presentation probe did not produce a report")
            return failures
        }
        guard let device = report.brokerDevice else {
            failures.append("the broker did not report its physical GPU identity")
            return failures
        }

        if brokerExitCode != 0 {
            failures.append(
                "the one-shot Android GPU broker exited with status "
                    + (brokerExitCode.map(String.init) ?? "unknown"))
        }
        if device.renderNode != expectedRenderDevice {
            failures.append(
                "the broker selected \(device.renderNode), expected "
                    + expectedRenderDevice)
        }
        if !device.hardwareDriver {
            failures.append("the broker selected a software Vulkan device")
        }
        if report.allocatedBufferCount != 3 {
            failures.append(
                "the broker allocated \(report.allocatedBufferCount) buffers, expected 3")
        }
        if report.submittedFrameCount != frameCount {
            failures.append(
                "submitted \(report.submittedFrameCount) frames, expected \(frameCount)")
        }
        if report.presentedFrameCount != frameCount {
            failures.append(
                "presented \(report.presentedFrameCount) frames, expected \(frameCount)")
        }
        if report.discardedFrameCount != 0 {
            failures.append(
                "the compositor discarded \(report.discardedFrameCount) frames")
        }
        if device.renderDevice != report.feedback.mainDevice
            && device.primaryDevice != report.feedback.mainDevice
        {
            failures.append(
                "Wayland dma-buf feedback and the broker identify different GPUs")
        }

        let waylandStages = Set(report.lifecycleEvents.map(\.stage))
        let missingWayland = requiredWaylandStages.subtracting(waylandStages).sorted()
        if !missingWayland.isEmpty {
            failures.append(
                "missing Wayland lifecycle stages: "
                    + missingWayland.joined(separator: ", "))
        }
        let missingGuest = requiredGuestStages.subtracting(guestStages).sorted()
        if !missingGuest.isEmpty {
            failures.append(
                "missing gfxstream lifecycle stages: "
                    + missingGuest.joined(separator: ", "))
        }
        return failures
    }
}

@MainActor
public final class PresentationQualificationRunner {
    private struct BrokerHandles {
        let process: Process
        let standardOutput: FileHandle
        let standardError: FileHandle
    }

    private struct GuestLifecycleRecord: Decodable {
        var component: String
        var stage: String
    }

    private let configuration: PresentationQualificationConfiguration

    public init(configuration: PresentationQualificationConfiguration) {
        self.configuration = configuration
    }

    public func run() async throws -> PresentationQualificationSummary {
        try FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true)

        let brokerSocket = configuration.outputDirectory
            .appendingPathComponent("android-gpu-broker.sock")
        let brokerStandardOutput = configuration.outputDirectory
            .appendingPathComponent("broker.stdout.log")
        let brokerTrace = configuration.outputDirectory
            .appendingPathComponent("broker.trace.log")
        let presentationPath = configuration.outputDirectory
            .appendingPathComponent("presentation.json")
        let guestLifecyclePath = configuration.outputDirectory
            .appendingPathComponent("guest-lifecycle.jsonl")

        var broker: BrokerHandles?
        var brokerExitCode: Int32?
        var report: SurfaceProbeReport?
        var runtimeFailures: [String] = []

        do {
            broker = try launchBroker(
                socket: brokerSocket,
                standardOutput: brokerStandardOutput,
                standardError: brokerTrace)
            try await waitForSocket(
                brokerSocket,
                process: broker!.process,
                timeout: .seconds(10))
            report = try await AndroidSurfaceProbe(configuration:
                SurfaceProbeConfiguration(
                    waylandSocket: configuration.waylandSocket,
                    brokerSocket: brokerSocket.path,
                    width: 1280,
                    height: 720,
                    frameCount: configuration.frameCount,
                    eventTimeoutMilliseconds: 10_000)
            ).run()
            brokerExitCode = try await waitForExit(
                broker!.process,
                timeout: .seconds(15))
        } catch {
            runtimeFailures.append(String(describing: error))
            if let process = broker?.process {
                brokerExitCode = await stop(process)
            }
        }

        try? broker?.standardOutput.close()
        try? broker?.standardError.close()

        let lifecycle = try extractGuestLifecycle(
            from: brokerTrace,
            to: guestLifecyclePath)
        let guestStages = Set(lifecycle.map(\.stage))
        var failures = runtimeFailures
        failures += PresentationQualificationValidator.failures(
            report: report,
            expectedRenderDevice: configuration.expectedRenderDevice,
            frameCount: configuration.frameCount,
            brokerExitCode: brokerExitCode,
            guestStages: guestStages)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let report {
            try encoder.encode(report).write(to: presentationPath, options: .atomic)
        } else {
            try Data("null\n".utf8).write(to: presentationPath, options: .atomic)
        }

        let technicalPass = failures.isEmpty
        let summary = PresentationQualificationSummary(
            status: technicalPass ? "qualified" : "rejected",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            supportBundle: configuration.supportBundle.path,
            requestedRenderDevice: configuration.expectedRenderDevice,
            technicalPass: technicalPass,
            brokerExitCode: brokerExitCode,
            failures: failures,
            presentation: report)
        try encoder.encode(summary).write(
            to: configuration.outputDirectory.appendingPathComponent("summary.json"),
            options: .atomic)
        return summary
    }

    private func launchBroker(
        socket: URL,
        standardOutput: URL,
        standardError: URL
    ) throws -> BrokerHandles {
        try Data().write(to: standardOutput, options: .atomic)
        try Data().write(to: standardError, options: .atomic)
        let outputHandle = try FileHandle(forWritingTo: standardOutput)
        let errorHandle = try FileHandle(forWritingTo: standardError)
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.brokerExecutable)
            process.arguments = [
                "--socket", socket.path,
                "--once",
                "--guest-workload", configuration.guestWorkloadExecutable,
            ]
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            return BrokerHandles(
                process: process,
                standardOutput: outputHandle,
                standardError: errorHandle)
        } catch {
            try? outputHandle.close()
            try? errorHandle.close()
            throw error
        }
    }

    private func waitForSocket(
        _ socket: URL,
        process: Process,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Self.isSocket(socket.path) { return }
            guard process.isRunning else {
                process.waitUntilExit()
                throw PresentationQualificationFailure.brokerExitedBeforeReady(
                    process.terminationStatus)
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }
        throw PresentationQualificationFailure.brokerStartupTimedOut
    }

    private func waitForExit(
        _ process: Process,
        timeout: Duration
    ) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else {
            _ = await stop(process)
            throw PresentationQualificationFailure.brokerShutdownTimedOut
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func stop(_ process: Process) async -> Int32? {
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await ContinuousClock().sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func extractGuestLifecycle(
        from trace: URL,
        to destination: URL
    ) throws -> [GuestLifecycleRecord] {
        guard let data = try? Data(contentsOf: trace) else {
            try Data().write(to: destination, options: .atomic)
            return []
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter {
                $0.hasPrefix(
                    #"{"component":"nucleus-android-gfxstream-workload""#)
            }
        let output = lines.isEmpty
            ? Data()
            : Data((lines.joined(separator: "\n") + "\n").utf8)
        try output.write(to: destination, options: .atomic)
        let decoder = JSONDecoder()
        return lines.compactMap {
            try? decoder.decode(
                GuestLifecycleRecord.self,
                from: Data($0.utf8))
        }
    }

    private static func isSocket(_ path: String) -> Bool {
        var information = stat()
        guard lstat(path, &information) == 0 else { return false }
        return information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }
}

public enum PresentationQualificationFailure: Error, CustomStringConvertible {
    case brokerExitedBeforeReady(Int32)
    case brokerStartupTimedOut
    case brokerShutdownTimedOut

    public var description: String {
        switch self {
        case .brokerExitedBeforeReady(let status):
            "the Android GPU broker exited before creating its socket (status \(status))"
        case .brokerStartupTimedOut:
            "the Android GPU broker did not create its socket before the deadline"
        case .brokerShutdownTimedOut:
            "the Android GPU broker did not shut down after presentation completed"
        }
    }
}
