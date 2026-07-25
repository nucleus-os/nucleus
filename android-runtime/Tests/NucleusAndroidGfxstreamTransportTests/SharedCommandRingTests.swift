import Foundation
import Glibc
import Testing
@testable import NucleusAndroidGfxstreamTransport

private func pollReadable(
    _ descriptor: Int32,
    timeout: Int32 = 1_000
) -> Bool {
    var event = pollfd(
        fd: descriptor,
        events: Int16(POLLIN),
        revents: 0)
    return unsafe poll(&event, 1, timeout) == 1
        && (event.revents & Int16(POLLIN)) != 0
}

@Test func sharedRingPreservesPacketBoundariesAcrossDirectionalMappings()
    throws
{
    let mapping = try SharedCommandRingMapping(
        slotCount: 4,
        slotSize: 256)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()
    let first = Data([0, 1, 2, 3])
    let second = Data("gfxstream-command".utf8)
    try producer.write(first)
    try producer.write(second)
    #expect(try consumer.read() == first)
    #expect(try consumer.read() == second)
    #expect(throws: GfxstreamTransportError.empty) {
        try consumer.read()
    }
}

@Test func sharedRingPreservesZeroAndMaximumSizePackets() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 128)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()
    let maximum = Data(
        (0..<(128 - MemoryLayout<UInt32>.size)).map {
            UInt8(truncatingIfNeeded: $0)
        })
    try producer.write(Data())
    try producer.write(maximum)
    #expect(try consumer.read().isEmpty)
    #expect(try consumer.read() == maximum)
}

@Test func dataNotificationRequiresAnArmedConsumerAndCoalescesBursts()
    throws
{
    let (guest, host) = try GfxstreamDuplexTransport.makePair(
        slotCount: 4,
        slotSize: 128)
    try guest.commandProducer.write(Data([8]))
    #expect(
        !pollReadable(
            host.commandConsumer.dataNotificationFileDescriptor,
            timeout: 0))
    #expect(try host.commandConsumer.read() == Data([8]))
    #expect(throws: GfxstreamTransportError.empty) {
        try host.commandConsumer.read()
    }
    #expect(try host.commandConsumer.prepareDataWait() == .armed)

    try guest.commandProducer.write(Data([9]))
    try guest.commandProducer.write(Data([10]))
    #expect(
        pollReadable(
            host.commandConsumer.dataNotificationFileDescriptor))
    try host.commandConsumer.drainDataNotification()
    #expect(try host.commandConsumer.read() == Data([9]))
    #expect(try host.commandConsumer.read() == Data([10]))

    let diagnostic = try host.commandConsumer.diagnostic
    #expect(diagnostic.dataNotificationWriteCount == 1)
    #expect(diagnostic.dataNotificationDrainCount == 1)
}

@Test func spaceNotificationRequiresAnArmedProducer() throws {
    let (guest, host) = try GfxstreamDuplexTransport.makePair(
        slotCount: 2,
        slotSize: 128)
    try guest.commandProducer.write(Data([1]))
    try guest.commandProducer.write(Data([2]))
    #expect(try host.commandConsumer.read() == Data([1]))
    #expect(
        !pollReadable(
            guest.commandProducer.spaceNotificationFileDescriptor,
            timeout: 0))
    try guest.commandProducer.write(Data([3]))
    #expect(throws: GfxstreamTransportError.full) {
        try guest.commandProducer.write(Data([4]))
    }
    #expect(try guest.commandProducer.prepareSpaceWait() == .armed)

    #expect(try host.commandConsumer.read() == Data([2]))
    #expect(
        pollReadable(
            guest.commandProducer.spaceNotificationFileDescriptor))
    try guest.commandProducer.drainSpaceNotification()
    try guest.commandProducer.write(Data([4]))

    let diagnostic = try guest.commandProducer.diagnostic
    #expect(diagnostic.spaceNotificationWriteCount == 1)
    #expect(diagnostic.spaceNotificationDrainCount == 1)
}

