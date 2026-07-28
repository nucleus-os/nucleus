import Glibc
import NucleusLinuxReactor
import NucleusLinuxSessionC
import NucleusSessionProtocol

private enum ServiceFailure: Error, CustomStringConvertible {
    case argument(String)
    case channel(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .argument(let value): value
        case .channel(let value): "configuration channel failed: \(value)"
        case .system(let operation, let error):
            "\(operation) failed: errno \(error)"
        }
    }
}

private struct Endpoint {
    let capability: ConfigurationCapability
    var descriptor: Int32
    var subscribed = false
}

@MainActor
private final class ConfigurationServiceProcess {
    private var state: ConfigurationServiceState
    private let activeFile: ActiveConfigurationFile?
    private var watcher: LinuxFileWatcher?
    private var endpoints: [Endpoint]
    private let attachments: SupervisorAttachmentChannel
    private let signalDescriptor: Int32

    init(
        epoch: ConfigurationServiceEpoch,
        endpoints: [Endpoint],
        attachments: SupervisorAttachmentChannel
    ) throws {
        activeFile = ActiveConfigurationFile()
        state = ConfigurationServiceState(
            epoch: epoch,
            startup: activeFile?.load()
                ?? .loaded(.defaults, warnings: []))
        self.endpoints = endpoints
        self.attachments = attachments
        watcher = activeFile.flatMap { LinuxFileWatcher(path: $0.path) }
        let descriptor = nucleus_session_create_signal_fd()
        guard descriptor >= 0 else {
            throw ServiceFailure.system("signalfd", errno)
        }
        signalDescriptor = descriptor
    }

    deinit {
        _ = close(signalDescriptor)
        for endpoint in endpoints { _ = close(endpoint.descriptor) }
    }

