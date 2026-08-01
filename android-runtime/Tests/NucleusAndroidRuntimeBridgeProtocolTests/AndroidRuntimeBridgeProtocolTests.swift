import Foundation
import Glibc
internal import NucleusAndroidRuntimeBridgeProtocol
import NucleusAndroidRuntimeCore
import NucleusIPCTransport
import Testing

private actor BridgeEventRecorder {
    private(set) var events: [AndroidRuntimeBridgeEvent] = []

    func append(_ event: AndroidRuntimeBridgeEvent) {
        events.append(event)
    }
}

private actor InputEventRecorder {
    private(set) var event: AndroidInputEvent?

    func record(_ event: AndroidInputEvent) {
        self.event = event
    }
}

@Test
func inputProtocolAcceptsNativeDeviceEventsAndRejectsMixedShapes()
    throws
{
    let key = try AndroidInputEvent(
        displayID: 0,
        eventTimeNanoseconds: 9,
        keyCode: 30,
        pressed: true,
        action: .key)
    #expect(key.keyCode == 30)
    let scroll = try AndroidInputEvent(
        displayID: 0,
        eventTimeNanoseconds: 10,
        x: 4,
        y: 5,
        scrollY: -0.25,
        action: .pointerScroll)
    #expect(scroll.scrollY == -0.25)
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidInputEvent(
            displayID: 0,
            eventTimeNanoseconds: 11,
            x: 4,
            y: 5,
            keyCode: 30,
            pressed: true,
            action: .key)
    }
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidInputEvent(
            displayID: 0,
            eventTimeNanoseconds: 12,
            button: 0x110,
            pressed: true,
            action: .pointerButton)
    }
}

@Test
func bridgePublishesOneUnlockedSnapshotForTheNegotiatedGeneration()
    async throws
{
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
            kind: .inputState,
            generation: generation,
            inputReady: true),
        over: connection)
    let pointer = try AndroidInputEvent(
        displayID: 0,
        eventTimeNanoseconds: 42_000_000,
        x: 320,
        y: 240,
        button: 0x110,
        pressed: true,
        action: .pointerButton)
    try server.send(pointer)
    let pointerCommand = try receive(from: connection)
    #expect(pointerCommand.kind == .inputEvent)
    #expect(pointerCommand.generation == generation)
    #expect(pointerCommand.inputEvent == pointer)

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
    let activities = [
        AndroidRuntimeBridgeActivity(
            packageName: "org.example",
            activityName: "org.example.MainActivity",
            label: "Example"),
    ]
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .replaceActivities,
            generation: generation,
            userUnlocked: true,
            userSerial: 42,
            activities: activities),
        over: connection)
    let cursor = try AndroidCursorShapeUpdate(
        displayID: 0,
        pointerIconType: 1_008)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .cursorShape,
            generation: generation,
            cursorShape: cursor),
        over: connection)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.events.count < 5,
        ContinuousClock.now < deadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(await recorder.events == [
        .connected(generation: generation),
        .inputReady(generation: generation),
        .userUnlocked(generation: generation, userSerial: 42),
        .activitiesReplaced(
            generation: generation,
            userSerial: 42,
            activities: activities),
        .cursorShapeChanged(
            generation: generation,
            update: cursor),
    ])
}

@Test
func bridgeKeepsRuntimeStateAvailableWhenNativeInputInitializationFails()
    async throws
{
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "nucleus-bridge-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("broker.sock")
    let generation = "runtime-generation-input-failure"
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
    #expect(try receive(from: connection).generation == generation)
    let failure = "native virtual input: Permission denied"
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .inputState,
            generation: generation,
            inputReady: false,
            inputError: failure),
        over: connection)

    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .runtimeState,
            generation: generation,
            userUnlocked: false,
            userSerial: 0),
        over: connection)
    for _ in 0..<100 {
        if await recorder.events.count == 2 {
            break
        }
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(await recorder.events == [
        .connected(generation: generation),
        .inputFailed(generation: generation, error: failure),
    ])
}

@Test
func displayInputForwardsOnlyValidatedInputPackets() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "nucleus-display-input-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("input.sock")
    let server = try AndroidDisplayInteractionServer(
        socketPath: socket,
        expectedUserID: getuid())
    let initialCursor = try AndroidCursorShapeUpdate(
        displayID: 0,
        pointerIconType: 1_000)
    try server.send(initialCursor)
    let expected = try AndroidInputEvent(
        displayID: 0,
        eventTimeNanoseconds: 7_000_000,
        x: 100,
        y: 80,
        action: .pointerMotion)
    let recorder = InputEventRecorder()
    let service = Task {
        try await server.run { event in
            if case .input(let input) = event {
                Task {
                    await recorder.record(input)
                }
            }
        }
    }
    defer { service.cancel() }
    let client = try AndroidDisplayInteractionClient(
        socketPath: socket.path)
    #expect(try client.receiveCursorShape() == initialCursor)
    try client.send(expected)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.event == nil,
        ContinuousClock.now < deadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(await recorder.event == expected)
    let cursor = try AndroidCursorShapeUpdate(
        displayID: 0,
        pointerIconType: 1_002)
    try server.send(cursor)
    #expect(try client.receiveCursorShape() == cursor)
}

@Test
func bridgeAcceptsAReplacementConnectionInTheSameBrokerGeneration()
    async throws
{
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "nucleus-bridge-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("broker.sock")
    let generation = "runtime-generation-2"
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

    var first: PacketConnection? = try PacketConnection.connect(
        path: socket.path)
    try send(
        AndroidRuntimeBridgeEnvelope(kind: .bridgeHello),
        over: first!)
    #expect(try receive(from: first!).generation == generation)
    first = nil

    let disconnectedDeadline = ContinuousClock.now.advanced(
        by: .seconds(2))
    while await recorder.events.count < 2,
        ContinuousClock.now < disconnectedDeadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }

    let replacement = try PacketConnection.connect(path: socket.path)
    try send(
        AndroidRuntimeBridgeEnvelope(kind: .bridgeHello),
        over: replacement)
    #expect(try receive(from: replacement).generation == generation)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .inputState,
            generation: generation,
            inputReady: true),
        over: replacement)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .runtimeState,
            generation: generation,
            userUnlocked: true,
            userSerial: 9),
        over: replacement)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .replaceActivities,
            generation: generation,
            userUnlocked: true,
            userSerial: 9,
            activities: []),
        over: replacement)

    let snapshotDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.events.count < 6,
        ContinuousClock.now < snapshotDeadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(await recorder.events == [
        .connected(generation: generation),
        .disconnected(generation: generation),
        .connected(generation: generation),
        .inputReady(generation: generation),
        .userUnlocked(generation: generation, userSerial: 9),
        .activitiesReplaced(
            generation: generation,
            userSerial: 9,
            activities: []),
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
