import Foundation
import Glibc
import NucleusAndroidGraphicsContract
import NucleusAndroidGraphicsPlatform
import NucleusAndroidGpuBrokerCore
import NucleusAndroidIPC
import NucleusAndroidIPCC
import NucleusLinuxReactor

private struct BrokerArguments {
    var socketPath: String?
    var diagnose = false
    var renderNode: String?
    var once = false
    var parentPID: Int32?
    var guestWorkload: String?
    var diagnoseGuestWorkload: String?

    static func parse(_ arguments: [String]) throws -> BrokerArguments {
        var result = BrokerArguments()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--socket":
                index += 1
                guard index < arguments.count else { throw CLIError("--socket requires a path") }
                result.socketPath = arguments[index]
            case "--render-node":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("--render-node requires a path")
                }
                result.renderNode = arguments[index]
            case "--diagnose":
                result.diagnose = true
            case "--once":
                result.once = true
            case "--parent-pid":
                index += 1
                guard index < arguments.count,
                      let parentPID = Int32(arguments[index]),
                      parentPID > 1
                else {
                    throw CLIError("--parent-pid requires a process ID greater than 1")
                }
                result.parentPID = parentPID
            case "--guest-workload":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("--guest-workload requires an executable path")
                }
                result.guestWorkload = arguments[index]
            case "--diagnose-guest-workload":
                index += 1
                guard index < arguments.count else {
                    throw CLIError(
                        "--diagnose-guest-workload requires an executable path")
                }
                result.diagnoseGuestWorkload = arguments[index]
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw CLIError("unknown argument: \(arguments[index])")
            }
            index += 1
        }
        if result.once, result.parentPID == nil {
            throw CLIError("--once requires --parent-pid")
        }
        if !result.once, result.parentPID != nil {
            throw CLIError("--parent-pid requires --once")
        }
        return result
    }
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct DiagnosticRecord: Codable {
    var status: String
    var device: BrokerDeviceDiagnostic?
    var drmFormat: String?
    var drmModifier: String?
    var exactDmaBufVulkanImport: Bool
    var explicitSyncSubmission: Bool
    var cpuFenceWaitCount: UInt64
    var implicitSyncOperationCount: UInt64
    var intermediateImageCopyCount: UInt64
    var error: String?
}

private func printUsage() {
    let usage = """
    Usage:
      nucleus-android-gpu-broker --diagnose [--render-node /dev/dri/renderD128]
      nucleus-android-gpu-broker --diagnose-guest-workload PATH
          [--render-node /dev/dri/renderD128]
      nucleus-android-gpu-broker --socket PATH --once --parent-pid PID
          [--guest-workload PATH]
    """
    print(usage)
}

private func defaultSocketPath() throws -> String {
    guard let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
          !runtime.isEmpty
    else { throw CLIError("XDG_RUNTIME_DIR is required when --socket is omitted") }
    let directory = runtime + "/nucleus"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return directory + "/android-gpu-broker.sock"
}