    func run(readiness: SessionReadinessReporter?) throws -> Int32 {
        try readiness?.report(.configServiceReady)
        try publishControlReadiness()
        while true {
            var pollDescriptors = endpoints.map {
                pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0)
            }
            let watcherIndex: Int?
            if let watcher {
                watcherIndex = pollDescriptors.count
                pollDescriptors.append(pollfd(
                    fd: watcher.fileDescriptor,
                    events: Int16(POLLIN),
                    revents: 0))
            } else {
                watcherIndex = nil
            }
            let signalIndex = pollDescriptors.count
            pollDescriptors.append(pollfd(
                fd: signalDescriptor,
                events: Int16(POLLIN),
                revents: 0))
            let attachmentIndex = pollDescriptors.count
            pollDescriptors.append(pollfd(
                fd: attachments.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0))
            let result = unsafe poll(
                &pollDescriptors,
                nfds_t(pollDescriptors.count),
                250)
            if result < 0 {
                if errno == EINTR { continue }
                throw ServiceFailure.system("poll", errno)
            }
            if pollDescriptors[signalIndex].revents & Int16(POLLIN) != 0 {
                while true {
                    let signal =
                        nucleus_session_consume_signal(signalDescriptor)
                    if signal < 0 { break }
                    if signal == SIGINT || signal == SIGTERM
                        || signal == SIGHUP
                    {
                        return 128 + signal
                    }
                }
            }
            if let watcherIndex,
               pollDescriptors[watcherIndex].revents & Int16(POLLIN) != 0
            {
                processWatcher()
            }
            for index in endpoints.indices {
                let events = pollDescriptors[index].revents
                guard events != 0 else { continue }
                if events & Int16(POLLIN) != 0 {
                    do {
                        try processRequest(at: index)
                    } catch {
                        disconnectEndpoint(at: index)
                    }
                } else if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    disconnectEndpoint(at: index)
                }
            }
            // Apply supervisor replacements after processing events for the
            // descriptors captured at the start of this poll cycle. A stale
            // HUP from the retired peer must never disconnect its replacement.
            if pollDescriptors[attachmentIndex].revents & Int16(POLLIN) != 0 {
                try processAttachment()
            }
            if watcher == nil, let activeFile {
                watcher = LinuxFileWatcher(path: activeFile.path)
            }
        }
    }

    private func processAttachment() throws {
        let attachment = try attachments.receive()
        let capability: ConfigurationCapability
        switch attachment.role {
        case .renderServerConfigurationSubscriber:
            capability = .renderServerSubscriber
        case .shellConfigurationSubscriber:
            capability = .shellSubscriber
        case .configurationControl:
            capability = .control
        case .renderServerControl:
            throw ServiceFailure.channel(
                "render-server control endpoint sent to config service")
        }
        guard let index = endpoints.firstIndex(where: {
            $0.capability == capability
        }) else {
            throw ServiceFailure.channel(
                "configuration attachment role is not provisioned")
        }
        if endpoints[index].descriptor >= 0 {
            _ = close(endpoints[index].descriptor)
        }
        endpoints[index].descriptor = attachment.descriptor.take()
        endpoints[index].subscribed = false
        if capability == .control {
            try publishControlReadiness()
        }
    }

    private func publishControlReadiness() throws {
        guard let index = endpoints.firstIndex(where: {
            $0.capability == .control
        }) else {
            throw ServiceFailure.channel(
                "configuration control endpoint is not provisioned")
        }
        try send(
            .ready(
                epoch: state.snapshot.epoch,
                generation: state.snapshot.generation),
            to: index)
    }

    private func disconnectEndpoint(at index: Int) {
        guard endpoints[index].descriptor >= 0 else { return }
        _ = close(endpoints[index].descriptor)
        endpoints[index].descriptor = -1
        endpoints[index].subscribed = false
    }

    private func processWatcher() {
        guard let watcher else { return }
        var observed: LinuxFileWatcher.Change?
        watcher.onChange = { observed = $0 }
        _ = watcher.process()
        guard let change = observed else { return }
        if change.watchInvalidated { self.watcher = nil }
        let update: ConfigurationServiceUpdate
        if change.removed {
            update = state.fileRemoved()
        } else if change.contentChanged, let activeFile {
            update = state.reload(activeFile.load())
        } else {
            return
        }
        publish(update)
    }

    private func processRequest(at index: Int) throws {
        let bytes = try SessionChannel.receive(
            from: endpoints[index].descriptor,
            maximumBytes: ConfigurationSubscriptionCodec.maximumMessageBytes)
        let envelope = try ConfigurationSubscriptionCodec.decode(
            ConfigurationSubscriptionRequest.self,
            from: bytes)
        guard envelope.protocolVersion == SessionProtocolVersion.current else {
            try send(
                .rejected(
                    epoch: state.snapshot.epoch,
                    generation: state.snapshot.generation,
                    reason: "unsupported protocol version"),
                to: index)
            return
        }
        let request = envelope.payload
        let capability = endpoints[index].capability
        let grantedRole = capability.subscriberRole
        switch request.operation {
        case .subscribe:
            guard let grantedRole, request.role == grantedRole else {
                try send(
                    .rejected(
                        epoch: state.snapshot.epoch,
                        generation: state.snapshot.generation,
                        reason: "subscriber role does not match channel"),
                    to: index)
                return
            }
            endpoints[index].subscribed = true
            try send(state.snapshot.publication(for: grantedRole), to: index)
        case .currentSnapshot:
            guard let grantedRole else {
                try rejectUnauthorized(to: index)
                return
            }
            try send(state.snapshot.publication(for: grantedRole), to: index)
        case .acknowledge, .reject:
            guard grantedRole != nil,
                  request.epoch == state.snapshot.epoch,
                  request.generation == state.snapshot.generation
            else {
                try send(
                    .rejected(
                        epoch: state.snapshot.epoch,
                        generation: state.snapshot.generation,
                        reason: "stale configuration identity"),
                    to: index)
                return
            }
            try send(
                .accepted(
                    epoch: state.snapshot.epoch,
                    generation: state.snapshot.generation),
                to: index)
        case .reload:
            guard capability == .control, let activeFile else {
                try rejectUnauthorized(to: index)
                return
            }
            let update = state.reload(activeFile.load())
            publish(update)
            try sendCurrentResult(update, to: index)
        case .validate:
            guard capability == .control, let source = request.source else {
                try rejectUnauthorized(to: index)
                return
            }
            try send(state.validate(source: source), to: index)
        case .replace:
            guard capability == .control, let source = request.source,
                  let activeFile
            else {
                try rejectUnauthorized(to: index)
                return
            }
            do {
                let update = try state.replace(
                    source: source, activeFile: activeFile)
                publish(update)
                try sendCurrentResult(update, to: index)
            } catch {
                try send(
                    .rejected(
                        epoch: state.snapshot.epoch,
                        generation: state.snapshot.generation,
                        reason: "replacement configuration is invalid"),
                    to: index)
            }
        case .export:
            guard capability == .control else {
                try rejectUnauthorized(to: index)
                return
            }
            do {
                try send(try state.export(), to: index)
            } catch {
                try send(
                    .rejected(
                        epoch: state.snapshot.epoch,
                        generation: state.snapshot.generation,
                        reason: "configuration export failed"),
                    to: index)
            }
        }
    }

    private func sendCurrentResult(
        _ update: ConfigurationServiceUpdate,
        to index: Int
    ) throws {
        switch update {
        case .diagnostics(let diagnostics), .unchanged(let diagnostics):
            try send(
                .validated(
                    epoch: state.snapshot.epoch,
                    generation: state.snapshot.generation,
                    diagnostics: diagnostics),
                to: index)
        case .adopted:
            try send(
                .accepted(
                    epoch: state.snapshot.epoch,
                    generation: state.snapshot.generation),
                to: index)
        }
    }

    private func rejectUnauthorized(to index: Int) throws {
        try send(
            .rejected(
                epoch: state.snapshot.epoch,
                generation: state.snapshot.generation,
                reason: "operation is not granted by this channel"),
            to: index)
    }

    private func publish(_ update: ConfigurationServiceUpdate) {
        switch update {
        case .unchanged:
            break
        case .diagnostics(let diagnostics):
            let publication = ConfigurationPublication.diagnostics(
                epoch: state.snapshot.epoch,
                generation: state.snapshot.generation,
                diagnostics: diagnostics)
            for index in endpoints.indices where endpoints[index].subscribed {
                try? send(publication, to: index)
            }
        case .adopted(let snapshot):
            for index in endpoints.indices where endpoints[index].subscribed {
                guard let role = endpoints[index].capability.subscriberRole
                else { continue }
                try? send(snapshot.publication(for: role), to: index)
            }
        }
    }

    private func send(
        _ publication: ConfigurationPublication,
        to index: Int
    ) throws {
        let bytes = try ConfigurationSubscriptionCodec.encode(
            ConfigurationSubscriptionEnvelope(payload: publication))
        try SessionChannel.send(bytes, to: endpoints[index].descriptor)
    }
}

