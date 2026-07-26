import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import NucleusAndroidIPC
import NucleusLinuxReactor
import WaylandClient
import WaylandClientDispatch
import WaylandProtocolTypes

public struct SurfaceProbeConfiguration: Sendable {
    public var waylandSocket: String?
    public var brokerSocket: String?
    public var width: UInt32
    public var height: UInt32
    public var frameCount: UInt64
    public var eventTimeoutMilliseconds: Int32

    public init(
        waylandSocket: String? = nil,
        brokerSocket: String? = nil,
        width: UInt32 = 1280,
        height: UInt32 = 720,
        frameCount: UInt64 = 0,
        eventTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.waylandSocket = waylandSocket
        self.brokerSocket = brokerSocket
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.eventTimeoutMilliseconds = eventTimeoutMilliseconds
    }
}

public struct SurfaceProbeReport: Codable, Equatable, Sendable {
    public var feedback: WaylandDmabufFeedback
    public var brokerDevice: BrokerDeviceDiagnostic?
    public var allocatedBufferCount: Int
    public var submittedFrameCount: UInt64
    public var presentedFrameCount: UInt64
    public var discardedFrameCount: UInt64
    public var lifecycleEvents: [SurfaceProbeLifecycleEvent]

    public init(
        feedback: WaylandDmabufFeedback,
        brokerDevice: BrokerDeviceDiagnostic? = nil,
        allocatedBufferCount: Int = 0,
        submittedFrameCount: UInt64 = 0,
        presentedFrameCount: UInt64 = 0,
        discardedFrameCount: UInt64 = 0,
        lifecycleEvents: [SurfaceProbeLifecycleEvent] = []
    ) {
        self.feedback = feedback
        self.brokerDevice = brokerDevice
        self.allocatedBufferCount = allocatedBufferCount
        self.submittedFrameCount = submittedFrameCount
        self.presentedFrameCount = presentedFrameCount
        self.discardedFrameCount = discardedFrameCount
        self.lifecycleEvents = lifecycleEvents
    }
}

public struct SurfaceProbeLifecycleEvent: Codable, Equatable, Sendable {
    public var stage: String
    public var bufferID: UInt64?
    public var frameNumber: UInt64?
    public var acquirePoint: UInt64?
    public var releasePoint: UInt64?

    public init(
        stage: String,
        bufferID: UInt64? = nil,
        frameNumber: UInt64? = nil,
        acquirePoint: UInt64? = nil,
        releasePoint: UInt64? = nil
    ) {
        self.stage = stage
        self.bufferID = bufferID
        self.frameNumber = frameNumber
        self.acquirePoint = acquirePoint
        self.releasePoint = releasePoint
    }
}

@MainActor
@safe public final class AndroidSurfaceProbe {
    private let configuration: SurfaceProbeConfiguration
    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private let compositor: WaylandProxy<WlCompositorClient>
    private let dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    private let wmBase: WaylandProxy<XdgWmBaseClient>
    private let syncobjManager:
        WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>
    private let presentation: WaylandProxy<WpPresentationClient>
    private let wmHandler = WmBaseHandler()
    private let reactor: LinuxHostReactor

