import Foundation
import Glibc
import NucleusAndroidComposerProtocolC
import NucleusAndroidDrmC
import NucleusAndroidProcessLifecycleC
import NucleusIPCTransportC
import NucleusLinuxReactor
import NucleusLinuxPrimitives
import WaylandClient
import WaylandClientDispatch
import WaylandProtocolTypes

private func elapsedMicroseconds(
    since began: ContinuousClock.Instant
) -> Int64 {
    let components = began.duration(to: ContinuousClock.now).components
    let seconds = components.seconds.multipliedReportingOverflow(
        by: 1_000_000)
    if seconds.overflow {
        return components.seconds >= 0 ? .max : .min
    }
    return seconds.partialValue.addingReportingOverflow(
        Int64(components.attoseconds / 1_000_000_000_000)
    ).partialValue
}

/// Converts the millihertz unit used by `wl_output.mode` to the exact nearest
/// integral nanosecond period used by Composer3.
public func composerRefreshPeriodNanoseconds(
    refreshMillihertz: Int32
) -> UInt64? {
    guard refreshMillihertz > 0 else { return nil }
    let divisor = UInt64(refreshMillihertz)
    return (1_000_000_000_000 + divisor / 2) / divisor
}

public enum DisplayHostError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case systemCall(String, Int32)
    case unauthorizedPeer(expected: UInt32, actual: UInt32)
    case invalidRequest
    case wayland(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .systemCall(let operation, let code):
            let reason = unsafe String(cString: strerror(code))
            return "\(operation) failed: \(reason)"
        case .unauthorizedPeer(let expected, let actual):
            return "unauthorized Composer3 peer uid \(actual), expected \(expected)"
        case .invalidRequest: return "invalid Composer3 display request"
        case .wayland(let message): return "Wayland display failure: \(message)"
        }
    }
}

@MainActor
func waitForDisplayHostReadable(
    _ descriptor: Int32,
    reactor: LinuxHostReactor
) async throws {
    while true {
        let batch = try await reactor.wait(
            interests: [LinuxReactorInterest(
                token: 1,
                fileDescriptor: descriptor,
                events: Int16(POLLIN))],
            timeoutNanoseconds: nil)
        guard let event = batch.events.first else { continue }
        if let failure = event.failureCode {
            throw DisplayHostError.systemCall("io_uring poll", failure)
        }
        let result = LinuxPollResult(returnedEvents: event.returnedEvents)
        if result.isReadable { return }
        if result.isTerminal { throw DisplayHostError.invalidRequest }
    }
}

@MainActor
@safe private final class SyncobjBridge {
    @unsafe private let native: OpaquePointer

