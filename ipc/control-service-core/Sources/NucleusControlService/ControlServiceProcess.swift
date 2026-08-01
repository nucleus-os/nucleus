import Foundation
import Glibc
import NucleusControlProtocol
import NucleusIPCTransport
import NucleusLinuxReactor
import NucleusLinuxSessionC
import NucleusSessionProtocol

private enum ControlServiceFailure: Error, CustomStringConvertible {
    case argument(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .argument(let value): value
        case .system(let operation, let code):
            "\(operation) failed: errno \(code)"
        }
    }
}

private enum PendingOwner {
    case configuration
    case renderServer(OwnerControlRequestID)
}

private struct PendingRequest {
    let connection: PacketConnection
    let requestID: ControlRequestID
    let owner: PendingOwner
    let deadlineNanoseconds: UInt64
}

func isSupervisorAttachmentClosure(_ error: Error) -> Bool {
    guard case .systemCall(_, let code) = error as? IPCTransportError
    else { return false }
    return code == ECONNRESET || code == EPIPE
}

@MainActor
private final class ControlServiceProcess {
    private static let maximumRequestBytes = 64 * 1024
    private static let requestTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let listener: PacketListener
    private var configuration: PacketConnection
    private var renderServer: PacketConnection
    private let attachments: SupervisorAttachmentChannel
    private let elevatedCapability: Int32?
    private let signalDescriptor: Int32
    private let reactor: LinuxHostReactor
    private var clients: [PacketConnection] = []
    private var pendingConfiguration: PendingRequest?
    private var pendingRenderServer: PendingRequest?
    private var renderAvailability = ControlOwnerAvailability(available: false)
    private var configurationAvailability =
        ControlOwnerAvailability(available: false)
    private var renderIdentity: RenderServerControlPublication?
    private var nextOwnerRequestID: UInt64 = 1
    private var configurationAvailable = true
    private var renderServerAvailable = true

    init(
        socketDirectory: String,
        configurationDescriptor: Int32,
        renderServerDescriptor: Int32,
        attachmentDescriptor: Int32,
        elevatedCapability: Int32?
    ) throws {
        try Self.validateSocketDirectory(socketDirectory)
        listener = try PacketListener(
            path: socketDirectory + "/control.sock",
            mode: 0o600,
            nonblocking: true)
        configuration = PacketConnection(owning: configurationDescriptor)
        renderServer = PacketConnection(owning: renderServerDescriptor)
        attachments = SupervisorAttachmentChannel(
            owning: attachmentDescriptor)
        self.elevatedCapability = elevatedCapability
        let signalDescriptor = nucleus_session_create_signal_fd()
        guard signalDescriptor >= 0 else {
            throw ControlServiceFailure.system("signalfd", errno)
        }
        self.signalDescriptor = signalDescriptor
        reactor = try LinuxHostReactor(queueDepth: 64)
    }

    deinit {
        _ = close(signalDescriptor)
        if let elevatedCapability { _ = close(elevatedCapability) }
    }