@Test func waitPreparationRechecksStateAfterArming() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 64)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()

    try producer.write(Data([1]))
    #expect(try consumer.prepareDataWait() == .ready)
    #expect(try consumer.read() == Data([1]))

    try producer.write(Data([2]))
    try producer.write(Data([3]))
    #expect(try consumer.read() == Data([2]))
    #expect(try producer.prepareSpaceWait() == .ready)
}

@Test func closeWakesAnArmedDataWait() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 64)
    let consumer = try mapping.makeConsumer()
    #expect(try consumer.prepareDataWait() == .armed)
    try mapping.close()
    #expect(pollReadable(consumer.dataNotificationFileDescriptor))
    try consumer.drainDataNotification()
    #expect(throws: GfxstreamTransportError.closed) {
        try consumer.read()
    }
}

@Test func closeWakesAnArmedSpaceWait() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 64)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()
    try producer.write(Data([1]))
    try producer.write(Data([2]))
    #expect(try producer.prepareSpaceWait() == .armed)
    try consumer.close()
    #expect(pollReadable(producer.spaceNotificationFileDescriptor))
    try producer.drainSpaceNotification()
    #expect(throws: GfxstreamTransportError.closed) {
        try producer.write(Data([3]))
    }
}

@Test func duplicateDirectionalAttachmentsAreRejected() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 64)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()
    _ = producer
    _ = consumer
    #expect(throws: GfxstreamTransportError.duplicateEndpointRole) {
        try mapping.makeProducer()
    }
    #expect(throws: GfxstreamTransportError.duplicateEndpointRole) {
        try mapping.makeConsumer()
    }
}

@Test func directionalEndpointsSerializeCrossTaskUse() async throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 32,
        slotSize: 64)
    let producer = try mapping.makeProducer()
    let consumer = try mapping.makeConsumer()
    let producerCount = 4
    let packetsPerProducer = 250
    let expectedCount = producerCount * packetsPerProducer

    async let received: Set<UInt64> = {
        var values: Set<UInt64> = []
        while values.count < expectedCount {
            do {
                let packet = try consumer.read()
                guard packet.count == MemoryLayout<UInt64>.size else {
                    throw GfxstreamTransportError.systemCall(
                        errno: EPROTO)
                }
                let value = unsafe packet.withUnsafeBytes {
                    unsafe $0.loadUnaligned(as: UInt64.self)
                }
                values.insert(value)
            } catch GfxstreamTransportError.empty {
                await Task.yield()
            }
        }
        return values
    }()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for producerID in 0..<producerCount {
            group.addTask {
                for sequence in 0..<packetsPerProducer {
                    var value =
                        UInt64(producerID * packetsPerProducer + sequence)
                    let packet = withUnsafeBytes(of: &value) {
                        unsafe Data($0)
                    }
                    while true {
                        do {
                            try producer.write(packet)
                            break
                        } catch GfxstreamTransportError.full {
                            await Task.yield()
                        }
                    }
                }
            }
        }
        try await group.waitForAll()
    }
    let values = try await received
    #expect(values.count == expectedCount)
    #expect(values == Set(0..<UInt64(expectedCount)))
}

@Test func sharedRingFailsClosedOnOversizedPackets() throws {
    let mapping = try SharedCommandRingMapping(
        slotCount: 2,
        slotSize: 64)
    let producer = try mapping.makeProducer()
    #expect(throws: GfxstreamTransportError.packetTooLarge) {
        try producer.write(Data(repeating: 0, count: 61))
    }
}

@Test func duplexTransportKeepsDirectionsIndependent() throws {
    let (guest, host) = try GfxstreamDuplexTransport.makePair(
        slotCount: 4,
        slotSize: 256)
    try guest.commandProducer.write(Data("vkQueueSubmit".utf8))
    #expect(
        try host.commandConsumer.read() ==
            Data("vkQueueSubmit".utf8))
    try host.responseProducer.write(Data("VK_SUCCESS".utf8))
    #expect(
        try guest.responseConsumer.read() ==
            Data("VK_SUCCESS".utf8))
}