    init(renderNode: String) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let native = renderNode.withCString({
            unsafe nucleus_android_syncobj_bridge_create(
                $0, &error, error.count)
        }) else {
            throw DisplayHostError.wayland(
                error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
        unsafe self.native = native
    }

    func importAcquireSyncFile(point: UInt64, fileDescriptor: Int32) -> Bool {
        unsafe nucleus_android_syncobj_bridge_import_acquire_sync_file(
            native, point, fileDescriptor) == 0
    }

    func signalAcquire(point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_bridge_signal_acquire(native, point) == 0
    }

    func watchRelease(point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_bridge_watch_release(native, point) == 0
    }

    var releaseNotificationFileDescriptor: Int32 {
        unsafe nucleus_android_syncobj_bridge_release_notification_fd(native)
    }

    func dispatchReleases() -> UInt64? {
        guard unsafe nucleus_android_syncobj_bridge_dispatch_releases(
            native) == 0
        else {
            return nil
        }
        let point = unsafe nucleus_android_syncobj_bridge_forwarded_release_point(
            native)
        return point
    }

    func exportPresentSyncFile(point: UInt64) throws -> Int32 {
        var error = [CChar](repeating: 0, count: 1_024)
        let descriptor =
            unsafe nucleus_android_syncobj_bridge_export_present_sync_file(
                native, point, &error, error.count)
        guard descriptor >= 0 else {
            throw DisplayHostError.wayland(
                error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
        return descriptor
    }

    func signalPresent(point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_bridge_signal_present(native, point) == 0
    }

    func exportAcquireTimeline() -> Int32 {
        unsafe nucleus_android_syncobj_bridge_export_acquire_timeline(native)
    }

    func exportReleaseTimeline() -> Int32 {
        unsafe nucleus_android_syncobj_bridge_export_release_timeline(native)
    }

    isolated deinit {
        unsafe nucleus_android_syncobj_bridge_destroy(native)
    }
}

@MainActor
@safe public final class NucleusAndroidDisplayHost {
    private let socketPath: String
    private let expectedUserID: UInt32
    private let parentProcessID: Int32
    private let listener: Int32
    private let acceptReactor: LinuxHostReactor
    private let presenter: AndroidDisplayPresenter
    private var topologySubscriber: Int32?

    public init(
        socketPath: String,
        expectedUserID: UInt32,
        renderDevice: String,
        parentProcessID: Int32,
        waylandSocket: String
    ) throws {
        guard nucleus_android_require_parent_lifetime(
            SIGTERM, parentProcessID) == 0
        else { throw systemError("prctl(PR_SET_PDEATHSIG)") }
        let listener = socketPath.withCString {
            unsafe nucleus_ipc_listen($0, 0o666)
        }
        guard listener >= 0 else { throw systemError("bind/listen") }
        self.socketPath = socketPath
        self.expectedUserID = expectedUserID
        self.parentProcessID = parentProcessID
        self.listener = listener
        self.acceptReactor = try LinuxHostReactor()
        do {
            self.presenter = try AndroidDisplayPresenter(
                waylandSocket: waylandSocket,
                renderDevice: renderDevice,
                reactor: LinuxHostReactor())
        } catch {
            _ = close(listener)
            _ = socketPath.withCString { unsafe unlink($0) }
            throw error
        }
        presenter.topologySink = { [weak self] update in
            self?.publishTopology(update)
        }
        presenter.presentationSink = { [weak self] sample in
            self?.publishPresentation(sample)
        }
    }

    public func run() async throws {
        defer {
            _ = close(listener)
            _ = socketPath.withCString { unsafe unlink($0) }
        }
        while true {
            try await waitForDisplayHostReadable(
                listener,
                reactor: acceptReactor)
            let connection = nucleus_ipc_accept(listener)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                throw systemError("accept")
            }
            do {
                try requirePeer(connection)
                let diagnostic =
                    "{\"component\":\"nucleus-android-display-host\","
                    + "\"stage\":\"composer.connection.accepted\"}\n"
                FileHandle.standardError.write(Data(diagnostic.utf8))
                Task { @MainActor [weak self] in
                    guard let self else {
                        _ = close(connection)
                        return
                    }
                    defer { _ = close(connection) }
                    do {
                        try await self.serve(connection)
                    } catch {
                        let diagnostic =
                            "{\"component\":\"nucleus-android-display-host\","
                            + "\"stage\":\"composer.connection.failed\","
                            + "\"error\":\"\(String(describing: error))\"}\n"
                        FileHandle.standardError.write(Data(diagnostic.utf8))
                    }
                }
            } catch {
                _ = close(connection)
                throw error
            }
        }
    }

    private func requirePeer(_ connection: Int32) throws {
        var credentials = nucleus_ipc_peer_credentials()
        guard unsafe nucleus_ipc_peer_credentials(
            connection, &credentials) == 0
        else { throw systemError("getsockopt(SO_PEERCRED)") }
        guard credentials.uid == expectedUserID else {
            throw DisplayHostError.unauthorizedPeer(
                expected: expectedUserID,
                actual: credentials.uid)
        }
    }

    private func serve(_ connection: Int32) async throws {
        let handshakeReactor = try LinuxHostReactor()
        try await waitForDisplayHostReadable(
            connection,
            reactor: handshakeReactor)
        var bytes = [UInt8](
            repeating: 0,
            count: Int(NUCLEUS_COMPOSER_MAX_MESSAGE_BYTES))
        var descriptors = [Int32](
            repeating: -1,
            count: Int(NUCLEUS_COMPOSER_MAX_FDS))
        var descriptorCount = 0
        let received = bytes.withUnsafeMutableBytes { message in
            descriptors.withUnsafeMutableBufferPointer { fds in
                unsafe nucleus_ipc_receive(
                    connection,
                    message.baseAddress,
                    message.count,
                    fds.baseAddress,
                    fds.count,
                    &descriptorCount)
            }
        }
        guard received >= MemoryLayout<nucleus_composer_message_header>.size else {
            throw DisplayHostError.invalidRequest
        }
        let header = bytes.withUnsafeBytes {
            unsafe $0.loadUnaligned(
                as: nucleus_composer_message_header.self)
        }
        guard header.magic == NUCLEUS_COMPOSER_PROTOCOL_MAGIC,
              header.version == NUCLEUS_COMPOSER_PROTOCOL_VERSION,
              header.byte_count == received,
              header.fd_count == descriptorCount
        else { throw DisplayHostError.invalidRequest }
        if header.operation
            == UInt16(NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY.rawValue)
        {
            guard received
                == MemoryLayout<nucleus_composer_topology_subscribe_request>.size,
                  descriptorCount == 0
            else { throw DisplayHostError.invalidRequest }
            let request = bytes.withUnsafeBytes {
                unsafe $0.loadUnaligned(
                    as: nucleus_composer_topology_subscribe_request.self)
            }
            try subscribeTopology(connection, request: request)
            return
        }
        guard header.operation == UInt16(NUCLEUS_COMPOSER_PRESENT.rawValue),
              received == MemoryLayout<nucleus_composer_present_request>.size
        else { throw DisplayHostError.invalidRequest }
        var firstRequest: nucleus_composer_present_request? =
            bytes.withUnsafeBytes {
                unsafe $0.loadUnaligned(
                    as: nucleus_composer_present_request.self)
            }
        descriptors.removeSubrange(descriptorCount..<descriptors.count)
        while true {
            var request: nucleus_composer_present_request
            if let initial = firstRequest {
                request = initial
                firstRequest = nil
            } else {
                try await presenter.dispatchUntilReadable(connection)
                request = nucleus_composer_present_request()
                descriptors = [Int32](
                    repeating: -1,
                    count: Int(NUCLEUS_COMPOSER_MAX_FDS))
                descriptorCount = 0
                let requestSize = MemoryLayout.size(ofValue: request)
                let received = descriptors.withUnsafeMutableBufferPointer { fds in
                    withUnsafeMutablePointer(to: &request) { bytes in
                        unsafe nucleus_ipc_receive(
                            connection,
                            bytes,
                            requestSize,
                            fds.baseAddress,
                            fds.count,
                            &descriptorCount)
                    }
                }
                if received < 0 {
                    if errno == ECONNRESET { return }
                    throw systemError("recvmsg")
                }
                guard received == requestSize else {
                    throw DisplayHostError.invalidRequest
                }
                descriptors.removeSubrange(descriptorCount..<descriptors.count)
            }
            do {
                try validate(request, descriptorCount: descriptorCount)
                let releaseFence = try await presenter.present(
                    request, descriptors: descriptors)
                defer { _ = close(releaseFence) }
                var reply = nucleus_composer_present_reply()
                reply.magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC
                reply.version = NUCLEUS_COMPOSER_PROTOCOL_VERSION
                reply.operation = UInt16(NUCLEUS_COMPOSER_PRESENT.rawValue)
                reply.byte_count = UInt32(MemoryLayout.size(ofValue: reply))
                reply.fd_count = 1
                reply.request_id = request.request_id
                reply.status = UInt32(NUCLEUS_COMPOSER_STATUS_OK.rawValue)
                let replySize = MemoryLayout.size(ofValue: reply)
                let sent = withUnsafePointer(to: &reply) { bytes in
                    var descriptor = releaseFence
                    return withUnsafePointer(to: &descriptor) { fd in
                        unsafe nucleus_ipc_send(
                            connection,
                            bytes,
                            replySize,
                            fd,
                            1)
                    }
                }
                guard sent == 0 else { throw systemError("sendmsg") }
            } catch {
                for descriptor in descriptors where descriptor >= 0 {
                    _ = close(descriptor)
                }
                throw error
            }
            for descriptor in descriptors where descriptor >= 0 {
                _ = close(descriptor)
            }
        }
    }

    private func subscribeTopology(
        _ connection: Int32,
        request: nucleus_composer_topology_subscribe_request
    ) throws {
        let subscriptionDiagnostic =
            "{\"component\":\"nucleus-android-display-host\","
            + "\"stage\":\"topology.subscription.received\","
            + "\"lastGeneration\":\(request.last_generation)}\n"
        FileHandle.standardError.write(
            Data(subscriptionDiagnostic.utf8))
        if let existing = topologySubscriber {
            var state = pollfd(
                fd: existing,
                events: Int16(POLLIN),
                revents: 0)
            if unsafe poll(&state, 1, 0) > 0,
               LinuxPollResult(
                returnedEvents: state.revents).isTerminal
            {
                _ = close(existing)
                topologySubscriber = nil
            }
        }
        if topologySubscriber != nil {
            try sendTopologyStatus(
                connection,
                status: NUCLEUS_COMPOSER_STATUS_DUPLICATE_SUBSCRIBER)
            return
        }
        let generation = presenter.topologyGeneration
        guard request.last_generation <= generation else {
            try sendTopologyStatus(
                connection,
                status: NUCLEUS_COMPOSER_STATUS_STALE_GENERATION)
            return
        }
        let retained = dup(connection)
        guard retained >= 0 else { throw systemError("dup") }
        topologySubscriber = retained
        do {
            let outputs = presenter.connectedOutputs
            for output in outputs {
                try sendTopology(
                    output,
                    operation: NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT,
                    to: retained)
            }
            try sendTopologyStatus(
                retained,
                status: NUCLEUS_COMPOSER_STATUS_OK)
            let snapshotDiagnostic =
                "{\"component\":\"nucleus-android-display-host\","
                + "\"stage\":\"topology.snapshot.sent\","
                + "\"generation\":\(presenter.topologyGeneration),"
                + "\"displays\":\(outputs.count)}\n"
            FileHandle.standardError.write(
                Data(snapshotDiagnostic.utf8))
        } catch {
            _ = close(retained)
            topologySubscriber = nil
            throw error
        }
    }

    private func publishTopology(_ update: AndroidOutputTopology.Update) {
        guard let subscriber = topologySubscriber else { return }
        do {
            try sendTopology(
                update.output,
                operation: update.operation,
                to: subscriber)
        } catch {
            _ = close(subscriber)
            topologySubscriber = nil
        }
    }

    private func publishPresentation(
        _ sample: AndroidDisplayPresenter.PresentationSample
    ) {
        guard let subscriber = topologySubscriber else { return }
        var event = nucleus_composer_topology_event()
        event.magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC
        event.version = NUCLEUS_COMPOSER_PROTOCOL_VERSION
        event.operation = UInt16(
            NUCLEUS_COMPOSER_OUTPUT_PRESENTED.rawValue)
        event.byte_count = UInt32(MemoryLayout.size(ofValue: event))
        event.generation = presenter.topologyGeneration
        event.display_id = sample.displayID
        event.refresh_period_ns = sample.refreshPeriodNanoseconds
        event.presentation_timestamp_ns = sample.timestampNanoseconds
        event.presentation_sequence = sample.sequence
        event.status = UInt32(NUCLEUS_COMPOSER_STATUS_OK.rawValue)
        event.connected = 1
        let eventSize = MemoryLayout.size(ofValue: event)
        let sent = withUnsafePointer(to: &event) {
            unsafe nucleus_ipc_send(
                subscriber, $0, eventSize, nil, 0)
        }
        if sent != 0 {
            _ = close(subscriber)
            topologySubscriber = nil
        }
    }

    private func sendTopology(
        _ output: AndroidOutputTopology.Output,
        operation: nucleus_composer_operation,
        to connection: Int32
    ) throws {
        var event = nucleus_composer_topology_event()
        event.magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC
        event.version = NUCLEUS_COMPOSER_PROTOCOL_VERSION
        event.operation = UInt16(operation.rawValue)
        event.byte_count = UInt32(MemoryLayout.size(ofValue: event))
        event.generation = output.generation
        event.display_id = output.displayID
        event.refresh_period_ns = output.refreshPeriodNanoseconds
        event.mode_width = output.width
        event.mode_height = output.height
        event.refresh_millihertz = output.refreshMillihertz
        event.status = UInt32(NUCLEUS_COMPOSER_STATUS_OK.rawValue)
        event.connected = output.connected ? 1 : 0
        withUnsafeMutableBytes(of: &event.output_name) { destination in
            let utf8 = output.name.utf8.prefix(destination.count - 1)
            unsafe destination.copyBytes(from: utf8)
            unsafe destination[utf8.count] = 0
        }
        let eventSize = MemoryLayout.size(ofValue: event)
        let sent = withUnsafePointer(to: &event) {
            unsafe nucleus_ipc_send(
                connection,
                $0,
                eventSize,
                nil,
                0)
        }
        guard sent == 0 else { throw systemError("sending topology event") }
    }

    private func sendTopologyStatus(
        _ connection: Int32,
        status: nucleus_composer_status
    ) throws {
        var event = nucleus_composer_topology_event()
        event.magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC
        event.version = NUCLEUS_COMPOSER_PROTOCOL_VERSION
        event.operation = UInt16(NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT.rawValue)
        event.byte_count = UInt32(MemoryLayout.size(ofValue: event))
        event.generation = presenter.topologyGeneration
        event.display_id = UInt64.max
        event.status = UInt32(status.rawValue)
        let eventSize = MemoryLayout.size(ofValue: event)
        let sent = withUnsafePointer(to: &event) {
            unsafe nucleus_ipc_send(
                connection,
                $0,
                eventSize,
                nil,
                0)
        }
        guard sent == 0 else { throw systemError("sending topology status") }
    }

    private func validate(
        _ request: nucleus_composer_present_request,
        descriptorCount: Int
    ) throws {
        let expectedDescriptors = request.has_acquire_fence == 1 ? 3 : 2
        guard request.magic == NUCLEUS_COMPOSER_PROTOCOL_MAGIC,
              request.version == NUCLEUS_COMPOSER_PROTOCOL_VERSION,
              request.operation == UInt16(NUCLEUS_COMPOSER_PRESENT.rawValue),
              request.byte_count == UInt32(MemoryLayout.size(ofValue: request)),
              request.fd_count == expectedDescriptors,
              descriptorCount == Int(expectedDescriptors),
              presenter.isConnected(displayID: request.display_id),
              request.allocation_id != 0,
              request.frame_number != 0,
              request.width > 0,
              request.height > 0,
              request.plane_stride > 0,
              request.damage_right > request.damage_left,
              request.damage_bottom > request.damage_top
        else { throw DisplayHostError.invalidRequest }
    }

}

@MainActor
@safe private final class AndroidOutputTopology: WlOutputEvents {
    typealias Output = ComposerOutputTopologyState.Output
    typealias Update = ComposerOutputTopologyState.Update

    private struct Pending {
        let globalName: UInt32
        let proxy: WaylandProxy<WlOutputClient>
        var name: String?
        var width: Int32?
        var height: Int32?
        var refreshMillihertz: Int32?
        var published: Output?
    }

    var sink: ((Update) -> Void)?
    private var pendingByProxy: [UInt: Pending] = [:]
    private var proxyByGlobal: [UInt32: UInt] = [:]
    private var state = ComposerOutputTopologyState()
    var generation: UInt64 { state.generation }

    var connectedOutputs: [Output] {
        state.connectedOutputs
    }

    func bind(_ global: BoundGlobal<WlOutputClient>) {
        let identity = global.proxy.identity
        pendingByProxy[identity] = Pending(
            globalName: global.name,
            proxy: global.proxy)
        proxyByGlobal[global.name] = identity
        try? global.proxy.installListener(self)
    }

    func remove(globalName: UInt32) {
        guard let identity = proxyByGlobal.removeValue(forKey: globalName),
              let pending = pendingByProxy.removeValue(forKey: identity),
              let published = pending.published
        else { return }
        if let update = state.disconnect(name: published.name) {
            sink?(update)
        }
        try? pending.proxy.release()
    }

    func isConnected(displayID: UInt64) -> Bool {
        connectedOutputs.contains { $0.displayID == displayID }
    }

    func displayID(proxyIdentity: UInt) -> UInt64? {
        pendingByProxy[proxyIdentity]?.published?.displayID
    }

    func proxy(displayID: UInt64) -> WaylandProxy<WlOutputClient>? {
        pendingByProxy.values.first {
            $0.published?.displayID == displayID
                && $0.published?.connected == true
        }?.proxy
    }

    func refreshPeriodNanoseconds(displayID: UInt64) -> UInt64? {
        connectedOutputs.first {
            $0.displayID == displayID
        }?.refreshPeriodNanoseconds
    }

    func geometry(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        x: Int32, y: Int32,
        physical_width: Int32, physical_height: Int32,
        subpixel: WlOutputSubpixel,
        make: String, model: String,
        transform: WlOutputTransform
    ) {}

    func mode(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        flags: WlOutputMode,
        width: Int32,
        height: Int32,
        refresh: Int32
    ) {
        guard flags.contains(.current),
              var pending = pendingByProxy[proxy.identity]
        else { return }
        pending.width = width
        pending.height = height
        pending.refreshMillihertz = refresh
        pendingByProxy[proxy.identity] = pending
    }

    func done(_ proxy: WaylandBorrowedProxy<WlOutputClient>) {
        publish(proxy.identity)
    }

    func scale(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        factor: Int32
    ) {}

    func name(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        name: String
    ) {
        guard var pending = pendingByProxy[proxy.identity] else { return }
        pending.name = name
        pendingByProxy[proxy.identity] = pending
    }

    func description(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        description: String
    ) {}

    private func publish(_ identity: UInt) {
        guard var pending = pendingByProxy[identity],
              let name = pending.name,
              let width = pending.width,
              let height = pending.height,
              let refreshMillihertz = pending.refreshMillihertz,
              let period = composerRefreshPeriodNanoseconds(
                refreshMillihertz: refreshMillihertz)
        else { return }
        guard period > 0,
              let update = state.publish(
                name: name,
                width: width,
                height: height,
                refreshMillihertz: refreshMillihertz)
        else { return }
        pending.published = update.output
        pendingByProxy[identity] = pending
        sink?(update)
    }
}

@MainActor
private final class PresentationClockHandler: WpPresentationEvents {
    private(set) var clockID: UInt32?

    func clockId(
        _ proxy: WaylandBorrowedProxy<WpPresentationClient>,
        clk_id: UInt32
    ) {
        clockID = clk_id
    }
}

@MainActor
@safe private final class AndroidDisplayPresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WlBufferEvents,
    @MainActor WpPresentationFeedbackEvents
{
    struct PresentationSample {
        let displayID: UInt64
        let timestampNanoseconds: UInt64
        let refreshPeriodNanoseconds: UInt64
        let sequence: UInt64
    }

    private final class DisplaySurface {
        let displayID: UInt64
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let syncSurface:
            WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        let acquireTimeline:
            WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        let releaseTimeline:
            WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        var configured = false
        var closed = false

        init(
            displayID: UInt64,
            surface: WaylandProxy<WlSurfaceClient>,
            xdgSurface: WaylandProxy<XdgSurfaceClient>,
            toplevel: WaylandProxy<XdgToplevelClient>,
            syncSurface:
                WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>,
            acquireTimeline:
                WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>,
            releaseTimeline:
                WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        ) {
            self.displayID = displayID
            self.surface = surface
            self.xdgSurface = xdgSurface
            self.toplevel = toplevel
            self.syncSurface = syncSurface
            self.acquireTimeline = acquireTimeline
            self.releaseTimeline = releaseTimeline
        }
    }

    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private let reactor: LinuxHostReactor
    private let wmHandler = DisplayWmBaseHandler()
    private let bridge: SyncobjBridge
    private let compositor: WaylandProxy<WlCompositorClient>
    private let dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    private let wmBase: WaylandProxy<XdgWmBaseClient>
    private let syncobjManager:
        WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>
    private let presentation:
        WaylandProxy<WpPresentationClient>
    private let presentationClock: PresentationClockHandler
    private let outputTopology: AndroidOutputTopology
    var topologySink: ((AndroidOutputTopology.Update) -> Void)? {
        didSet {
            outputTopology.sink = { [weak self] update in
                if update.operation
                    == NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED
                {
                    self?.retireSurface(
                        displayID: update.output.displayID)
                }
                self?.topologySink?(update)
            }
        }
    }
    var topologyGeneration: UInt64 { outputTopology.generation }
    var connectedOutputs: [AndroidOutputTopology.Output] {
        outputTopology.connectedOutputs
    }
    var presentationSink: ((PresentationSample) -> Void)?
    private var surfaces: [UInt64: DisplaySurface] = [:]
    private var displayIDByXdgSurface: [UInt: UInt64] = [:]
    private var displayIDByToplevel: [UInt: UInt64] = [:]
    private var buffers: [UInt64: DisplayBuffer] = [:]
    private var reportedBufferRelease = false
    private var nextAcquirePoint: UInt64 = 1
    private var nextReleasePoint: UInt64 = 1
    private var nextPresentPoint: UInt64 = 1
    private var deferredFailure: DisplayHostError?
    private var presentationDiagnosticBudget = 16
    private var pendingBufferReleases:
        [UInt64: (frameNumber: UInt64, committed: ContinuousClock.Instant)] = [:]
    private var presentationFeedback:
        [UInt: (
            proxy: WaylandProxy<WpPresentationFeedbackClient>,
            displayID: UInt64,
            frameNumber: UInt64,
            presentPoint: UInt64,
            committed: ContinuousClock.Instant
        )] = [:]

    init(
        waylandSocket: String,
        renderDevice: String,
        reactor: LinuxHostReactor
    ) throws {
        let selectedRenderDevice: String
        if renderDevice == "auto" {
            var path = [CChar](
                repeating: 0,
                count: Int(NUCLEUS_ANDROID_DRM_PATH_MAX))
            guard unsafe nucleus_android_drm_select_display_render_path(
                &path, path.count) == 0
            else { throw systemError("selecting display GPU") }
            let end = path.firstIndex(of: 0) ?? path.endIndex
            selectedRenderDevice = String(
                decoding: path[..<end].map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self)
        } else {
            selectedRenderDevice = renderDevice
        }
        guard let connection = WaylandConnection(socket: waylandSocket),
              true
        else { throw DisplayHostError.wayland("connection failed") }
        let outputTopology = AndroidOutputTopology()
        let presentationClock = PresentationClockHandler()
        guard let registry = WaylandRegistry(connection, wanting: [
                DesiredGlobal<WlCompositorClient>(maximumVersion: 6),
                DesiredGlobal<ZwpLinuxDmabufV1Client>(maximumVersion: 5),
                DesiredGlobal<XdgWmBaseClient>(maximumVersion: 6),
                DesiredGlobal<WpLinuxDrmSyncobjManagerV1Client>(
                    maximumVersion: 1),
                DesiredGlobal<WpPresentationClient>(
                    maximumVersion: 1,
                    onBind: {
                        try? $0.proxy.installListener(
                            presentationClock)
                    }),
                DesiredGlobal<WlOutputClient>(
                    maximumVersion: 4,
                    allowsMultiple: true,
                    onBind: { outputTopology.bind($0) },
                    onRemove: {
                        outputTopology.remove(globalName: $0.name)
                    }),
            ])
        else { throw DisplayHostError.wayland("registry creation failed") }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("registry roundtrip failed")
        }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("output-state roundtrip failed")
        }
        guard presentationClock.clockID == UInt32(CLOCK_MONOTONIC) else {
            throw DisplayHostError.wayland(
                "wp_presentation does not use CLOCK_MONOTONIC")
        }
        guard let compositor = registry.singleton(WlCompositorClient.self),
              let dmabuf = registry.singleton(ZwpLinuxDmabufV1Client.self),
              let wmBase = registry.singleton(XdgWmBaseClient.self),
              let syncobjManager = registry.singleton(
                WpLinuxDrmSyncobjManagerV1Client.self),
              let presentation = registry.singleton(
                WpPresentationClient.self)
        else { throw DisplayHostError.wayland("required protocol is unavailable") }
        try validateDisplayFormatContract(
            connection: connection,
            dmabuf: dmabuf,
            renderDevice: selectedRenderDevice)
        let bridge = try SyncobjBridge(renderNode: selectedRenderDevice)
        self.connection = connection
        self.registry = registry
        self.reactor = reactor
        self.bridge = bridge
        self.compositor = compositor
        self.dmabuf = dmabuf
        self.wmBase = wmBase
        self.syncobjManager = syncobjManager
        self.presentation = presentation
        self.presentationClock = presentationClock
        self.outputTopology = outputTopology
        wmHandler.proxy = wmBase
        try wmBase.installListener(wmHandler)
    }

