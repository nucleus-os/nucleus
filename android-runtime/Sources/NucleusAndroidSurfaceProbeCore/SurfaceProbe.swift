import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import NucleusAndroidIPC
import NucleusLinuxReactor
import WaylandClient
import WaylandClientC
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
        guard let registry = unsafe WaylandRegistry(connection, wanting: [
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
        let compositor = try unsafe require(compositor, "wl_compositor")
        let dmabuf = try unsafe require(dmabuf, "zwp_linux_dmabuf_v1")
        let wmBase = try unsafe require(wmBase, "xdg_wm_base")
        let syncobjManager = try unsafe require(
            syncobjManager,
            "wp_linux_drm_syncobj_manager_v1")
        let presentation = try unsafe require(
            presentation,
            "wp_presentation")
        let presenter = try await unsafe SurfacePresenter(
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

    private func bound(_ global: BoundGlobal) {
        switch unsafe String(cString: global.interface.pointee.name) {
        case "wl_compositor": unsafe compositor = global.proxy
        case "zwp_linux_dmabuf_v1": unsafe dmabuf = global.proxy
        case "xdg_wm_base":
            unsafe wmBase = global.proxy
            unsafe XdgWmBaseClient.addListener(
                global.proxy,
                owner: wmHandler)
        case "wp_linux_drm_syncobj_manager_v1":
            unsafe syncobjManager = global.proxy
        case "wp_presentation": unsafe presentation = global.proxy
        default: break
        }
    }

    private func requireGlobals() throws {
        _ = try unsafe require(compositor, "wl_compositor")
        _ = try unsafe require(dmabuf, "zwp_linux_dmabuf_v1")
        _ = try unsafe require(wmBase, "xdg_wm_base")
        _ = try unsafe require(
            syncobjManager,
            "wp_linux_drm_syncobj_manager_v1")
        _ = try unsafe require(presentation, "wp_presentation")
    }

    private func collectFeedback() async throws -> WaylandDmabufFeedback {
        let dmabuf = try unsafe require(dmabuf, "zwp_linux_dmabuf_v1")
        guard let proxy = unsafe zwp_linux_dmabuf_v1_get_default_feedback(
            dmabuf)
        else { throw SurfaceProbeError.waylandObjectCreationFailed("dma-buf feedback") }
        defer { unsafe zwp_linux_dmabuf_feedback_v1_destroy(proxy) }
        let collector = WaylandDmabufFeedbackCollector()
        unsafe ZwpLinuxDmabufFeedbackV1Client.addListener(
            proxy,
            owner: collector)
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
        guard let proxy = unsafe proxy else {
            throw SurfaceProbeError.missingGlobal(name)
        }
        return unsafe proxy
    }
}

private final class WmBaseHandler: XdgWmBaseEvents {
    func ping(
        _ proxy: WaylandBorrowedProxy<XdgWmBaseClient>, serial: UInt32
    ) {
        unsafe xdg_wm_base_pong(proxy.proxy, serial)
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
    private let surface: OpaquePointer
    private let xdgSurface: OpaquePointer
    private let toplevel: OpaquePointer
    private let syncSurface: OpaquePointer
    private let acquireTimeline: OpaquePointer
    private let presentation: OpaquePointer
    private let timeoutMilliseconds: Int32
    private var buffers: [UInt64: OpaquePointer] = unsafe [:]
    private var releaseTimelines: [UInt64: OpaquePointer] = unsafe [:]
    private var releaseWaiters: [UInt64: OpaquePointer] = unsafe [:]
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
        guard let surface = unsafe wl_compositor_create_surface(compositor),
              let xdgSurface = unsafe xdg_wm_base_get_xdg_surface(wmBase, surface),
              let toplevel = unsafe xdg_surface_get_toplevel(xdgSurface),
              let syncSurface = unsafe wp_linux_drm_syncobj_manager_v1_get_surface(
                syncobjManager, surface),
              descriptors.indices.contains(Int(allocation.acquireTimelineFDIndex)),
              let acquireTimeline = unsafe wp_linux_drm_syncobj_manager_v1_import_timeline(
                syncobjManager,
                descriptors[Int(allocation.acquireTimelineFDIndex)])
        else { throw SurfaceProbeError.waylandObjectCreationFailed("surface tree") }
        self.connection = connection
        self.reactor = reactor
        unsafe self.surface = surface
        unsafe self.xdgSurface = xdgSurface
        unsafe self.toplevel = toplevel
        unsafe self.syncSurface = syncSurface
        unsafe self.acquireTimeline = acquireTimeline
        unsafe self.presentation = presentation
        self.timeoutMilliseconds = timeoutMilliseconds
        unsafe XdgSurfaceClient.addListener(xdgSurface, owner: self)
        unsafe XdgToplevelClient.addListener(toplevel, owner: self)
        "android.dev.nucleus.graphics-probe".withCString {
            unsafe xdg_toplevel_set_app_id(toplevel, $0)
        }
        "Nucleus Android Graphics Probe".withCString {
            unsafe xdg_toplevel_set_title(toplevel, $0)
        }
        for description in allocation.buffers {
            guard descriptors.indices.contains(Int(description.releaseTimelineFDIndex)),
                  let releaseTimeline = unsafe wp_linux_drm_syncobj_manager_v1_import_timeline(
                    syncobjManager,
                    descriptors[Int(description.releaseTimelineFDIndex)]),
                  let releaseWaiter = allocation.device.renderNode.withCString({ path in
                    unsafe nucleus_android_syncobj_waiter_create(
                        path,
                        descriptors[Int(description.releaseTimelineFDIndex)])
                  })
            else {
                throw SurfaceProbeError.waylandObjectCreationFailed(
                    "per-buffer release timeline")
            }
            unsafe releaseTimelines[description.id] = releaseTimeline
            unsafe releaseWaiters[description.id] = releaseWaiter
            guard let params = unsafe zwp_linux_dmabuf_v1_create_params(dmabuf) else {
                throw SurfaceProbeError.waylandObjectCreationFailed("dma-buf params")
            }
            defer { unsafe zwp_linux_buffer_params_v1_destroy(params) }
            for (planeIndex, plane) in description.planes.enumerated() {
                guard descriptors.indices.contains(Int(plane.fdIndex)) else {
                    throw SurfaceProbeError.invalidBrokerReply
                }
                unsafe zwp_linux_buffer_params_v1_add(
                    params,
                    descriptors[Int(plane.fdIndex)],
                    UInt32(planeIndex),
                    plane.offset,
                    plane.stride,
                    UInt32(description.modifier >> 32),
                    UInt32(truncatingIfNeeded: description.modifier))
            }
            guard let buffer = unsafe zwp_linux_buffer_params_v1_create_immed(
                params,
                Int32(description.width),
                Int32(description.height),
                description.format,
                0)
            else { throw SurfaceProbeError.waylandObjectCreationFailed("wl_buffer") }
            unsafe buffers[description.id] = buffer
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "wayland.buffer-import",
                bufferID: description.id))
        }
        lifecycleEvents.append(SurfaceProbeLifecycleEvent(
            stage: "wayland.configure-commit"))
        unsafe wl_surface_commit(surface)
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
        guard unsafe !buffers.isEmpty else {
            throw SurfaceProbeError.invalidBrokerReply
        }
        guard frames > 0 else { return }
        let ordered = unsafe buffers.keys.sorted()
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
                  let buffer = unsafe buffers[bufferID],
                  let releaseTimeline = unsafe releaseTimelines[bufferID]
            else { throw brokerError(packet.envelope) }
            lifecycleEvents.append(SurfaceProbeLifecycleEvent(
                stage: "broker.guest-submission-accepted",
                bufferID: bufferID,
                frameNumber: frame,
                acquirePoint: render.acquirePoint,
                releasePoint: render.releasePoint))
            unsafe wp_linux_drm_syncobj_surface_v1_set_acquire_point(
                syncSurface,
                acquireTimeline,
                UInt32(render.acquirePoint >> 32),
                UInt32(truncatingIfNeeded: render.acquirePoint))
            unsafe wp_linux_drm_syncobj_surface_v1_set_release_point(
                syncSurface,
                releaseTimeline,
                UInt32(render.releasePoint >> 32),
                UInt32(truncatingIfNeeded: render.releasePoint))
            unsafe wl_surface_attach(surface, buffer, 0, 0)
            unsafe wl_surface_damage_buffer(
                surface,
                0,
                0,
                Int32.max,
                Int32.max)
            if let feedback = unsafe wp_presentation_feedback(
                presentation,
                surface)
            {
                unsafe WpPresentationFeedbackClient.addListener(
                    feedback,
                    owner: self)
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
            unsafe wl_surface_commit(surface)
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
        unsafe xdg_surface_ack_configure(proxy.proxy, serial)
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
        if var event = presentationFrames.removeValue(
            forKey: unsafe UInt(bitPattern: proxy.proxy)
        ) {
            event.stage = "wayland.presented"
            lifecycleEvents.append(event)
        }
        unsafe wp_presentation_feedback_destroy(proxy.proxy)
    }

    func discarded(
        _ proxy: WaylandBorrowedProxy<WpPresentationFeedbackClient>
    ) {
        discarded &+= 1
        if var event = presentationFrames.removeValue(
            forKey: unsafe UInt(bitPattern: proxy.proxy)
        ) {
            event.stage = "wayland.discarded"
            lifecycleEvents.append(event)
        }
        unsafe wp_presentation_feedback_destroy(proxy.proxy)
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
        for feedback in presentationFrames.keys {
            if let proxy = unsafe OpaquePointer(bitPattern: feedback) {
                unsafe wp_presentation_feedback_destroy(proxy)
            }
        }
        presentationFrames.removeAll()
        for unsafe buffer in unsafe buffers.values {
            unsafe wl_buffer_destroy(buffer)
        }
        for unsafe timeline in unsafe releaseTimelines.values {
            unsafe wp_linux_drm_syncobj_timeline_v1_destroy(timeline)
        }
        for unsafe waiter in unsafe releaseWaiters.values {
            unsafe nucleus_android_syncobj_waiter_destroy(waiter)
        }
        unsafe wp_linux_drm_syncobj_timeline_v1_destroy(acquireTimeline)
        unsafe wp_linux_drm_syncobj_surface_v1_destroy(syncSurface)
        unsafe xdg_toplevel_destroy(toplevel)
        unsafe xdg_surface_destroy(xdgSurface)
        unsafe wl_surface_destroy(surface)
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

private func brokerError(_ envelope: BrokerEnvelope) -> Error {
    if let failure = envelope.failure { return SurfaceProbeError.brokerFailure(failure) }
    return SurfaceProbeError.invalidBrokerReply
}