private func descriptor(
    following argument: String,
    arguments: [String]
) throws -> Int32 {
    guard let index = arguments.firstIndex(of: argument),
          arguments.indices.contains(index + 1),
          let descriptor = Int32(arguments[index + 1]),
          descriptor >= 3
    else { throw ServiceFailure.argument("missing \(argument)") }
    return descriptor
}

private func makeEpoch() -> ConfigurationServiceEpoch {
    return ConfigurationServiceEpoch(
        high: UInt64(arc4random()) << 32 | UInt64(arc4random()),
        low: UInt64(arc4random()) << 32 | UInt64(arc4random()))
}

@MainActor
public func runConfigurationService(
    arguments: [String] = CommandLine.arguments
) -> Int32 {
    do {
        let role = try SessionProcessRole.inherited(arguments: arguments)
        guard role == .configService else {
            throw ServiceFailure.argument(
                "configuration service requires its supervised role")
        }
        let readiness = try SessionReadinessReporter.inherited(
            role: .configService,
            arguments: arguments)
        let endpoints = [
            Endpoint(
                capability: .renderServerSubscriber,
                descriptor: try descriptor(
                    following: "--nucleus-render-server-config-fd",
                    arguments: arguments)),
            Endpoint(
                capability: .shellSubscriber,
                descriptor: try descriptor(
                    following: "--nucleus-shell-config-fd",
                    arguments: arguments)),
            Endpoint(
                capability: .control,
                descriptor: try descriptor(
                    following: "--nucleus-control-config-fd",
                    arguments: arguments)),
        ]
        return try ConfigurationServiceProcess(
            epoch: makeEpoch(),
            endpoints: endpoints,
            attachments: SupervisorAttachmentChannel(
                owning: try descriptor(
                    following:
                        SupervisorAttachmentChannel.descriptorArgument,
                    arguments: arguments))).run(readiness: readiness)
    } catch {
        let message = "nucleus-config-service: \(error)\n"
        _ = message.withCString {
            unsafe write(STDERR_FILENO, $0, strlen($0))
        }
        return 1
    }
}