    func isConnected(displayID: UInt64) -> Bool {
        outputTopology.isConnected(displayID: displayID)
    }

    private func retireSurface(displayID: UInt64) {
        guard let displaySurface = surfaces.removeValue(
            forKey: displayID)
        else { return }
        displayIDByXdgSurface.removeValue(
            forKey: displaySurface.xdgSurface.identity)
        displayIDByToplevel.removeValue(
            forKey: displaySurface.toplevel.identity)
        try? displaySurface.acquireTimeline.destroy()
        try? displaySurface.releaseTimeline.destroy()
        try? displaySurface.syncSurface.destroy()
        try? displaySurface.toplevel.destroy()
        try? displaySurface.xdgSurface.destroy()
        try? displaySurface.surface.destroy()
    }

    func present(
        _ request: nucleus_composer_present_request,
        descriptors: [Int32]
    ) async throws -> Int32 {
        let presentationBegan = ContinuousClock.now
        if surfaces[request.display_id] == nil {
            try await createSurface(
                displayID: request.display_id,
                width: request.width,
                height: request.height)
        }
        guard let displaySurface = surfaces[request.display_id],
              !displaySurface.closed
        else { throw DisplayHostError.wayland("surface closed") }
        let surface = displaySurface.surface
        let syncSurface = displaySurface.syncSurface
        let acquireTimeline = displaySurface.acquireTimeline
        let releaseTimeline = displaySurface.releaseTimeline
        let importBegan = ContinuousClock.now
        let buffer = try importBuffer(request, descriptors: descriptors)
        let bufferImportMicroseconds = elapsedMicroseconds(since: importBegan)
        let acquirePoint = nextAcquirePoint
        nextAcquirePoint &+= 1
        let acquireBegan = ContinuousClock.now
        if request.has_acquire_fence == 1 {
            guard bridge.importAcquireSyncFile(
                point: acquirePoint,
                fileDescriptor: descriptors[2])
            else { throw systemError("importing Composer3 acquire fence") }
        } else {
            guard bridge.signalAcquire(point: acquirePoint)
            else { throw systemError("signaling empty acquire point") }
        }
        let acquireMicroseconds = elapsedMicroseconds(since: acquireBegan)
        let releasePoint = nextReleasePoint
        nextReleasePoint &+= 1
        let presentPoint = nextPresentPoint
        nextPresentPoint &+= 1
        let presentExportBegan = ContinuousClock.now
        let presentFence = try bridge.exportPresentSyncFile(
            point: presentPoint)
        var ownsPresentFence = true
        defer {
            if ownsPresentFence {
                _ = Glibc.close(presentFence)
            }
        }
        let presentExportMicroseconds = elapsedMicroseconds(
            since: presentExportBegan)
        let commitBegan = ContinuousClock.now
        try syncSurface.setAcquirePoint(
            timeline: acquireTimeline,
            point_hi: UInt32(acquirePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: acquirePoint))
        try syncSurface.setReleasePoint(
            timeline: releaseTimeline,
            point_hi: UInt32(releasePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: releasePoint))
        guard bridge.watchRelease(point: releasePoint) else {
            throw systemError("arming compositor buffer-release notification")
        }
        try surface.attach(buffer: buffer.proxy, x: 0, y: 0)
        try surface.damageBuffer(
            x: request.damage_left,
            y: request.damage_top,
            width: request.damage_right - request.damage_left,
            height: request.damage_bottom - request.damage_top)
        let feedback = try presentation.feedback(
            surface: surface)
        try feedback.installListener(self)
        presentationFeedback[feedback.identity] = (
            proxy: feedback,
            displayID: request.display_id,
            frameNumber: request.frame_number,
            presentPoint: presentPoint,
            committed: ContinuousClock.now)
        try surface.commit()
        guard connection.flush() >= 0 || errno == EAGAIN else {
            throw DisplayHostError.wayland("commit flush failed")
        }
        let commitMicroseconds = elapsedMicroseconds(since: commitBegan)
        let totalMicroseconds = elapsedMicroseconds(
            since: presentationBegan)
        pendingBufferReleases[releasePoint] = (
            frameNumber: request.frame_number,
            committed: ContinuousClock.now)
        if presentationDiagnosticBudget > 0
            || totalMicroseconds >= 50_000
        {
            if presentationDiagnosticBudget > 0 {
                presentationDiagnosticBudget -= 1
            }
            let fields = [
                "\"component\":\"nucleus-android-display-host\"",
                "\"stage\":\"presentation.committed\"",
                "\"requestId\":\(request.request_id)",
                "\"frameNumber\":\(request.frame_number)",
                "\"allocationId\":\(request.allocation_id)",
                "\"acquirePoint\":\(acquirePoint)",
                "\"releasePoint\":\(releasePoint)",
                "\"presentPoint\":\(presentPoint)",
                "\"hasAcquireFence\":\(request.has_acquire_fence)",
                "\"bufferImportMicroseconds\":\(bufferImportMicroseconds)",
                "\"acquireMicroseconds\":\(acquireMicroseconds)",
                "\"presentExportMicroseconds\":\(presentExportMicroseconds)",
                "\"commitMicroseconds\":\(commitMicroseconds)",
                "\"totalMicroseconds\":\(totalMicroseconds)",
            ]
            let diagnostic = "{\(fields.joined(separator: ","))}\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        ownsPresentFence = false
        return presentFence
    }

    func dispatchUntilReadable(_ descriptor: Int32) async throws {
        while true {
            guard let preparation = connection.prepareRead() else {
                throw DisplayHostError.wayland("prepare-read failed")
            }
            let flushResult = connection.flush()
            let flushError = errno
            if flushResult < 0 && flushError != EAGAIN {
                preparation.read.cancel()
                throw DisplayHostError.wayland("flush failed")
            }
            let displayEvents = Int16(POLLIN)
                | (flushResult < 0 ? Int16(POLLOUT) : 0)
            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(interests: [
                    LinuxReactorInterest(
                        token: 1,
                        fileDescriptor: connection.fd,
                        events: displayEvents),
                    LinuxReactorInterest(
                        token: 2,
                        fileDescriptor: descriptor,
                        events: Int16(POLLIN)),
                    LinuxReactorInterest(
                        token: 3,
                        fileDescriptor:
                            bridge.releaseNotificationFileDescriptor,
                        events: Int16(POLLIN)),
                ], timeoutNanoseconds: nil)
            } catch {
                preparation.read.cancel()
                throw error
            }
            let displayEvent = batch.events.first { $0.token == 1 }
            let socketEvent = batch.events.first { $0.token == 2 }
            let releaseEvent = batch.events.first { $0.token == 3 }
            if let failure = displayEvent?.failureCode
                ?? socketEvent?.failureCode
                ?? releaseEvent?.failureCode
            {
                preparation.read.cancel()
                throw DisplayHostError.systemCall("io_uring poll", failure)
            }
            let displayReadable = displayEvent.map {
                LinuxPollResult(returnedEvents: $0.returnedEvents).isReadable
            } ?? false
            guard preparation.read.complete(readable: displayReadable) >= 0 else {
                throw DisplayHostError.wayland("event dispatch failed")
            }
            if let deferredFailure {
                throw deferredFailure
            }
            if surfaces.values.contains(where: \.closed) {
                throw DisplayHostError.wayland("surface closed")
            }
            if let releaseEvent,
               LinuxPollResult(
                returnedEvents: releaseEvent.returnedEvents).isReadable {
                guard let completedPoint = bridge.dispatchReleases() else {
                    throw systemError("forwarding compositor release fences")
                }
                let released = pendingBufferReleases
                    .filter { $0.key <= completedPoint }
                for point in released.keys {
                    pendingBufferReleases.removeValue(forKey: point)
                }
                let releaseMicroseconds = released.values.map {
                    elapsedMicroseconds(since: $0.committed)
                }.max() ?? 0
                if !reportedBufferRelease
                    || releaseMicroseconds >= 50_000
                {
                    reportedBufferRelease = true
                    let diagnostic =
                        "{\"component\":\"nucleus-android-display-host\","
                        + "\"stage\":\"buffer.released\","
                        + "\"completedPoint\":\(completedPoint),"
                        + "\"releasedFrames\":\(released.count),"
                        + "\"releaseMicroseconds\":\(releaseMicroseconds)}\n"
                    FileHandle.standardError.write(Data(diagnostic.utf8))
                }
            }
            if let socketEvent,
               LinuxPollResult(
                returnedEvents: socketEvent.returnedEvents).isReadable {
                return
            }
            if let socketEvent,
               LinuxPollResult(
                returnedEvents: socketEvent.returnedEvents).isTerminal {
                throw DisplayHostError.invalidRequest
            }
        }
    }

