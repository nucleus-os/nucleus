import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import NucleusAndroidIPC
import NucleusLinuxReactor
import WaylandClient
import WaylandClientC
import WaylandClientDispatch

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
public final class AndroidSurfaceProbe {
    private let configuration: SurfaceProbeConfiguration
    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private var compositor: OpaquePointer?
    private var dmabuf: OpaquePointer?
    private var wmBase: OpaquePointer?
    private var syncobjManager: OpaquePointer?
    private var presentation: OpaquePointer?
    private let wmHandler = WmBaseHandler()
    private let reactor: LinuxHostReactor

    public init(configuration: SurfaceProbeConfiguration) throws {
        guard let connection = WaylandConnection(socket: configuration.waylandSocket) else {
            throw SurfaceProbeError.waylandConnectionFailed
        }
        guard let registry = WaylandRegistry(connection, wanting: [
            DesiredGlobal(swift_wayland_iface_wl_compositor(), maxVersion: 6),
            DesiredGlobal(swift_wayland_iface_zwp_linux_dmabuf_v1(), maxVersion: 5),
            DesiredGlobal(swift_wayland_iface_xdg_wm_base(), maxVersion: 6),
            DesiredGlobal(
                swift_wayland_iface_wp_linux_drm_syncobj_manager_v1(),
                maxVersion: 1),
            DesiredGlobal(swift_wayland_iface_wp_presentation(), maxVersion: 1),
        ]) else { throw SurfaceProbeError.waylandConnectionFailed }
        self.configuration = configuration
        self.connection = connection
        self.registry = registry
        self.reactor = try LinuxHostReactor()
        registry.onBind = { [weak self] global in self?.bound(global) }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw SurfaceProbeError.roundtripFailed
        }
        try requireGlobals()
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
            compositor: require(compositor, "wl_compositor"),
            dmabuf: require(dmabuf, "zwp_linux_dmabuf_v1"),
            wmBase: require(wmBase, "xdg_wm_base"),
            syncobjManager: require(
                syncobjManager,
                "wp_linux_drm_syncobj_manager_v1"),
            presentation: require(presentation, "wp_presentation"),
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

    private func bound(_ global: BoundGlobal) {
        switch String(cString: global.interface.pointee.name) {
        case "wl_compositor": compositor = global.proxy
        case "zwp_linux_dmabuf_v1": dmabuf = global.proxy
        case "xdg_wm_base":
            wmBase = global.proxy
            XdgWmBaseClient.addListener(global.proxy, owner: wmHandler)
        case "wp_linux_drm_syncobj_manager_v1": syncobjManager = global.proxy
        case "wp_presentation": presentation = global.proxy
        default: break
        }
    }

    private func requireGlobals() throws {
        _ = try require(compositor, "wl_compositor")
        _ = try require(dmabuf, "zwp_linux_dmabuf_v1")
        _ = try require(wmBase, "xdg_wm_base")
        _ = try require(syncobjManager, "wp_linux_drm_syncobj_manager_v1")
        _ = try require(presentation, "wp_presentation")
    }

