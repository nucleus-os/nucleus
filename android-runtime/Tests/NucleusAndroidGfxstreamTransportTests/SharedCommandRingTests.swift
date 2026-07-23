import Foundation
import Glibc
import Testing
@testable import NucleusAndroidGfxstreamTransport

@Test func sharedRingPreservesPacketBoundariesAcrossMappings() throws {
    let owner = try SharedCommandRing(slotCount: 4, slotSize: 256)
    let descriptors = try owner.exportFileDescriptors()
    let peer = try SharedCommandRing(
        owningMemoryFD: descriptors.memory,
        dataNotificationFD: descriptors.dataNotification,
        spaceNotificationFD: descriptors.spaceNotification)
    let first = Data([0, 1, 2, 3])
    let second = Data("gfxstream-command".utf8)
    try owner.write(first)
    try owner.write(second)
    #expect(try peer.read() == first)
    #expect(try peer.read() == second)
    #expect(throws: GfxstreamTransportError.empty) { try peer.read() }
}

@Test func sharedRingNotificationIsPollableAndDrainable() throws {
    let (guest, host) = try GfxstreamDuplexEndpoint.makePair(slotCount: 2, slotSize: 128)
    try guest.commands.write(Data([9]))
    var descriptor = pollfd(
        fd: host.commands.dataNotificationFileDescriptor,
        events: Int16(POLLIN),
        revents: 0)
    #expect(poll(&descriptor, 1, 0) == 1)
    try host.commands.drainDataNotification()
    descriptor.revents = 0
    #expect(poll(&descriptor, 1, 0) == 0)
    #expect(try host.commands.read() == Data([9]))
}

@Test func sharedRingSignalsCapacityAfterConsumerReads() throws {
    let (guest, host) = try GfxstreamDuplexEndpoint.makePair(slotCount: 2, slotSize: 128)
    try guest.commands.write(Data([1]))
    try guest.commands.write(Data([2]))
    #expect(throws: GfxstreamTransportError.full) {
        try guest.commands.write(Data([3]))
    }

    #expect(try host.commands.read() == Data([1]))
    var descriptor = pollfd(
        fd: guest.commands.spaceNotificationFileDescriptor,
        events: Int16(POLLIN),
        revents: 0)
    #expect(poll(&descriptor, 1, 0) == 1)
    try guest.commands.drainSpaceNotification()
    descriptor.revents = 0
    #expect(poll(&descriptor, 1, 0) == 0)
    try guest.commands.write(Data([3]))
}

@Test func sharedRingFailsClosedOnBackpressureAndOversizedPackets() throws {
    let ring = try SharedCommandRing(slotCount: 2, slotSize: 64)
    try ring.write(Data([1]))
    try ring.write(Data([2]))
    #expect(throws: GfxstreamTransportError.full) { try ring.write(Data([3])) }
    #expect(throws: GfxstreamTransportError.packetTooLarge) {
        try ring.write(Data(repeating: 0, count: 61))
    }
}

@Test func duplexTransportKeepsCommandAndResponseDirectionsIndependent() throws {
    let (guest, host) = try GfxstreamDuplexEndpoint.makePair(slotCount: 4, slotSize: 256)
    try guest.commands.write(Data("vkQueueSubmit".utf8))
    #expect(try host.commands.read() == Data("vkQueueSubmit".utf8))
    try host.responses.write(Data("VK_SUCCESS".utf8))
    #expect(try guest.responses.read() == Data("VK_SUCCESS".utf8))
}