    func run(readiness: SessionReadinessReporter?) async throws -> Int32 {
        try readiness?.report(.controlServiceReady)
        while true {
            expirePendingRequests()
            var interests = [
                LinuxReactorInterest(
                    token: 1,
                    fileDescriptor: listener.fileDescriptor,
                    events: Int16(POLLIN)),
                LinuxReactorInterest(
                    token: 4,
                    fileDescriptor: signalDescriptor,
                    events: Int16(POLLIN)),
                LinuxReactorInterest(
                    token: 5,
                    fileDescriptor: attachments.fileDescriptor,
                    events: Int16(POLLIN)),
            ]
            if configurationAvailable {
                interests.append(
                    LinuxReactorInterest(
                        token: 2,
                        fileDescriptor: configuration.fileDescriptor,
                        events: Int16(POLLIN)))
            }
            if renderServerAvailable {
                interests.append(
                    LinuxReactorInterest(
                        token: 3,
                        fileDescriptor: renderServer.fileDescriptor,
                        events: Int16(POLLIN)))
            }
            interests += clients.map {
                LinuxReactorInterest(
                    token: Self.clientToken($0.fileDescriptor),
                    fileDescriptor: $0.fileDescriptor,
                    events: Int16(POLLIN))
            }
            let batch = try await reactor.wait(
                interests: interests,
                timeoutNanoseconds: 250_000_000)
            // Owner-channel terminal events describe the descriptors captured
            // for this reactor wait. Process them before supervisor attachment
            // packets so a stale HUP cannot overwrite the replacement state.
            for event in batch.events where event.token != 5 {
                let result = LinuxPollResult(
                    returnedEvents: event.returnedEvents)
                switch event.token {
                case 1:
                    if result.isReadable { acceptClients() }
                case 2:
                    if result.isReadable {
                        receiveConfigurationResponse()
                    } else if result.isTerminal {
                        configurationAvailable = false
                        configurationAvailability =
                            ControlOwnerAvailability(available: false)
                        failPendingConfiguration()
                    }
                case 3:
                    if result.isReadable {
                        receiveRenderServerPublication()
                    } else if result.isTerminal {
                        renderServerUnavailable("owner channel became terminal")
                    }
                case 4:
                    if result.isReadable, consumeTerminationSignal() {
                        await reactor.shutdown()
                        return 0
                    }
                default:
                    guard
                        let index = clients.firstIndex(where: {
                            Self.clientToken($0.fileDescriptor) == event.token
                        })
                    else { continue }
                    let connection = clients.remove(at: index)
                    if result.isReadable { processClient(connection) }
                }
            }
            for event in batch.events where event.token == 5 {
                let result = LinuxPollResult(
                    returnedEvents: event.returnedEvents)
                if result.isReadable {
                    guard processAttachment() else {
                        await reactor.shutdown()
                        return 0
                    }
                } else if result.isTerminal {
                    await reactor.shutdown()
                    return 0
                }
            }
        }
    }

    private func processAttachment() -> Bool {
        do {
            let attachment = try attachments.receive()
            switch attachment.role {
            case .configurationControl:
                failPendingConfiguration()
                configuration = PacketConnection(
                    owning: attachment.descriptor.take())
                configurationAvailable = true
                configurationAvailability =
                    ControlOwnerAvailability(available: false)
            case .renderServerControl:
                renderServerUnavailable("owner endpoint replaced")
                renderServer = PacketConnection(
                    owning: attachment.descriptor.take())
                renderServerAvailable = true
                renderAvailability = ControlOwnerAvailability(
                    available: false)
                renderIdentity = nil
            case .renderServerConfigurationSubscriber,
                .shellConfigurationSubscriber:
                diagnostic(
                    "configuration subscriber sent to control service")
            }
        } catch {
            if isSupervisorAttachmentClosure(error) {
                return false
            }
            diagnostic("supervisor attachment failed: \(error)")
        }
        return true
    }