    private func collectFeedback() async throws -> WaylandDmabufFeedback {
        guard let proxy = zwp_linux_dmabuf_v1_get_default_feedback(
            try require(dmabuf, "zwp_linux_dmabuf_v1"))
        else { throw SurfaceProbeError.waylandObjectCreationFailed("dma-buf feedback") }
        defer { zwp_linux_dmabuf_feedback_v1_destroy(proxy) }
        let collector = WaylandDmabufFeedbackCollector()
        ZwpLinuxDmabufFeedbackV1Client.addListener(proxy, owner: collector)
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

    private func require(_ proxy: OpaquePointer?, _ name: String) throws -> OpaquePointer {
        guard let proxy else { throw SurfaceProbeError.missingGlobal(name) }
        return proxy
    }
}

private final class WmBaseHandler: XdgWmBaseEvents {
    func ping(_ proxy: OpaquePointer, serial: UInt32) {
        xdg_wm_base_pong(proxy, serial)
    }
}

@MainActor
private final class SurfacePresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WpPresentationFeedbackEvents
{
    private let connection: WaylandConnection
    private let reactor: LinuxHostReactor
    private let surface: OpaquePointer
    private let xdgSurface: OpaquePointer
    private let toplevel: OpaquePointer
    private let syncSurface: OpaquePointer
    private let acquireTimeline: OpaquePointer
    private let presentation: OpaquePointer
    private let timeoutMilliseconds: Int32
    private var buffers: [UInt64: OpaquePointer] = [:]
    private var releaseTimelines: [UInt64: OpaquePointer] = [:]
    private var releaseWaiters: [UInt64: OpaquePointer] = [:]
    private var previousReleasePoint: [UInt64: UInt64] = [:]
    private var presentationFrames: [UInt: SurfaceProbeLifecycleEvent] = [:]
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
        compositor: OpaquePointer,
        dmabuf: OpaquePointer,
        wmBase: OpaquePointer,
        syncobjManager: OpaquePointer,
        presentation: OpaquePointer,
        allocation: BufferAllocationReply,
        descriptors: [Int32],
        timeoutMilliseconds: Int32
    ) async throws {
        guard let surface = wl_compositor_create_surface(compositor),
              let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface),
              let toplevel = xdg_surface_get_toplevel(xdgSurface),
              let syncSurface = wp_linux_drm_syncobj_manager_v1_get_surface(
                syncobjManager, surface),
              descriptors.indices.contains(Int(allocation.acquireTimelineFDIndex)),
              let acquireTimeline = wp_linux_drm_syncobj_manager_v1_import_timeline(
                syncobjManager,
                descriptors[Int(allocation.acquireTimelineFDIndex)])
        else { throw SurfaceProbeError.waylandObjectCreationFailed("surface tree") }
        self.connection = connection
        self.reactor = reactor
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.toplevel = toplevel
        self.syncSurface = syncSurface
        self.acquireTimeline = acquireTimeline
        self.presentation = presentation
        self.timeoutMilliseconds = timeoutMilliseconds
        XdgSurfaceClient.addListener(xdgSurface, owner: self)
        XdgToplevelClient.addListener(toplevel, owner: self)
        "android.dev.nucleus.graphics-probe".withCString {
            xdg_toplevel_set_app_id(toplevel, $0)
        }
        "Nucleus Android Graphics Probe".withCString {
            xdg_toplevel_set_title(toplevel, $0)
        }
        for description in allocation.buffers {
            guard descriptors.indices.contains(Int(description.releaseTimelineFDIndex)),
                  let releaseTimeline = wp_linux_drm_syncobj_manager_v1_import_timeline(
                    syncobjManager,
                    descriptors[Int(description.releaseTimelineFDIndex)]),
                  let releaseWaiter = allocation.device.renderNode.withCString({ path in
                    nucleus_android_syncobj_waiter_create(
                        path,
                        descriptors[Int(description.releaseTimelineFDIndex)])
                  })
            else {
                throw SurfaceProbeError.waylandObjectCreationFailed(
                    "per-buffer release timeline")
            }
            releaseTimelines[description.id] = releaseTimeline
            releaseWaiters[description.id] = releaseWaiter
            guard let params = zwp_linux_dmabuf_v1_create_params(dmabuf) else {
                throw SurfaceProbeError.waylandObjectCreationFailed("dma-buf params")
            }
            defer { zwp_linux_buffer_params_v1_destroy(params) }
            for (planeIndex, plane) in description.planes.enumerated() {
                guard descriptors.indices.contains(Int(plane.fdIndex)) else {
                    throw SurfaceProbeError.invalidBrokerReply
                }
                zwp_linux_buffer_params_v1_add(
                    params,
                    descriptors[Int(plane.fdIndex)],
                    UInt32(planeIndex),
                    plane.offset,
                    plane.stride,
                    UInt32(description.modifier >> 32),
                    UInt32(truncatingIfNeeded: description.modifier))
            }
            guard let buffer = zwp_linux_buffer_params_v1_create_immed(
                params,
                Int32(description.width),
                Int32(description.height),
                description.format,
                0)
            else { throw SurfaceProbeError.waylandObjectCreationFailed("wl_buffer") }
            buffers[description.id] = buffer
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "wayland.buffer-import",
                bufferID: description.id))
        }
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.configure-commit"))
        wl_surface_commit(surface)
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
        guard !buffers.isEmpty else { throw SurfaceProbeError.invalidBrokerReply }
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
            wp_linux_drm_syncobj_surface_v1_set_acquire_point(
                syncSurface,
                acquireTimeline,
                UInt32(render.acquirePoint >> 32),
                UInt32(truncatingIfNeeded: render.acquirePoint))
            wp_linux_drm_syncobj_surface_v1_set_release_point(
                syncSurface,
                releaseTimeline,
                UInt32(render.releasePoint >> 32),
                UInt32(truncatingIfNeeded: render.releasePoint))
            wl_surface_attach(surface, buffer, 0, 0)
            wl_surface_damage_buffer(surface, 0, 0, Int32.max, Int32.max)
            if let feedback = wp_presentation_feedback(presentation, surface) {
                WpPresentationFeedbackClient.addListener(feedback, owner: self)
                presentationFrames[UInt(bitPattern: feedback)] =
                    SurfaceProbeLifecycleEvent(
                        stage: "wayland.presentation-pending",
                        bufferID: bufferID,
                        frameNumber: frame,
                        acquirePoint: render.acquirePoint,
                        releasePoint: render.releasePoint)
            }
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "wayland.commit",
                bufferID: bufferID,
                frameNumber: frame,
                acquirePoint: render.acquirePoint,
                releasePoint: render.releasePoint))
            wl_surface_commit(surface)
            guard connection.flush() >= 0 else { throw SurfaceProbeError.compositorClosed }
            previousReleasePoint[bufferID] = render.releasePoint
            submitted &+= 1
            try await dispatchUntil {
                presented + discarded == submitted || closed
            }
        }
        if closed { throw SurfaceProbeError.compositorClosed }
    }

    func configure(_ proxy: OpaquePointer, serial: UInt32) {
        xdg_surface_ack_configure(proxy, serial)
        configured = true
    }

    func configure(
        _ proxy: OpaquePointer,
        width: Int32,
        height: Int32,
        states: UnsafeMutablePointer<wl_array>?
    ) {}

    func close(_ proxy: OpaquePointer) { closed = true }
    func configureBounds(_ proxy: OpaquePointer, width: Int32, height: Int32) {}
    func wmCapabilities(
        _ proxy: OpaquePointer,
        capabilities: UnsafeMutablePointer<wl_array>?
    ) {}

    func syncOutput(_ proxy: OpaquePointer, output: OpaquePointer?) {}

    func presented(
        _ proxy: OpaquePointer,
        tv_sec_hi: UInt32,
        tv_sec_lo: UInt32,
        tv_nsec: UInt32,
        refresh: UInt32,
        seq_hi: UInt32,
        seq_lo: UInt32,
        flags: UInt32
    ) {
        presented &+= 1
        if var event = presentationFrames.removeValue(
            forKey: UInt(bitPattern: proxy)
        ) {
            event.stage = "wayland.presented"
            lifecycleEvents.append(event)
        }
        wp_presentation_feedback_destroy(proxy)
    }

    func discarded(_ proxy: OpaquePointer) {
        discarded &+= 1
        if var event = presentationFrames.removeValue(
            forKey: UInt(bitPattern: proxy)
        ) {
            event.stage = "wayland.discarded"
            lifecycleEvents.append(event)
        }
        wp_presentation_feedback_destroy(proxy)
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
        guard let waiter = releaseWaiters[bufferID] else {
            throw SurfaceProbeError.invalidBrokerReply
        }
        let initial = nucleus_android_syncobj_waiter_is_signaled(waiter, point)
        if initial == 1 { return }
        guard initial == 0,
              nucleus_android_syncobj_waiter_arm(waiter, point) == 0
        else { throw SurfaceProbeError.compositorClosed }
        let notification = nucleus_android_syncobj_waiter_notification_fd(waiter)
        try await dispatchUntil(extraFileDescriptor: notification) {
            nucleus_android_syncobj_waiter_is_signaled(waiter, point) == 1 || closed
        }
        guard nucleus_android_syncobj_waiter_drain(waiter) == 0 else {
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
        for feedback in presentationFrames.keys {
            if let proxy = OpaquePointer(bitPattern: feedback) {
                wp_presentation_feedback_destroy(proxy)
            }
        }
        presentationFrames.removeAll()
        for buffer in buffers.values { wl_buffer_destroy(buffer) }
        for timeline in releaseTimelines.values {
            wp_linux_drm_syncobj_timeline_v1_destroy(timeline)
        }
        for waiter in releaseWaiters.values {
            nucleus_android_syncobj_waiter_destroy(waiter)
        }
        wp_linux_drm_syncobj_timeline_v1_destroy(acquireTimeline)
        wp_linux_drm_syncobj_surface_v1_destroy(syncSurface)
        xdg_toplevel_destroy(toplevel)
        xdg_surface_destroy(xdgSurface)
        wl_surface_destroy(surface)
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
    _ = clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000 + Int64(time.tv_nsec) / 1_000_000
}

private func brokerError(_ envelope: BrokerEnvelope) -> Error {
    if let failure = envelope.failure { return SurfaceProbeError.brokerFailure(failure) }
    return SurfaceProbeError.invalidBrokerReply
}