    private func createSurface(
        displayID: UInt64,
        width: UInt32,
        height: UInt32
    ) async throws {
        guard surfaces[displayID] == nil,
              let output = outputTopology.proxy(displayID: displayID)
        else {
            throw DisplayHostError.wayland(
                "display \(displayID) has no connected Wayland output")
        }
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let syncSurface: WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        do {
            surface = try compositor.createSurface()
            xdgSurface = try wmBase.getXdgSurface(surface: surface)
            toplevel = try xdgSurface.getToplevel()
            syncSurface = try syncobjManager.getSurface(surface: surface)
        } catch {
            throw DisplayHostError.wayland("surface creation failed")
        }
        let acquireFD = bridge.exportAcquireTimeline()
        let releaseFD = bridge.exportReleaseTimeline()
        guard acquireFD >= 0, releaseFD >= 0 else {
            if acquireFD >= 0 { _ = Glibc.close(acquireFD) }
            if releaseFD >= 0 { _ = Glibc.close(releaseFD) }
            throw DisplayHostError.wayland("timeline import failed")
        }
        let acquireTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        let releaseTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        do {
            acquireTimeline = try syncobjManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(acquireFD))
            releaseTimeline = try syncobjManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(releaseFD))
        } catch {
            throw DisplayHostError.wayland("timeline import failed")
        }
        let displaySurface = DisplaySurface(
            displayID: displayID,
            surface: surface,
            xdgSurface: xdgSurface,
            toplevel: toplevel,
            syncSurface: syncSurface,
            acquireTimeline: acquireTimeline,
            releaseTimeline: releaseTimeline)
        surfaces[displayID] = displaySurface
        displayIDByXdgSurface[xdgSurface.identity] = displayID
        displayIDByToplevel[toplevel.identity] = displayID
        try xdgSurface.installListener(self)
        try toplevel.installListener(self)
        try toplevel.setAppId(app_id: "android.runtime")
        try toplevel.setTitle(title: "Android Display \(displayID)")
        try toplevel.setMinSize(
            width: Int32(width),
            height: Int32(height))
        try toplevel.setFullscreen(output: output)
        let opaqueRegion: WaylandProxy<WlRegionClient>
        do {
            opaqueRegion = try compositor.createRegion()
            defer { try? opaqueRegion.destroy() }
            try opaqueRegion.add(
                x: 0,
                y: 0,
                width: Int32(width),
                height: Int32(height))
            try surface.setOpaqueRegion(region: opaqueRegion)
        } catch {
            throw DisplayHostError.wayland(
                "opaque display-region creation failed")
        }
        try surface.commit()
        guard connection.flush() >= 0 else {
            throw DisplayHostError.wayland("initial commit failed")
        }
        while !displaySurface.configured {
            try await dispatchWaylandOnce(displayID: displayID)
        }
    }

    private func importBuffer(
        _ request: nucleus_composer_present_request,
        descriptors: [Int32]
    ) throws -> DisplayBuffer {
        if let existing = buffers[request.allocation_id] {
            guard existing.width == request.width,
                  existing.height == request.height,
                  existing.format == request.drm_format,
                  existing.modifier == request.drm_modifier,
                  existing.offset == request.plane_offset,
                  existing.stride == request.plane_stride
            else { throw DisplayHostError.invalidRequest }
            return existing
        }
        let params: WaylandProxy<ZwpLinuxBufferParamsV1Client>
        do {
            params = try dmabuf.createParams()
        } catch {
            throw DisplayHostError.wayland("dma-buf params creation failed")
        }
        defer { try? params.destroy() }
        try params.add(
            fd: try duplicateDisplayDescriptor(descriptors[0]),
            plane_idx: 0,
            offset: request.plane_offset,
            stride: request.plane_stride,
            modifier_hi: UInt32(request.drm_modifier >> 32),
            modifier_lo: UInt32(truncatingIfNeeded: request.drm_modifier))
        let proxy = try params.createImmed(
            width: Int32(request.width),
            height: Int32(request.height),
            format: request.drm_format,
            flags: ZwpLinuxBufferParamsV1Flags(rawValue: 0))
        let lifetime = dup(descriptors[1])
        guard lifetime >= 0 else {
            try? proxy.destroy()
            throw systemError("duplicating allocation lifetime")
        }
        let buffer = DisplayBuffer(
            proxy: proxy,
            lifetime: LinuxOwnedFileDescriptor(adopting: lifetime),
            width: request.width,
            height: request.height,
            format: request.drm_format,
            modifier: request.drm_modifier,
            offset: request.plane_offset,
            stride: request.plane_stride)
        try proxy.installListener(self)
        buffers[request.allocation_id] = buffer
        return buffer
    }

    private func dispatchWaylandOnce(displayID: UInt64) async throws {
        guard let preparation = connection.prepareRead() else {
            throw DisplayHostError.wayland("prepare-read failed")
        }
        guard connection.flush() >= 0 else {
            preparation.read.cancel()
            throw DisplayHostError.wayland("flush failed")
        }
        let batch = try await reactor.wait(interests: [
            LinuxReactorInterest(
                token: 1,
                fileDescriptor: connection.fd,
                events: Int16(POLLIN)),
        ], timeoutNanoseconds: nil)
        let readable = batch.events.contains {
            $0.token == 1
                && LinuxPollResult(
                    returnedEvents: $0.returnedEvents).isReadable
        }
        guard preparation.read.complete(readable: readable) >= 0 else {
            throw DisplayHostError.wayland("event dispatch failed")
        }
        if let deferredFailure {
            throw deferredFailure
        }
        if surfaces[displayID]?.closed != false {
            throw DisplayHostError.wayland("surface closed")
        }
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>, serial: UInt32
    ) {
        guard let displayID = displayIDByXdgSurface[proxy.identity],
              let displaySurface = surfaces[displayID]
        else { return }
        try? displaySurface.xdgSurface.ackConfigure(serial: serial)
        displaySurface.configured = true
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32,
        states: WaylandClientArrayView
    ) {}

    func close(_ proxy: WaylandBorrowedProxy<XdgToplevelClient>) {
        guard let displayID = displayIDByToplevel[proxy.identity] else {
            return
        }
        surfaces[displayID]?.closed = true
    }
    func release(_ proxy: WaylandBorrowedProxy<WlBufferClient>) {
        guard let allocation = buffers.first(where: {
            $0.value.proxy.identity == proxy.identity
        })?.key else {
            return
        }
        if let removed = buffers.removeValue(forKey: allocation) {
            try? removed.proxy.destroy()
        }
    }
    func syncOutput(
        _ proxy: WaylandBorrowedProxy<
            WpPresentationFeedbackClient>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {
        guard var entry = presentationFeedback[proxy.identity],
              let displayID = outputTopology.displayID(
                proxyIdentity: output.identity)
        else { return }
        entry.displayID = displayID
        presentationFeedback[proxy.identity] = entry
    }
    func presented(
        _ proxy: WaylandBorrowedProxy<
            WpPresentationFeedbackClient>,
        tv_sec_hi: UInt32,
        tv_sec_lo: UInt32,
        tv_nsec: UInt32,
        refresh: UInt32,
        seq_hi: UInt32,
        seq_lo: UInt32,
        flags: WpPresentationFeedbackKind
    ) {
        guard let entry = presentationFeedback.removeValue(
            forKey: proxy.identity)
        else { return }
        guard bridge.signalPresent(point: entry.presentPoint) else {
            deferredFailure = systemError(
                "signaling Composer physical-present fence")
            return
        }
        let sequence =
            UInt64(seq_hi) << 32 | UInt64(seq_lo)
        let seconds = UInt64(tv_sec_hi) << 32 | UInt64(tv_sec_lo)
        let (secondNanoseconds, secondsOverflow) =
            seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (timestampNanoseconds, timestampOverflow) =
            secondNanoseconds.addingReportingOverflow(UInt64(tv_nsec))
        guard tv_nsec < 1_000_000_000,
              !secondsOverflow,
              !timestampOverflow,
              let selectedPeriod =
                outputTopology.refreshPeriodNanoseconds(
                    displayID: entry.displayID)
        else {
            deferredFailure = .wayland(
                "invalid physical presentation timestamp")
            return
        }
        let refreshPeriod = refresh == 0
            ? selectedPeriod
            : UInt64(refresh)
        presentationSink?(PresentationSample(
            displayID: entry.displayID,
            timestampNanoseconds: timestampNanoseconds,
            refreshPeriodNanoseconds: refreshPeriod,
            sequence: sequence))
        let latency = elapsedMicroseconds(
            since: entry.committed)
        let diagnostic =
            "{\"component\":\"nucleus-android-display-host\","
            + "\"stage\":\"presentation.physically-presented\","
            + "\"frameNumber\":\(entry.frameNumber),"
            + "\"presentPoint\":\(entry.presentPoint),"
            + "\"sequence\":\(sequence),"
            + "\"refreshNanoseconds\":\(refresh),"
            + "\"presentationLatencyMicroseconds\":\(latency)}\n"
        FileHandle.standardError.write(
            Data(diagnostic.utf8))
    }
    func discarded(
        _ proxy: WaylandBorrowedProxy<
            WpPresentationFeedbackClient>
    ) {
        guard let entry = presentationFeedback.removeValue(
            forKey: proxy.identity)
        else { return }
        if !bridge.signalPresent(point: entry.presentPoint) {
            deferredFailure = systemError(
                "signaling discarded Composer present fence")
            return
        }
        let diagnostic =
            "{\"component\":\"nucleus-android-display-host\","
            + "\"stage\":\"presentation.discarded\","
            + "\"frameNumber\":\(entry.frameNumber),"
            + "\"presentPoint\":\(entry.presentPoint)}\n"
        FileHandle.standardError.write(
            Data(diagnostic.utf8))
        deferredFailure = .wayland(
            "physical presentation discarded for Composer3 frame "
                + "\(entry.frameNumber)")
    }
    func configureBounds(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32, height: Int32
    ) {}
    func wmCapabilities(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        capabilities: WaylandClientArrayView
    ) {}

    isolated deinit {
        for buffer in buffers.values {
            try? buffer.proxy.destroy()
        }
        for displaySurface in surfaces.values {
            try? displaySurface.acquireTimeline.destroy()
            try? displaySurface.releaseTimeline.destroy()
            try? displaySurface.syncSurface.destroy()
            try? displaySurface.toplevel.destroy()
            try? displaySurface.xdgSurface.destroy()
            try? displaySurface.surface.destroy()
        }
    }
}

