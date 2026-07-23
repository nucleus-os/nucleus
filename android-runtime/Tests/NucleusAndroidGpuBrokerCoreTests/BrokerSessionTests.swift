import Glibc
import Testing
import NucleusAndroidGraphicsContract
import NucleusAndroidGraphicsPlatform
@testable import NucleusAndroidGpuBrokerCore
import NucleusAndroidIPC

@Test func brokerRejectsProtocolRequestsBeforeHello() throws {
    let (client, server) = try BrokerPacketConnection.socketPair()
    let session = BrokerSession(connection: server)
    try client.send(BrokerEnvelope(messageID: 1, kind: .diagnose))
    try session.handleNextPacket()
    let reply = try client.receive()
    #expect(reply.envelope.kind == .failure)
    #expect(reply.envelope.failure?.code == "invalid_state_transition")
}

@Test func brokerLoopbackAllocatesTheExactDmabufRingAndRenders() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let probe = try AndroidGraphicsDevice(candidate: candidate)
    let pair = try #require(probe.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .first(where: probe.supports))
    let feedback = WaylandDmabufFeedback(
        mainDevice: candidate.renderDevice,
        tranches: [
            WaylandDmabufTranche(
                targetDevice: candidate.renderDevice,
                scanout: false,
                formats: [pair])
        ])

    let (client, server) = try BrokerPacketConnection.socketPair()
    let session = BrokerSession(connection: server)
    try client.send(BrokerEnvelope(messageID: 1, kind: .hello))
    try session.handleNextPacket()
    #expect(try client.receive().envelope.kind == .helloReply)

    try client.send(BrokerEnvelope(
        messageID: 2,
        kind: .allocate,
        allocationRequest: BufferAllocationRequest(
            width: 64,
            height: 64,
            feedback: feedback)))
    try session.handleNextPacket()
    let allocationPacket = try client.receive()
    #expect(allocationPacket.envelope.kind == .allocationReply)
    #expect(allocationPacket.envelope.allocationReply?.buffers.count == 3)
    #expect(allocationPacket.envelope.allocationReply?.device.renderNode == candidate.renderNode)
    #expect(allocationPacket.descriptorCount == 7)
    let descriptors = allocationPacket.takeDescriptors()
    defer { for descriptor in descriptors { _ = close(descriptor) } }

    try client.send(BrokerEnvelope(
        messageID: 3,
        kind: .render,
        renderRequest: RenderRequest(bufferID: 1, frameNumber: 1)))
    try session.handleNextPacket()
    let renderPacket = try client.receive()
    #expect(renderPacket.envelope.renderReply?.acquirePoint == 1)
    #expect(renderPacket.envelope.renderReply?.releasePoint == 2)
}

@Test func brokerRejectsOutOfOrderFramesBeforeSubmittingGpuWork() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let probe = try AndroidGraphicsDevice(candidate: candidate)
    let pair = try #require(probe.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .first(where: probe.supports))
    let feedback = WaylandDmabufFeedback(
        mainDevice: candidate.renderDevice,
        tranches: [
            WaylandDmabufTranche(
                targetDevice: candidate.renderDevice,
                scanout: false,
                formats: [pair])
        ])
    let (client, server) = try BrokerPacketConnection.socketPair()
    let session = BrokerSession(connection: server)
    try client.send(BrokerEnvelope(messageID: 1, kind: .hello))
    try session.handleNextPacket()
    _ = try client.receive()
    try client.send(BrokerEnvelope(
        messageID: 2,
        kind: .allocate,
        allocationRequest: BufferAllocationRequest(width: 32, height: 32, feedback: feedback)))
    try session.handleNextPacket()
    let allocation = try client.receive()
    let descriptors = allocation.takeDescriptors()
    defer { for descriptor in descriptors { _ = close(descriptor) } }
    try client.send(BrokerEnvelope(
        messageID: 3,
        kind: .render,
        renderRequest: RenderRequest(bufferID: 1, frameNumber: 2)))
    try session.handleNextPacket()
    let failure = try client.receive()
    #expect(failure.envelope.failure?.code == "invalid_frame_sequence")
}