    public init(configuration: SurfaceProbeConfiguration) throws {
        guard let connection = WaylandConnection(socket: configuration.waylandSocket) else {
            throw SurfaceProbeError.waylandConnectionFailed
        }
        guard let registry = WaylandRegistry(connection, wanting: [
            DesiredGlobal<WlCompositorClient>(maximumVersion: 6),
            DesiredGlobal<ZwpLinuxDmabufV1Client>(maximumVersion: 5),
            DesiredGlobal<XdgWmBaseClient>(maximumVersion: 6),
            DesiredGlobal<WpLinuxDrmSyncobjManagerV1Client>(
                maximumVersion: 1),
            DesiredGlobal<WpPresentationClient>(maximumVersion: 1),
        ]) else { throw SurfaceProbeError.waylandConnectionFailed }
        self.configuration = configuration
        self.connection = connection
        self.registry = registry
        self.reactor = try LinuxHostReactor()
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw SurfaceProbeError.roundtripFailed
        }
        guard let compositor = registry.singleton(WlCompositorClient.self),
              let dmabuf = registry.singleton(ZwpLinuxDmabufV1Client.self),
              let wmBase = registry.singleton(XdgWmBaseClient.self),
              let syncobjManager = registry.singleton(
                WpLinuxDrmSyncobjManagerV1Client.self),
              let presentation = registry.singleton(WpPresentationClient.self)
        else { throw SurfaceProbeError.missingGlobal("required probe protocol") }
        self.compositor = compositor
        self.dmabuf = dmabuf
        self.wmBase = wmBase
        self.syncobjManager = syncobjManager
        self.presentation = presentation
        wmHandler.proxy = wmBase
        try wmBase.installListener(wmHandler)
    }

    public func run() async throws -> SurfaceProbeReport {
        do {
            let report = try await runProbe()
            await reactor.shutdown()
            return report
        } catch {
            await reactor.shutdown()
            throw error
        }
    }

    private func runProbe() async throws -> SurfaceProbeReport {
        let feedback = try await collectFeedback()
        guard let brokerSocket = configuration.brokerSocket else {
            return SurfaceProbeReport(feedback: feedback)
        }
        let broker = try BrokerPacketConnection.connect(path: brokerSocket)
        try broker.requirePeer(userID: UInt32(geteuid()))
        try broker.send(BrokerEnvelope(messageID: 1, kind: .hello))
        let hello = try await receivePacket(from: broker)
        guard hello.envelope.kind == .helloReply else {
            throw brokerError(hello.envelope)
        }
        try broker.send(BrokerEnvelope(
            messageID: 2,
            kind: .allocate,
            allocationRequest: BufferAllocationRequest(
                width: configuration.width,
                height: configuration.height,
                feedback: feedback)))
        let allocationPacket = try await receivePacket(from: broker)
        guard allocationPacket.envelope.kind == .allocationReply,
              let allocation = allocationPacket.envelope.allocationReply
        else { throw brokerError(allocationPacket.envelope) }
        let descriptors = allocationPacket.takeDescriptors()
        defer { for descriptor in descriptors { _ = close(descriptor) } }
        let presenter = try await SurfacePresenter(
            connection: connection,
            reactor: reactor,
            compositor: compositor,
            dmabuf: dmabuf,
            wmBase: wmBase,
            syncobjManager: syncobjManager,
            presentation: presentation,
            allocation: allocation,
            descriptors: descriptors,
            timeoutMilliseconds: configuration.eventTimeoutMilliseconds)
        try await presenter.present(
            frames: configuration.frameCount,
            through: broker)
        let lifecycleEvents = presenter.finish()
        return SurfaceProbeReport(
            feedback: feedback,
            brokerDevice: allocation.device,
            allocatedBufferCount: allocation.buffers.count,
            submittedFrameCount: presenter.submitted,
            presentedFrameCount: presenter.presented,
            discardedFrameCount: presenter.discarded,
            lifecycleEvents: lifecycleEvents)
    }

    private func collectFeedback() async throws -> WaylandDmabufFeedback {
        let proxy: WaylandProxy<ZwpLinuxDmabufFeedbackV1Client>
        do {
            proxy = try dmabuf.getDefaultFeedback()
        } catch {
            throw SurfaceProbeError.waylandObjectCreationFailed(
                "dma-buf feedback")
        }
        defer { try? proxy.destroy() }
        let collector = WaylandDmabufFeedbackCollector()
        try proxy.installListener(collector)
        try await dispatchWaylandUntil(
            connection: connection,
            reactor: reactor,
            timeoutMilliseconds: configuration.eventTimeoutMilliseconds
        ) { collector.feedback != nil || collector.failure != nil }
        if let failure = collector.failure { throw failure }
        guard let feedback = collector.feedback else {
            throw SurfaceProbeError.incompleteFeedback
        }
        return feedback
    }

    private func receivePacket(
        from broker: BrokerPacketConnection
    ) async throws -> ReceivedBrokerPacket {
        try await waitUntilReadable(
            reactor: reactor,
            fileDescriptor: broker.fileDescriptor,
            timeoutMilliseconds: configuration.eventTimeoutMilliseconds,
            terminalError: .invalidBrokerReply)
        return try broker.receive()
    }
}

@MainActor
private final class WmBaseHandler: XdgWmBaseEvents {
    weak var proxy: WaylandProxy<XdgWmBaseClient>?

    func ping(
        _ proxy: WaylandBorrowedProxy<XdgWmBaseClient>, serial: UInt32
    ) {
        try? self.proxy?.pong(serial: serial)
    }
}