@safe private final class DisplayBuffer {
    let proxy: WaylandProxy<WlBufferClient>
    let lifetime: LinuxOwnedFileDescriptor
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64
    let offset: UInt32
    let stride: UInt32

    init(
        proxy: WaylandProxy<WlBufferClient>,
        lifetime: consuming LinuxOwnedFileDescriptor,
        width: UInt32,
        height: UInt32,
        format: UInt32,
        modifier: UInt64,
        offset: UInt32,
        stride: UInt32
    ) {
        self.proxy = proxy
        self.lifetime = consume lifetime
        self.width = width
        self.height = height
        self.format = format
        self.modifier = modifier
        self.offset = offset
        self.stride = stride
    }
}

@MainActor
private final class DisplayWmBaseHandler: XdgWmBaseEvents {
    weak var proxy: WaylandProxy<XdgWmBaseClient>?

    func ping(
        _ proxy: WaylandBorrowedProxy<XdgWmBaseClient>, serial: UInt32
    ) {
        try? self.proxy?.pong(serial: serial)
    }
}

private func duplicateDisplayDescriptor(
    _ descriptor: Int32
) throws -> WaylandClientOwnedFileDescriptor {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else {
        throw systemError("duplicating dma-buf plane")
    }
    return WaylandClientOwnedFileDescriptor(duplicate)
}

private func systemError(_ operation: String) -> DisplayHostError {
    .systemCall(operation, errno)
}