private func runDiagnostics(renderNode: String?) throws {
    let candidates = try DrmDeviceDiscovery.enumerate()
    let selected = renderNode.map { path in candidates.filter { $0.renderNode == path } }
        ?? candidates
    guard !selected.isEmpty else {
        throw CLIError("no DRM render node matched the diagnostic request")
    }
    let records = selected.map { candidate -> DiagnosticRecord in
        do {
            let device = try AndroidGraphicsDevice(candidate: candidate)
            let candidates = device.formatModifiers(format: DrmFormats.xrgb8888)
                .map(\.pair)
                .filter(device.supports)
            guard !candidates.isEmpty else {
                throw GraphicsPlatformError.noCompatibleFormatModifier
            }
            let ring = try device.allocate(BufferAllocationRequest(
                width: 64,
                height: 64,
                feedback: WaylandDmabufFeedback(
                    mainDevice: candidate.renderDevice,
                    tranches: [
                        WaylandDmabufTranche(
                            targetDevice: candidate.renderDevice,
                            scanout: false,
                            formats: candidates)
                    ])))
            let pair = ring.buffers[0].formatModifier
            try ring.buffers[0].render(
                frameNumber: 1,
                acquireTimeline: ring.acquireTimeline,
                acquirePoint: 1)
            return DiagnosticRecord(
                status: "qualified",
                device: device.diagnostic,
                drmFormat: String(format: "0x%08x", pair.format),
                drmModifier: String(format: "0x%016llx", pair.modifier),
                exactDmaBufVulkanImport: true,
                explicitSyncSubmission: true,
                cpuFenceWaitCount: 0,
                implicitSyncOperationCount: 0,
                intermediateImageCopyCount: 0,
                error: nil)
        } catch {
            return DiagnosticRecord(
                status: "rejected",
                device: nil,
                drmFormat: nil,
                drmModifier: nil,
                exactDmaBufVulkanImport: false,
                explicitSyncSubmission: false,
                cpuFenceWaitCount: 0,
                implicitSyncOperationCount: 0,
                intermediateImageCopyCount: 0,
                error: String(describing: error))
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(records), as: UTF8.self))
    guard records.allSatisfy({ $0.status == "qualified" }) else { exit(2) }
}

private struct GuestWorkloadDiagnosticRecord: Codable {
    var status: String
    var device: BrokerDeviceDiagnostic
    var drmFormat: String
    var drmModifier: String
    var bufferCount: Int
    var frameCount: UInt64
    var exactBrokerAllocation: Bool
    var guestAcquireTimelineSignal: Bool
    var releaseTimelineReuse: Bool
    var cpuFenceWaitCount: UInt64
}

private func runGuestWorkloadDiagnostics(
    renderNode: String?,
    executablePath: String
) throws {
    let candidates = try DrmDeviceDiscovery.enumerate()
    let selected: DrmDeviceCandidate
    if let renderNode {
        guard let match = candidates.first(where: {
            $0.renderNode == renderNode
        }) else {
            throw CLIError(
                "no DRM render node matched the guest workload diagnostic")
        }
        selected = match
    } else {
        guard let first = candidates.first else {
            throw CLIError("no DRM render nodes are available")
        }
        selected = first
    }
    let device = try AndroidGraphicsDevice(candidate: selected)
    let formats = device.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .filter(device.supports)
    guard !formats.isEmpty else {
        throw GraphicsPlatformError.noCompatibleFormatModifier
    }
    let ring = try device.allocate(BufferAllocationRequest(
        width: 96,
        height: 72,
        feedback: WaylandDmabufFeedback(
            mainDevice: selected.renderDevice,
            tranches: [WaylandDmabufTranche(
                targetDevice: selected.renderDevice,
                scanout: false,
                formats: formats)])))
    let backend = GfxstreamWorkerBrokerRenderBackend(
        executablePath: executablePath)
    try backend.prepare(ring: ring)
    var priorReleasePoints: [UInt64: UInt64] = [:]
    let frameCount: UInt64 = 24
    for frame in 1...frameCount {
        let buffer = ring.buffers[
            Int((frame - 1) % UInt64(ring.buffers.count))]
        let acquirePoint = frame &* 2 &- 1
        let nextReleasePoint = acquirePoint &+ 1
        let priorReleasePoint = priorReleasePoints[buffer.id]
        let releaseTimeline = ring.releaseTimeline(for: buffer.id)
        if let priorReleasePoint {
            guard releaseTimeline?.signal(point: priorReleasePoint) == true else {
                throw CLIError(
                    "failed to simulate compositor release for buffer reuse")
            }
        }
        try backend.render(
            buffer: buffer,
            frameNumber: frame,
            acquireTimeline: ring.acquireTimeline,
            acquirePoint: acquirePoint,
            releaseTimeline: priorReleasePoint == nil ? nil : releaseTimeline,
            releasePoint: priorReleasePoint ?? 0)
        let deadline = ContinuousClock.now + .seconds(10)
        while ring.acquireTimeline.isSignaled(point: acquirePoint) == false {
            guard ContinuousClock.now < deadline else {
                throw CLIError(
                    "guest workload did not signal its broker acquire point")
            }
            usleep(1_000)
        }
        guard ring.acquireTimeline.isSignaled(point: acquirePoint) == true else {
            throw CLIError("broker acquire timeline query failed")
        }
        priorReleasePoints[buffer.id] = nextReleasePoint
    }
    let pair = ring.buffers[0].formatModifier
    let record = GuestWorkloadDiagnosticRecord(
        status: "qualified",
        device: ring.diagnostic,
        drmFormat: String(format: "0x%08x", pair.format),
        drmModifier: String(format: "0x%016llx", pair.modifier),
        bufferCount: ring.buffers.count,
        frameCount: frameCount,
        exactBrokerAllocation: true,
        guestAcquireTimelineSignal: true,
        releaseTimelineReuse: true,
        cpuFenceWaitCount: 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(record), as: UTF8.self))
}