@MainActor
@safe private final class SurfacePresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WpPresentationFeedbackEvents
{
    private let connection: WaylandConnection
    private let reactor: LinuxHostReactor
    private let surface: WaylandProxy<WlSurfaceClient>
    private let xdgSurface: WaylandProxy<XdgSurfaceClient>
    private let toplevel: WaylandProxy<XdgToplevelClient>
    private let syncSurface:
        WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
    private let acquireTimeline:
        WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
    private let presentation: WaylandProxy<WpPresentationClient>
    private let timeoutMilliseconds: Int32
    private var buffers: [UInt64: WaylandProxy<WlBufferClient>] = [:]
    private var releaseTimelines:
        [UInt64: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>] = [:]
    private var releaseWaiters: [UInt64: OpaquePointer] = unsafe [:]
    private var previousReleasePoint: [UInt64: UInt64] = [:]
    private var presentationFrames:
        [UInt: (
            proxy: WaylandProxy<WpPresentationFeedbackClient>,
            event: SurfaceProbeLifecycleEvent
        )] = [:]
    private var lifecycleEvents: [SurfaceProbeLifecycleEvent] = []
    private var configured = false
    private var closed = false
    private var didTearDown = false
    private(set) var submitted: UInt64 = 0
    private(set) var presented: UInt64 = 0
    private(set) var discarded: UInt64 = 0