    private func acceptClients() {
        while true {
            do {
                let connection = try listener.accept()
                guard connection.peerCredentials?.userID == geteuid() else {
                    continue
                }
                guard Self.makeNonblocking(connection.fileDescriptor) else {
                    continue
                }
                clients.append(connection)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    return
                }
                return
            } catch {
                return
            }
        }
    }

    private func processClient(_ connection: PacketConnection) {
        let packet: ReceivedPacket
        do {
            packet = try connection.receive(
                maximumBytes: Self.maximumRequestBytes,
                maximumDescriptors: 1)
        } catch {
            return
        }
        let envelope: ControlRequestEnvelope
        do {
            envelope = try ControlCoding.decoder().decode(
                ControlRequestEnvelope.self,
                from: Data(packet.bytes))
        } catch {
            return
        }
        guard envelope.protocolVersion == ControlProtocolVersion.current else {
            respond(
                .error(
                    ControlFailure(
                        code: .unsupportedVersion,
                        message: "unsupported control protocol version")),
                requestID: envelope.requestID,
                to: connection)
            return
        }
        let needsElevation: Bool
        if case .replaceConfiguration = envelope.request {
            needsElevation = true
        } else {
            needsElevation = false
        }
        guard packet.descriptors.count == (needsElevation ? 1 : 0) else {
            respond(
                .error(
                    ControlFailure(
                        code: packet.descriptors.isEmpty
                            ? .unauthorized : .invalidRequest,
                        message: packet.descriptors.isEmpty
                            ? "request requires an elevated capability"
                            : "request carried unexpected descriptors")),
                requestID: envelope.requestID,
                to: connection)
            return
        }
        let elevated =
            packet.descriptors.first.map {
                capabilityMatches($0.rawValue)
            } ?? false
        let route = ControlRouting.route(
            envelope.request,
            configurationAvailability: configurationAvailability,
            renderServerAvailability: renderAvailability,
            hasElevatedCapability: elevated)
        switch route {
        case .local(let response):
            respond(response, requestID: envelope.requestID, to: connection)
        case .unauthorized:
            respond(
                .error(
                    ControlFailure(
                        code: .unauthorized,
                        message: "elevated capability was not granted")),
                requestID: envelope.requestID,
                to: connection)
        case .configuration(let request):
            guard pendingConfiguration == nil else {
                respondBusy(requestID: envelope.requestID, to: connection)
                return
            }
            do {
                try configuration.send(
                    ConfigurationSubscriptionCodec.encode(
                        ConfigurationSubscriptionEnvelope(payload: request)))
                pendingConfiguration = PendingRequest(
                    connection: connection,
                    requestID: envelope.requestID,
                    owner: .configuration,
                    deadlineNanoseconds: Self.now()
                        + Self.requestTimeoutNanoseconds)
            } catch {
                configurationAvailable = false
                respondUnavailable(
                    requestID: envelope.requestID, to: connection)
            }
        case .renderServer(let request):
            guard pendingRenderServer == nil else {
                respondBusy(requestID: envelope.requestID, to: connection)
                return
            }
            let ownerID = OwnerControlRequestID(rawValue: nextOwnerRequestID)
            nextOwnerRequestID &+= 1
            do {
                try renderServer.send(
                    OwnerControlCodec.encode(
                        RenderServerControlRequestEnvelope(
                            requestID: ownerID,
                            request: request)))
                pendingRenderServer = PendingRequest(
                    connection: connection,
                    requestID: envelope.requestID,
                    owner: .renderServer(ownerID),
                    deadlineNanoseconds: Self.now()
                        + Self.requestTimeoutNanoseconds)
            } catch {
                renderServerUnavailable("owner request send failed: \(error)")
                respondUnavailable(
                    requestID: envelope.requestID, to: connection)
            }
        }
    }

    private func receiveConfigurationResponse() {
        do {
            let packet = try configuration.receive(
                maximumBytes:
                    ConfigurationSubscriptionCodec.maximumMessageBytes,
                maximumDescriptors: 0)
            let envelope = try ConfigurationSubscriptionCodec.decode(
                ConfigurationPublication.self, from: packet.bytes)
            guard envelope.protocolVersion == SessionProtocolVersion.current
            else {
                if let pending = pendingConfiguration {
                    respondInternal(request: pending)
                }
                pendingConfiguration = nil
                return
            }
            let publication = envelope.payload
            configurationAvailability = ControlOwnerAvailability(
                available: true,
                version: "nucleus-configuration-schema "
                    + String(publication.schemaVersion))
            if publication.kind == .ready {
                return
            }
            guard let pending = pendingConfiguration else {
                configurationAvailable = false
                configurationAvailability =
                    ControlOwnerAvailability(available: false)
                return
            }
            respond(
                publicConfigurationResponse(publication),
                requestID: pending.requestID,
                to: pending.connection)
        } catch {
            configurationAvailable = false
            configurationAvailability =
                ControlOwnerAvailability(available: false)
            if let pending = pendingConfiguration {
                respondUnavailable(
                    requestID: pending.requestID, to: pending.connection)
            }
        }
        pendingConfiguration = nil
    }

    private func publicConfigurationResponse(
        _ publication: ConfigurationPublication
    ) -> ControlResponse {
        switch publication.kind {
        case .exported:
            return .configuration(
                ControlConfigurationSnapshot(
                    canonicalSource: publication.exportedSource ?? "",
                    configuredEpochHigh: publication.epoch.high,
                    configuredEpochLow: publication.epoch.low,
                    configuredGeneration: publication.generation.rawValue,
                    renderServerAppliedGeneration:
                        renderIdentity?.appliedConfigurationGeneration.rawValue))
        case .validated:
            return .validation(publication.diagnostics.map(\.message))
        case .accepted:
            return .completed
        case .rejected:
            return .error(
                ControlFailure(
                    code: .rejected,
                    message: publication.rejection ?? "request rejected"))
        case .ready, .snapshot, .diagnostics:
            return .error(
                ControlFailure(
                    code: .internalTransport,
                    message: "configuration owner returned an invalid response"))
        }
    }

    private func receiveRenderServerPublication() {
        do {
            let packet = try renderServer.receive(
                maximumBytes: OwnerControlCodec.maximumMessageBytes,
                maximumDescriptors: 0)
            let publication = try OwnerControlCodec.decode(
                RenderServerControlPublication.self,
                from: packet.bytes)
            guard publication.protocolVersion == SessionProtocolVersion.current
            else {
                renderServerUnavailable("owner protocol version mismatch")
                return
            }
            renderIdentity = publication
            renderAvailability = ControlOwnerAvailability(
                available: true,
                version: publication.version ?? renderAvailability.version)
            if publication.result == .ready { return }
            guard let pending = pendingRenderServer,
                case .renderServer(let expectedID) = pending.owner,
                publication.requestID == expectedID
            else {
                renderServerUnavailable("unexpected owner response identity")
                return
            }
            respond(
                publicRenderResponse(publication),
                requestID: pending.requestID,
                to: pending.connection)
            pendingRenderServer = nil
        } catch {
            renderServerUnavailable("owner response decoding failed: \(error)")
        }
    }

    private func publicRenderResponse(
        _ publication: RenderServerControlPublication
    ) -> ControlResponse {
        switch publication.result {
        case .accepted:
            return .accepted
        case .completed:
            if let outputs = publication.outputs {
                return .outputs(
                    ControlOutputSnapshot(
                        outputs: outputs.map {
                            ControlOutput(
                                id: .init(rawValue: $0.id),
                                name: $0.name,
                                width: $0.width,
                                height: $0.height,
                                refreshMillihertz: $0.refreshMillihertz,
                                scale: $0.scale,
                                x: $0.x,
                                y: $0.y,
                                enabled: $0.enabled)
                        },
                        appliedConfigurationGeneration:
                            publication.appliedConfigurationGeneration.rawValue))
            }
            if let binds = publication.activeBindings {
                return .binds(
                    ControlBindingSnapshot(
                        binds: binds,
                        appliedConfigurationGeneration:
                            publication.appliedConfigurationGeneration.rawValue))
            }
            if let version = publication.version {
                return .version(
                    ControlVersionInfo(
                        configurationService: configurationAvailability,
                        renderServer: ControlOwnerAvailability(
                            available: true, version: version)))
            }
            return .completed
        case .unavailable:
            return .error(
                ControlRouting.failure(
                    code: publication.failureCode ?? .unavailable,
                    message: publication.rejection
                        ?? "render-server operation is unavailable"))
        case .rejected:
            return .error(
                ControlRouting.failure(
                    code: publication.failureCode,
                    message: publication.rejection))
        case .ready:
            return .error(
                ControlFailure(
                    code: .internalTransport,
                    message: "render server returned an invalid response"))
        }
    }

    private func capabilityMatches(_ descriptor: Int32) -> Bool {
        guard let elevatedCapability else { return false }
        var expected = stat()
        var actual = stat()
        let expectedResult = unsafe fstat(elevatedCapability, &expected)
        let actualResult = unsafe fstat(descriptor, &actual)
        return expectedResult == 0
            && actualResult == 0
            && expected.st_dev == actual.st_dev
            && expected.st_ino == actual.st_ino
    }

    private func expirePendingRequests() {
        let now = Self.now()
        if let pendingConfiguration,
            pendingConfiguration.deadlineNanoseconds <= now
        {
            respondUnavailable(
                requestID: pendingConfiguration.requestID,
                to: pendingConfiguration.connection)
            self.pendingConfiguration = nil
        }
        if let pendingRenderServer,
            pendingRenderServer.deadlineNanoseconds <= now
        {
            respondUnavailable(
                requestID: pendingRenderServer.requestID,
                to: pendingRenderServer.connection)
            self.pendingRenderServer = nil
        }
    }

    private func renderServerUnavailable(_ reason: String) {
        diagnostic("render server unavailable: \(reason)")
        renderServerAvailable = false
        renderAvailability = ControlOwnerAvailability(available: false)
        guard let pending = pendingRenderServer else { return }
        respondUnavailable(
            requestID: pending.requestID, to: pending.connection)
        pendingRenderServer = nil
    }

    private func failPendingConfiguration() {
        guard let pending = pendingConfiguration else { return }
        respondUnavailable(
            requestID: pending.requestID, to: pending.connection)
        pendingConfiguration = nil
    }

    private func respondBusy(
        requestID: ControlRequestID,
        to connection: PacketConnection
    ) {
        respond(
            .error(
                ControlFailure(
                    code: .ownerUnavailable,
                    message: "request owner is busy")),
            requestID: requestID,
            to: connection)
    }

    private func respondUnavailable(
        requestID: ControlRequestID,
        to connection: PacketConnection
    ) {
        respond(
            .error(
                ControlFailure(
                    code: .ownerUnavailable,
                    message: "request owner is unavailable")),
            requestID: requestID,
            to: connection)
    }

    private func respondInternal(request: PendingRequest) {
        respond(
            .error(
                ControlFailure(
                    code: .internalTransport,
                    message: "owner protocol mismatch")),
            requestID: request.requestID,
            to: request.connection)
    }

    private func respond(
        _ response: ControlResponse,
        requestID: ControlRequestID,
        to connection: PacketConnection
    ) {
        let envelope = ControlResponseEnvelope(
            requestID: requestID, response: response)
        guard let bytes = try? ControlCoding.packet(envelope) else { return }
        try? connection.send(bytes)
    }

    private func consumeTerminationSignal() -> Bool {
        while true {
            let signal = nucleus_session_consume_signal(signalDescriptor)
            if signal < 0 { return false }
            if signal == SIGINT || signal == SIGTERM || signal == SIGHUP {
                return true
            }
        }
    }

    private static func validateSocketDirectory(
        _ path: String
    ) throws {
        var metadata = stat()
        guard unsafe lstat(path, &metadata) == 0,
            metadata.st_uid == geteuid(),
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            metadata.st_mode & 0o077 == 0
        else {
            throw ControlServiceFailure.argument(
                "control socket directory must be an owner-only directory")
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0
            && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func now() -> UInt64 {
        var value = timespec()
        unsafe clock_gettime(CLOCK_MONOTONIC, &value)
        return UInt64(value.tv_sec) * 1_000_000_000
            + UInt64(value.tv_nsec)
    }

    private static func clientToken(_ descriptor: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: descriptor)) + 1_000
    }

    private func diagnostic(_ value: String) {
        let message = "nucleus-control-service: \(value)\n"
        _ = message.withCString {
            unsafe write(STDERR_FILENO, $0, strlen($0))
        }
    }
}

