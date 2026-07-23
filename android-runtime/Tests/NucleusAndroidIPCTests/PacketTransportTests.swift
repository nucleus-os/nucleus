import Glibc
import Testing
import NucleusAndroidGraphicsContract
@testable import NucleusAndroidIPC

@Test func seqpacketTransportPreservesEnvelopeAndDescriptorOrdering() throws {
    let (sender, receiver) = try BrokerPacketConnection.socketPair()
    let descriptor = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { _ = close(descriptor) } }
    let sent = BrokerEnvelope(
        messageID: 91,
        kind: .helloReply,
        descriptorSlots: [
            GraphicsFileDescriptorSlot(index: 0, role: .acquireTimeline)
        ])

    try sender.send(sent, descriptors: [descriptor])
    let packet = try receiver.receive()
    #expect(packet.envelope == sent)
    #expect(packet.descriptorCount == 1)
    let receivedDescriptors = packet.takeDescriptors()
    defer { for received in receivedDescriptors { _ = close(received) } }
    #expect(receivedDescriptors[0] != descriptor)
    #expect(fcntl(receivedDescriptors[0], F_GETFD) & FD_CLOEXEC != 0)
}

@Test func seqpacketPeerCredentialsIdentifyTheCurrentUser() throws {
    let (first, second) = try BrokerPacketConnection.socketPair()
    let expected = UInt32(geteuid())
    try first.requirePeer(userID: expected)
    try second.requirePeer(userID: expected)
    #expect(first.peerCredentials?.userID == expected)
}

@Test func sendingDescriptorsWithoutDeclaredSlotsFailsClosed() throws {
    let (sender, _) = try BrokerPacketConnection.socketPair()
    let descriptor = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { _ = close(descriptor) } }
    let envelope = BrokerEnvelope(messageID: 1, kind: .hello)
    #expect(throws: GraphicsContractValidationError.descriptorCountMismatch(expected: 0, actual: 1)) {
        try sender.send(envelope, descriptors: [descriptor])
    }
}
