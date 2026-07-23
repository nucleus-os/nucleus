import Glibc
import NucleusAndroidGraphicsContract
import NucleusAndroidGraphicsPlatform
import NucleusAndroidIPC

public protocol BrokerRenderBackend: AnyObject {
    func prepare(ring: AndroidBufferRing) throws
    func render(
        buffer: AndroidGraphicsBuffer,
        frameNumber: UInt64,
        acquireTimeline: AndroidSyncobjTimeline,
        acquirePoint: UInt64,
        releaseTimeline: AndroidSyncobjTimeline?,
        releasePoint: UInt64
    ) throws
}

public final class DirectVulkanBrokerRenderBackend: BrokerRenderBackend {
    public init() {}

    public func prepare(ring: AndroidBufferRing) throws {}

    public func render(
        buffer: AndroidGraphicsBuffer,
        frameNumber: UInt64,
        acquireTimeline: AndroidSyncobjTimeline,
        acquirePoint: UInt64,
        releaseTimeline: AndroidSyncobjTimeline?,
        releasePoint: UInt64
    ) throws {
        try buffer.render(
            frameNumber: frameNumber,
            acquireTimeline: acquireTimeline,
            acquirePoint: acquirePoint,
            releaseTimeline: releaseTimeline,
            releasePoint: releasePoint)
    }
}

public final class BrokerSession {
    private enum State {
        case awaitingHello
        case ready
        case allocated(AndroidBufferRing)
    }

    private let connection: BrokerPacketConnection
    private let renderBackend: any BrokerRenderBackend
    private var state: State = .awaitingHello
    private var nextFrameNumber: UInt64 = 1
    private var previousReleasePoint: [UInt64: UInt64] = [:]

    public init(
        connection: BrokerPacketConnection,
        renderBackend: any BrokerRenderBackend =
            DirectVulkanBrokerRenderBackend()
    ) {
        self.connection = connection
        self.renderBackend = renderBackend
    }

    public func run() throws {
        while true { try handleNextPacket() }
    }

    public func handleNextPacket() throws {
        let packet = try connection.receive()
        let request = packet.envelope
        let descriptors = packet.takeDescriptors()
        defer { for descriptor in descriptors { _ = close(descriptor) } }
        guard descriptors.isEmpty else {
            try sendFailure(
                for: request.messageID,
                code: "unexpected_descriptors",
                message: "broker requests do not accept file descriptors")
            return
        }
        do {
            try handle(request)
        } catch let failure as GraphicsFailure {
            try sendFailure(
                for: request.messageID,
                code: failure.code,
                message: failure.message)
        } catch {
            try sendFailure(
                for: request.messageID,
                code: "broker_failure",
                message: String(describing: error))
        }
    }

    private func handle(_ request: BrokerEnvelope) throws {
        switch (state, request.kind) {
        case (.awaitingHello, .hello):
            try connection.send(BrokerEnvelope(
                messageID: request.messageID,
                kind: .helloReply))
            state = .ready
        case (.ready, .allocate):
            guard let allocation = request.allocationRequest else {
                throw GraphicsFailure(
                    code: "invalid_allocation",
                    message: "allocation payload is missing")
            }
            let device = try AndroidGraphicsDevice(
                compositorDevice: allocation.feedback.mainDevice)
            guard device.diagnostic.hardwareDriver else {
                throw GraphicsFailure(
                    code: "software_driver_rejected",
                    message: "the compositor-selected adapter resolved to a software Vulkan driver")
            }
            let ring = try device.allocate(allocation)
            try renderBackend.prepare(ring: ring)
            try sendAllocationReply(messageID: request.messageID, ring: ring)
            state = .allocated(ring)
        case let (.allocated(ring), .render):
            guard let render = request.renderRequest,
                  let buffer = ring.buffers.first(where: { $0.id == render.bufferID })
            else {
                throw GraphicsFailure(
                    code: "unknown_buffer",
                    message: "render request names an unallocated buffer")
            }
            let acquirePoint = render.frameNumber &* 2 &- 1
            let releasePoint = acquirePoint &+ 1
            guard let releaseTimeline = ring.releaseTimeline(for: buffer.id) else {
                throw GraphicsFailure(
                    code: "missing_release_timeline",
                    message: "allocated buffer has no release timeline")
            }
            guard render.frameNumber == nextFrameNumber,
                  render.frameNumber <= UInt64.max / 2,
                  render.releasePoint == previousReleasePoint[buffer.id]
            else {
                throw GraphicsFailure(
                    code: "invalid_frame_sequence",
                    message: "frames and per-buffer release points must advance in broker order")
            }
            try renderBackend.render(
                buffer: buffer,
                frameNumber: render.frameNumber,
                acquireTimeline: ring.acquireTimeline,
                acquirePoint: acquirePoint,
                releaseTimeline: render.releasePoint == nil ? nil : releaseTimeline,
                releasePoint: render.releasePoint ?? 0)
            try connection.send(BrokerEnvelope(
                messageID: request.messageID,
                kind: .renderReply,
                renderReply: RenderReply(
                    bufferID: buffer.id,
                    frameNumber: render.frameNumber,
                    acquirePoint: acquirePoint,
                    releasePoint: releasePoint)))
            previousReleasePoint[buffer.id] = releasePoint
            nextFrameNumber &+= 1
        case (.ready, .diagnose):
            throw GraphicsFailure(
                code: "device_not_selected",
                message: "device diagnostics require dma-buf feedback in an allocation request")
        default:
            throw GraphicsFailure(
                code: "invalid_state_transition",
                message: "\(request.kind.rawValue) is not valid in the current broker state")
        }
    }