    init(
        connection: WaylandConnection,
        reactor: LinuxHostReactor,
        compositor: WaylandProxy<WlCompositorClient>,
        dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>,
        wmBase: WaylandProxy<XdgWmBaseClient>,
        syncobjManager: WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>,
        presentation: WaylandProxy<WpPresentationClient>,
        allocation: BufferAllocationReply,
        descriptors: [Int32],
        timeoutMilliseconds: Int32
    ) async throws {
        guard descriptors.indices.contains(
            Int(allocation.acquireTimelineFDIndex))
        else { throw SurfaceProbeError.invalidBrokerReply }
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let syncSurface: WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        let acquireTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        do {
            surface = try compositor.createSurface()
            xdgSurface = try wmBase.getXdgSurface(surface: surface)
            toplevel = try xdgSurface.getToplevel()
            syncSurface = try syncobjManager.getSurface(surface: surface)
            acquireTimeline = try syncobjManager.importTimeline(
                fd: try duplicateDescriptor(
                    descriptors[Int(allocation.acquireTimelineFDIndex)]))
        } catch {
            throw SurfaceProbeError.waylandObjectCreationFailed("surface tree")
        }
        self.connection = connection
        self.reactor = reactor
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.toplevel = toplevel
        self.syncSurface = syncSurface
        self.acquireTimeline = acquireTimeline
        self.presentation = presentation
        self.timeoutMilliseconds = timeoutMilliseconds
        try xdgSurface.installListener(self)
        try toplevel.installListener(self)
        try toplevel.setAppId(app_id: "android.dev.nucleus.graphics-probe")
        try toplevel.setTitle(title: "Nucleus Android Graphics Probe")
        for description in allocation.buffers {
            guard descriptors.indices.contains(Int(description.releaseTimelineFDIndex)),
                  let releaseWaiter = allocation.device.renderNode.withCString({ path in
                    unsafe nucleus_android_syncobj_waiter_create(
                        path,
                        descriptors[Int(description.releaseTimelineFDIndex)])
                  })
            else {
                throw SurfaceProbeError.waylandObjectCreationFailed(
                    "per-buffer release timeline")
            }
            let releaseTimeline: WaylandProxy<
                WpLinuxDrmSyncobjTimelineV1Client
            >
            do {
                releaseTimeline = try syncobjManager.importTimeline(
                    fd: try duplicateDescriptor(
                        descriptors[Int(description.releaseTimelineFDIndex)]))
            } catch {
                unsafe nucleus_android_syncobj_waiter_destroy(releaseWaiter)
                throw SurfaceProbeError.waylandObjectCreationFailed(
                    "per-buffer release timeline")
            }
            releaseTimelines[description.id] = releaseTimeline
            unsafe releaseWaiters[description.id] = releaseWaiter
            let params: WaylandProxy<ZwpLinuxBufferParamsV1Client>
            do {
                params = try dmabuf.createParams()
            } catch {
                throw SurfaceProbeError.waylandObjectCreationFailed("dma-buf params")
            }
            defer { try? params.destroy() }
            for (planeIndex, plane) in description.planes.enumerated() {
                guard descriptors.indices.contains(Int(plane.fdIndex)) else {
                    throw SurfaceProbeError.invalidBrokerReply
                }
                try params.add(
                    fd: try duplicateDescriptor(
                        descriptors[Int(plane.fdIndex)]),
                    plane_idx: UInt32(planeIndex),
                    offset: plane.offset,
                    stride: plane.stride,
                    modifier_hi: UInt32(description.modifier >> 32),
                    modifier_lo: UInt32(
                        truncatingIfNeeded: description.modifier))
            }
            let buffer = try params.createImmed(
                width: Int32(description.width),
                height: Int32(description.height),
                format: description.format,
                flags: ZwpLinuxBufferParamsV1Flags(rawValue: 0))
            buffers[description.id] = buffer
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "wayland.buffer-import",
                bufferID: description.id))
        }
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.configure-commit"))
        try surface.commit()
        guard connection.flush() >= 0 else { throw SurfaceProbeError.compositorClosed }
        try await dispatchUntil { configured || closed }
        if closed { throw SurfaceProbeError.compositorClosed }
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.surface-configured"))
    }

    func present(
        frames: UInt64,
        through broker: BrokerPacketConnection
    ) async throws {
        guard !buffers.isEmpty else {
            throw SurfaceProbeError.invalidBrokerReply
        }
        guard frames > 0 else { return }
        let ordered = buffers.keys.sorted()
        for frame in 1...frames {
            let bufferID = ordered[Int((frame - 1) % UInt64(ordered.count))]
            if let priorRelease = previousReleasePoint[bufferID] {
                lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                    stage: "wayland.release-wait.begin",
                    bufferID: bufferID,
                    frameNumber: frame,
                    releasePoint: priorRelease))
                try await waitForRelease(bufferID: bufferID, point: priorRelease)
                lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                    stage: "wayland.release-observed",
                    bufferID: bufferID,
                    frameNumber: frame,
                    releasePoint: priorRelease))
            }
            if closed { throw SurfaceProbeError.compositorClosed }
            try broker.send(BrokerEnvelope(
                messageID: frame &+ 2,
                kind: .render,
                renderRequest: RenderRequest(
                    bufferID: bufferID,
                    frameNumber: frame,
                    releasePoint: previousReleasePoint[bufferID])))
            try await waitUntilReadable(
                reactor: reactor,
                fileDescriptor: broker.fileDescriptor,
                timeoutMilliseconds: timeoutMilliseconds,
                terminalError: .invalidBrokerReply)
            let packet = try broker.receive()
            guard packet.envelope.kind == .renderReply,
                  let render = packet.envelope.renderReply,
                  render.bufferID == bufferID,
                  render.frameNumber == frame,
                  let buffer = buffers[bufferID],
                  let releaseTimeline = releaseTimelines[bufferID]
            else { throw brokerError(packet.envelope) }
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "broker.guest-submission-accepted",
                bufferID: bufferID,
                frameNumber: frame,
                acquirePoint: render.acquirePoint,
                releasePoint: render.releasePoint))
            try syncSurface.setAcquirePoint(
                timeline: acquireTimeline,
                point_hi: UInt32(render.acquirePoint >> 32),
                point_lo: UInt32(truncatingIfNeeded: render.acquirePoint))
            try syncSurface.setReleasePoint(
                timeline: releaseTimeline,
                point_hi: UInt32(render.releasePoint >> 32),
                point_lo: UInt32(truncatingIfNeeded: render.releasePoint))
            try surface.attach(buffer: buffer, x: 0, y: 0)
            try surface.damageBuffer(
                x: 0,
                y: 0,
                width: Int32.max,
                height: Int32.max)
            if let feedback = try? presentation.feedback(surface: surface) {
                try feedback.installListener(self)
                presentationFrames[feedback.identity] = (
                    proxy: feedback,
                    event: SurfaceProbeLifecycleEvent(
                        stage: "wayland.presentation-pending",
                        bufferID: bufferID,
                        frameNumber: frame,
                        acquirePoint: render.acquirePoint,
                        releasePoint: render.releasePoint))
            }
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "wayland.commit",
                bufferID: bufferID,
                frameNumber: frame,
                acquirePoint: render.acquirePoint,
                releasePoint: render.releasePoint))
            try surface.commit()
            guard connection.flush() >= 0 else { throw SurfaceProbeError.compositorClosed }
            previousReleasePoint[bufferID] = render.releasePoint
            submitted &+= 1
            try await dispatchUntil {
                presented + discarded == submitted || closed
            }
        }
        if closed { throw SurfaceProbeError.compositorClosed }
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>, serial: UInt32
    ) {
        try? xdgSurface.ackConfigure(serial: serial)
        configured = true
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32,
        states: WaylandClientArrayView
    ) {}

    func close(_ proxy: WaylandBorrowedProxy<XdgToplevelClient>) {
        closed = true
    }
    func configureBounds(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32, height: Int32
    ) {}
    func wmCapabilities(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        capabilities: WaylandClientArrayView
    ) {}

    func syncOutput(
        _ proxy: WaylandBorrowedProxy<WpPresentationFeedbackClient>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}

    func presented(
        _ proxy: WaylandBorrowedProxy<WpPresentationFeedbackClient>,
        tv_sec_hi: UInt32,
        tv_sec_lo: UInt32,
        tv_nsec: UInt32,
        refresh: UInt32,
        seq_hi: UInt32,
        seq_lo: UInt32,
        flags: WpPresentationFeedbackKind
    ) {
        presented &+= 1
        if let entry = presentationFrames.removeValue(
            forKey: proxy.identity
        ) {
            var event = entry.event
            event.stage = "wayland.presented"
            lifecycleEvents.append(event)
        }
    }

    func discarded(
        _ proxy: WaylandBorrowedProxy<WpPresentationFeedbackClient>
    ) {
        discarded &+= 1
        if let entry = presentationFrames.removeValue(
            forKey: proxy.identity
        ) {
            var event = entry.event
            event.stage = "wayland.discarded"
            lifecycleEvents.append(event)
        }
    }

    func finish() -> [SurfaceProbeLifecycleEvent] {
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.surface-teardown.begin"))
        tearDown()
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.surface-teardown.complete"))
        return lifecycleEvents
    }

    private func waitForRelease(
        bufferID: UInt64,
        point: UInt64
    ) async throws {
        guard let waiter = unsafe releaseWaiters[bufferID] else {
            throw SurfaceProbeError.invalidBrokerReply
        }
        let initial = unsafe nucleus_android_syncobj_waiter_is_signaled(
            waiter,
            point)
        if initial == 1 { return }
        guard initial == 0,
              unsafe nucleus_android_syncobj_waiter_arm(waiter, point) == 0
        else { throw SurfaceProbeError.compositorClosed }
        let notification = unsafe nucleus_android_syncobj_waiter_notification_fd(
            waiter)
        try await dispatchUntil(extraFileDescriptor: notification) {
            unsafe nucleus_android_syncobj_waiter_is_signaled(
                waiter,
                point) == 1 || closed
        }
        guard unsafe nucleus_android_syncobj_waiter_drain(waiter) == 0 else {
            throw SurfaceProbeError.compositorClosed
        }
    }

    private func dispatchUntil(
        extraFileDescriptor: Int32? = nil,
        _ condition: () -> Bool
    ) async throws {
        try await dispatchWaylandUntil(
            connection: connection,
            reactor: reactor,
            extraFileDescriptor: extraFileDescriptor,
            timeoutMilliseconds: timeoutMilliseconds,
            condition)
    }

    isolated deinit {
        tearDown()
    }

    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        presentationFrames.removeAll()
        for buffer in buffers.values {
            try? buffer.destroy()
        }
        for timeline in releaseTimelines.values {
            try? timeline.destroy()
        }
        for unsafe waiter in unsafe releaseWaiters.values {
            unsafe nucleus_android_syncobj_waiter_destroy(waiter)
        }
        try? acquireTimeline.destroy()
        try? syncSurface.destroy()
        try? toplevel.destroy()
        try? xdgSurface.destroy()
        try? surface.destroy()
    }
}

