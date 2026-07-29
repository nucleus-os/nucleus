import Foundation
import Glibc
import NucleusAndroidRuntimeBridgeProtocol
import NucleusAndroidRuntimeCore
import NucleusIPCTransport
import Testing

private actor BridgeEventRecorder {
    private(set) var events: [AndroidRuntimeBridgeEvent] = []

    func append(_ event: AndroidRuntimeBridgeEvent) {
        events.append(event)
    }
}

@Test
func bridgePublishesUnlockOnceForTheNegotiatedGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "nucleus-bridge-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("broker.sock")
    let generation = "runtime-generation-1"
    let server = try AndroidRuntimeBridgeServer(
        socketPath: socket,
        expectedUserID: getuid(),
        generation: generation)
    let recorder = BridgeEventRecorder()
    let service = Task {
        try await server.run {
            await recorder.append($0)
        }
    }
    defer { service.cancel() }

    let connection = try PacketConnection.connect(path: socket.path)
    try send(
        AndroidRuntimeBridgeEnvelope(kind: .bridgeHello),
        over: connection)
    let brokerHello = try receive(from: connection)
    #expect(brokerHello.kind == .brokerHello)
    #expect(brokerHello.generation == generation)

    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .runtimeState,
            generation: generation,
            userUnlocked: false,
            userSerial: 0),
        over: connection)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .runtimeState,
            generation: generation,
            userUnlocked: true,
            userSerial: 42),
        over: connection)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.events.count < 2,
        ContinuousClock.now < deadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(await recorder.events == [
        .connected(generation: generation),
        .userUnlocked(generation: generation, userSerial: 42),
    ])
}

private func send(
    _ envelope: AndroidRuntimeBridgeEnvelope,
    over connection: PacketConnection
) throws {
    try connection.send(try JSONEncoder().encode(envelope))
}

private func receive(
    from connection: PacketConnection
) throws -> AndroidRuntimeBridgeEnvelope {
    let packet = try connection.receive(
        maximumBytes: AndroidRuntimeBridgeProtocol.maximumPacketBytes,
        maximumDescriptors: 0)
    return try JSONDecoder().decode(
        AndroidRuntimeBridgeEnvelope.self,
        from: Data(packet.bytes))
}