private func descriptor(
    following argument: String,
    arguments: [String],
    required: Bool = true
) throws -> Int32? {
    guard let index = arguments.firstIndex(of: argument) else {
        if required { throw ControlServiceFailure.argument("missing \(argument)") }
        return nil
    }
    guard arguments.indices.contains(index + 1),
        let descriptor = Int32(arguments[index + 1]),
        descriptor >= 3
    else { throw ControlServiceFailure.argument("invalid \(argument)") }
    return descriptor
}

private func value(
    following argument: String,
    arguments: [String]
) throws -> String {
    guard let index = arguments.firstIndex(of: argument),
        arguments.indices.contains(index + 1),
        !arguments[index + 1].isEmpty
    else { throw ControlServiceFailure.argument("missing \(argument)") }
    return arguments[index + 1]
}

@MainActor
package func runControlService(
    arguments: [String] = CommandLine.arguments
) async -> Int32 {
    do {
        guard
            try SessionProcessRole.inherited(arguments: arguments)
                == .controlService
        else {
            throw ControlServiceFailure.argument(
                "control service requires its supervised role")
        }
        let readiness = try SessionReadinessReporter.inherited(
            role: .controlService, arguments: arguments)
        let process = try ControlServiceProcess(
            socketDirectory: value(
                following: "--nucleus-control-socket-directory",
                arguments: arguments),
            configurationDescriptor: descriptor(
                following: "--nucleus-control-config-fd",
                arguments: arguments)!,
            renderServerDescriptor: descriptor(
                following: RenderServerControlChannel.descriptorArgument,
                arguments: arguments)!,
            attachmentDescriptor: descriptor(
                following:
                    SupervisorAttachmentChannel.descriptorArgument,
                arguments: arguments)!,
            elevatedCapability: try descriptor(
                following: "--nucleus-control-elevated-fd",
                arguments: arguments,
                required: false))
        return try await process.run(readiness: readiness)
    } catch {
        let message = "nucleus-control-service: \(error)\n"
        _ = message.withCString {
            unsafe write(STDERR_FILENO, $0, strlen($0))
        }
        return 1
    }
}