@MainActor
private func waitUntilReadable(
    reactor: LinuxHostReactor,
    fileDescriptor: Int32,
    timeoutMilliseconds: Int32,
    terminalError: SurfaceProbeError
) async throws {
    let deadline = monotonicMilliseconds() + Int64(timeoutMilliseconds)
    while true {
        let remaining = deadline - monotonicMilliseconds()
        guard remaining > 0 else { throw SurfaceProbeError.eventTimeout }
        let batch = try await reactor.wait(
            interests: [LinuxReactorInterest(
                token: 3,
                fileDescriptor: fileDescriptor,
                events: Int16(POLLIN))],
            timeoutNanoseconds: UInt64(remaining) * 1_000_000)
        if batch.didReachDeadline { throw SurfaceProbeError.eventTimeout }
        guard let event = batch.events.first(where: { $0.token == 3 }) else {
            continue
        }
        if let failure = event.failureCode {
            throw SurfaceProbeError.reactorFailure(failure)
        }
        let result = LinuxPollResult(returnedEvents: event.returnedEvents)
        if result.isReadable { return }
        if result.isTerminal { throw terminalError }
    }
}

@MainActor
private func dispatchWaylandUntil(
    connection: WaylandConnection,
    reactor: LinuxHostReactor,
    extraFileDescriptor: Int32? = nil,
    timeoutMilliseconds: Int32,
    _ condition: () -> Bool
) async throws {
    let deadline = monotonicMilliseconds() + Int64(timeoutMilliseconds)
    while !condition() {
        guard let preparation = connection.prepareRead() else {
            throw SurfaceProbeError.compositorClosed
        }
        let flushResult = connection.flush()
        let flushError = errno
        if flushResult < 0 && flushError != EAGAIN {
            preparation.read.cancel()
            throw SurfaceProbeError.compositorClosed
        }
        let writeEvents = flushResult < 0 && flushError == EAGAIN
            ? Int16(POLLOUT)
            : 0
        var interests = [LinuxReactorInterest(
            token: 1,
            fileDescriptor: connection.fd,
            events: Int16(POLLIN) | writeEvents)]
        if let extraFileDescriptor {
            interests.append(LinuxReactorInterest(
                token: 2,
                fileDescriptor: extraFileDescriptor,
                events: Int16(POLLIN)))
        }
        let remaining = deadline - monotonicMilliseconds()
        guard remaining > 0 else {
            preparation.read.cancel()
            throw SurfaceProbeError.eventTimeout
        }
        let batch: LinuxReactorBatch
        do {
            batch = try await reactor.wait(
                interests: interests,
                timeoutNanoseconds: UInt64(remaining) * 1_000_000)
        } catch {
            preparation.read.cancel()
            throw error
        }
        guard !batch.didReachDeadline else {
            preparation.read.cancel()
            throw SurfaceProbeError.eventTimeout
        }
        let displayEvent = batch.events.first(where: { $0.token == 1 })
        let extraEvent = batch.events.first(where: { $0.token == 2 })
        if let failure = displayEvent?.failureCode ?? extraEvent?.failureCode {
            preparation.read.cancel()
            throw SurfaceProbeError.reactorFailure(failure)
        }
        if let displayEvent {
            let result = LinuxPollResult(returnedEvents: displayEvent.returnedEvents)
            if result.isTerminal && !result.isReadable {
                preparation.read.cancel()
                throw SurfaceProbeError.compositorClosed
            }
        }
        if let extraEvent {
            let result = LinuxPollResult(returnedEvents: extraEvent.returnedEvents)
            if result.isTerminal && !result.isReadable {
                preparation.read.cancel()
                throw SurfaceProbeError.compositorClosed
            }
        }
        let readable = displayEvent.map {
            LinuxPollResult(returnedEvents: $0.returnedEvents).isReadable
        } ?? false
        guard preparation.read.complete(readable: readable) >= 0 else {
            throw SurfaceProbeError.compositorClosed
        }
    }
}

private func monotonicMilliseconds() -> Int64 {
    var time = timespec()
    _ = unsafe clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000 + Int64(time.tv_nsec) / 1_000_000
}

private func duplicateDescriptor(
    _ descriptor: Int32
) throws -> WaylandClientOwnedFileDescriptor {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else {
        throw SurfaceProbeError.invalidBrokerReply
    }
    return WaylandClientOwnedFileDescriptor(duplicate)
}

private func brokerError(_ envelope: BrokerEnvelope) -> Error {
    if let failure = envelope.failure { return SurfaceProbeError.brokerFailure(failure) }
    return SurfaceProbeError.invalidBrokerReply
}