@MainActor
private func waitUntilReadable(
    reactor: LinuxHostReactor,
    fileDescriptor: Int32,
    token: UInt64
) async throws {
    while true {
        let batch = try await reactor.wait(
            interests: [LinuxReactorInterest(
                token: token,
                fileDescriptor: fileDescriptor,
                events: Int16(POLLIN))],
            timeoutNanoseconds: nil)
        guard let event = batch.events.first(where: { $0.token == token }) else {
            continue
        }
        if let failure = event.failureCode {
            throw CLIError("io_uring poll failed (\(failure))")
        }
        let result = LinuxPollResult(returnedEvents: event.returnedEvents)
        if result.isReadable { return }
        if result.isTerminal {
            throw PacketTransportError.systemCall(
                operation: "io_uring poll",
                errno: ECONNRESET)
        }
    }
}

private func isClosedConnection(_ error: Error) -> Bool {
    guard let transportError = error as? PacketTransportError,
          case .systemCall(_, let code) = transportError
    else {
        return false
    }
    return code == ECONNRESET || code == EPIPE
}

@MainActor
private func runBrokerServer(
    path: String,
    once: Bool,
    guestWorkload: String?
) async throws {
    let listener = try BrokerPacketListener(path: path)
    let reactor = try LinuxHostReactor()
    do {
        repeat {
            try await waitUntilReadable(
                reactor: reactor,
                fileDescriptor: listener.fileDescriptor,
                token: 1)
            let connection = try listener.accept(expectedUserID: UInt32(geteuid()))
            let renderBackend: any BrokerRenderBackend
            if let guestWorkload {
                renderBackend = GfxstreamWorkerBrokerRenderBackend(
                    executablePath: guestWorkload)
            } else {
                renderBackend = DirectVulkanBrokerRenderBackend()
            }
            let session = BrokerSession(
                connection: connection,
                renderBackend: renderBackend)
            while true {
                do {
                    try await waitUntilReadable(
                        reactor: reactor,
                        fileDescriptor: connection.fileDescriptor,
                        token: 2)
                    try session.handleNextPacket()
                } catch {
                    if isClosedConnection(error) { break }
                    throw error
                }
            }
        } while !once
    } catch {
        await reactor.shutdown()
        throw error
    }
    await reactor.shutdown()
}

do {
    let arguments = try BrokerArguments.parse(CommandLine.arguments)
    if arguments.diagnose {
        try runDiagnostics(renderNode: arguments.renderNode)
    } else if let guestWorkload = arguments.diagnoseGuestWorkload {
        try runGuestWorkloadDiagnostics(
            renderNode: arguments.renderNode,
            executablePath: guestWorkload)
    } else {
        if let parentPID = arguments.parentPID,
           nucleus_android_ipc_require_parent_lifetime(
               SIGTERM,
               parentPID) != 0
        {
            throw CLIError(
                "cannot bind the one-shot broker lifetime to its qualifier "
                    + "(errno \(errno))")
        }
        let path = try arguments.socketPath ?? defaultSocketPath()
        try await runBrokerServer(
            path: path,
            once: arguments.once,
            guestWorkload: arguments.guestWorkload)
    }
} catch {
    let message = "nucleus-android-gpu-broker: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