    private func sendAllocationReply(messageID: UInt64, ring: AndroidBufferRing) throws {
        var descriptors: [Int32] = []
        var slots: [GraphicsFileDescriptorSlot] = []
        var brokerBuffers: [BrokerBuffer] = []
        do {
            for buffer in ring.buffers {
                var planes: [DmabufPlane] = []
                for planeIndex in 0..<buffer.planeCount {
                    let exported = try buffer.exportPlane(at: planeIndex)
                    let offset = exported.offset
                    let stride = exported.stride
                    let descriptor = exported.takeFileDescriptor()
                    let index = UInt8(descriptors.count)
                    descriptors.append(descriptor)
                    slots.append(GraphicsFileDescriptorSlot(
                        index: index,
                        role: .dmaBufPlane,
                        bufferID: buffer.id,
                        planeIndex: UInt8(planeIndex)))
                    planes.append(DmabufPlane(
                        fdIndex: index,
                        offset: offset,
                        stride: stride))
                }
                guard let releaseTimeline = ring.releaseTimeline(for: buffer.id) else {
                    throw GraphicsFailure(
                        code: "missing_release_timeline",
                        message: "allocated buffer has no release timeline")
                }
                let releaseIndex = UInt8(descriptors.count)
                descriptors.append(try releaseTimeline.exportFileDescriptor())
                slots.append(GraphicsFileDescriptorSlot(
                    index: releaseIndex,
                    role: .releaseTimeline,
                    bufferID: buffer.id))
                brokerBuffers.append(BrokerBuffer(
                    id: buffer.id,
                    width: buffer.width,
                    height: buffer.height,
                    format: buffer.formatModifier.format,
                    modifier: buffer.formatModifier.modifier,
                    planes: planes,
                    releaseTimelineFDIndex: releaseIndex))
            }
            let acquireIndex = UInt8(descriptors.count)
            descriptors.append(try ring.acquireTimeline.exportFileDescriptor())
            slots.append(GraphicsFileDescriptorSlot(
                index: acquireIndex,
                role: .acquireTimeline))
            try connection.send(
                BrokerEnvelope(
                    messageID: messageID,
                    kind: .allocationReply,
                    allocationReply: BufferAllocationReply(
                        device: ring.diagnostic,
                        buffers: brokerBuffers,
                        acquireTimelineFDIndex: acquireIndex),
                    descriptorSlots: slots),
                descriptors: descriptors)
        } catch {
            for descriptor in descriptors { _ = close(descriptor) }
            throw error
        }
        for descriptor in descriptors { _ = close(descriptor) }
    }

    private func sendFailure(
        for messageID: UInt64,
        code: String,
        message: String
    ) throws {
        try connection.send(BrokerEnvelope(
            messageID: messageID,
            kind: .failure,
            failure: GraphicsFailure(code: code, message: message)))
    }
}
