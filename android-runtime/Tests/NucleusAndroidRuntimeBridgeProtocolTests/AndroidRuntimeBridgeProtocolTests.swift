import Foundation
import Glibc
import NucleusAndroidRuntimeCore
import NucleusIPCTransport
import Testing

@testable internal import NucleusAndroidRuntimeBridgeProtocol

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
func launchResultsDistinguishRequestedAndExistingPresentations() throws {
    let reused = try AndroidActivityLaunchResult(
        requestID: "request",
        requestedPresentationID: 7,
        presentationID: 3,
        displayID: 11,
        taskID: 19,
        outcome: .activatedExistingPresentation)

    #expect(reused.requestedPresentationID == 7)
    #expect(reused.presentationID == 3)
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidActivityLaunchResult(
            requestID: "request",
            requestedPresentationID: 7,
            presentationID: 7,
            displayID: nil,
            taskID: 19,
            outcome: .created)
    }
}

@Test
func inputProtocolAcceptsNativeDeviceEventsAndRejectsMixedShapes()
    throws
{
    let key = try AndroidInputEvent(
        presentationID: 0,
        configurationGeneration: 1,
        eventTimeNanoseconds: 9,
        keyCode: 30,
        pressed: true,
        action: .key)
    #expect(key.keyCode == 30)
    let scroll = try AndroidInputEvent(
        presentationID: 0,
        configurationGeneration: 1,
        eventTimeNanoseconds: 10,
        x: 4,
        y: 5,
        scrollY: -0.25,
        action: .pointerScroll)
    #expect(scroll.scrollY == -0.25)
    let focus = try AndroidInputEvent(
        presentationID: 7,
        configurationGeneration: 3,
        eventTimeNanoseconds: 10,
        focused: true,
        action: .keyboardFocus)
    #expect(focus.focused == true)
    let touch = try AndroidInputEvent(
        presentationID: 7,
        configurationGeneration: 3,
        eventTimeNanoseconds: 10,
        x: 40,
        y: 50,
        contactID: 2,
        action: .touchDown)
    #expect(touch.contactID == 2)
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidInputEvent(
            presentationID: 0,
            configurationGeneration: 1,
            eventTimeNanoseconds: 11,
            x: 4,
            y: 5,
            keyCode: 30,
            pressed: true,
            action: .key)
    }
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidInputEvent(
            presentationID: 0,
            configurationGeneration: 1,
            eventTimeNanoseconds: 12,
            button: 0x110,
            pressed: true,
            action: .pointerButton)
    }
    #expect(throws: AndroidRuntimeFailure.self) {
        try AndroidInputEvent(
            presentationID: 7,
            configurationGeneration: 0,
            eventTimeNanoseconds: 12,
            action: .touchCancel)
    }
    let configurationChanged = try AndroidInputEvent(
        presentationID: 7,
        configurationGeneration: 4,
        eventTimeNanoseconds: 13,
        action: .configurationChanged)
    #expect(configurationChanged.configurationGeneration == 4)
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
        presentationID: 0,
        configurationGeneration: 1,
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

    let launch = Task {
        await server.launch(
            presentationID: 7,
            packageName: "org.example",
            activityName: "org.example.MainActivity",
            activationToken: "activation-token")
    }
    let launchEnvelope = try receive(from: connection)
    let launchCommand = try #require(launchEnvelope.activityLaunch)
    #expect(launchEnvelope.kind == .launchActivity)
    #expect(launchCommand.presentationID == 7)
    #expect(launchCommand.packageName == "org.example")
    #expect(launchCommand.activationToken == "activation-token")
    let launchResult = try AndroidActivityLaunchResult(
        requestID: launchCommand.requestID,
        requestedPresentationID: launchCommand.presentationID,
        presentationID: launchCommand.presentationID,
        displayID: 3,
        taskID: 19,
        outcome: .created)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .launchResult,
            generation: generation,
            activityLaunchResult: launchResult),
        over: connection)
    #expect(await launch.value == launchResult)

    let taskState = try AndroidTaskState(
        presentationID: 7,
        displayID: 3,
        taskID: 19,
        packageName: "org.example",
        activityName: "org.example.MainActivity")
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .taskChanged,
            generation: generation,
            taskState: taskState),
        over: connection)
    let vanishedTask = try AndroidTaskVanished(
        presentationID: 7,
        taskID: 19)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .taskVanished,
            generation: generation,
            vanishedTask: vanishedTask),
        over: connection)

    let close = try AndroidPresentationCloseCommand(presentationID: 7)
    try server.close(presentationID: 7)
    let closeEnvelope = try receive(from: connection)
    #expect(closeEnvelope.kind == .closePresentation)
    #expect(closeEnvelope.presentationClose == close)

    let shellClipboard = try AndroidClipboardUpdate(
        source: .shell,
        generation: 3,
        text: "from shell")
    try server.setClipboard(shellClipboard)
    let clipboardCommand = try receive(from: connection)
    #expect(clipboardCommand.kind == .setClipboard)
    #expect(clipboardCommand.clipboardUpdate == shellClipboard)
    let androidClipboard = try AndroidClipboardUpdate(
        source: .android,
        generation: 8,
        text: "from Android")
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .clipboardChanged,
            generation: generation,
            clipboardUpdate: androidClipboard),
        over: connection)

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
    let notification = AndroidNotification(
        id: "notification-key",
        packageName: "org.example",
        applicationName: "Example",
        title: "Ready",
        body: "The operation completed.",
        iconDigest: nil,
        urgency: .normal,
        progress: AndroidNotificationProgress(value: 1, total: 2),
        hasDefaultAction: true,
        actions: [
            AndroidNotificationAction(id: "action:0", title: "Open")
        ])
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .replaceNotifications,
            generation: generation,
            userUnlocked: true,
            userSerial: 42,
            notifications: [notification]),
        over: connection)
    try server.dismissNotification("notification-key")
    let dismissEnvelope = try receive(from: connection)
    #expect(dismissEnvelope.kind == .dismissNotification)
    #expect(dismissEnvelope.notificationCommand?.notificationID == "notification-key")
    let notificationActivation = Task {
        await server.activateNotification(
            "notification-key",
            actionID: "action:0",
            activationToken: "token",
            presentationID: 9)
    }
    let activationEnvelope = try receive(from: connection)
    #expect(activationEnvelope.kind == .activateNotification)
    #expect(activationEnvelope.notificationCommand?.actionID == "action:0")
    #expect(activationEnvelope.notificationCommand?.activationToken == "token")
    #expect(activationEnvelope.notificationCommand?.presentationID == 9)
    let activationRequestID = try #require(
        activationEnvelope.notificationCommand?.requestID)
    let activationResult = try AndroidActivityLaunchResult(
        requestID: activationRequestID,
        requestedPresentationID: 9,
        presentationID: 9,
        displayID: 4,
        taskID: 20,
        outcome: .created)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .launchResult,
            generation: generation,
            activityLaunchResult: activationResult),
        over: connection)
    #expect(await notificationActivation.value == activationResult)
    let activities = [
        AndroidRuntimeBridgeActivity(
            packageName: "org.example",
            activityName: "org.example.MainActivity",
            label: "Example",
            categories: ["productivity"],
            iconDigest: String(repeating: "a", count: 64))
    ]
    let icon = AndroidRuntimeBridgeIconAsset(
        digest: String(repeating: "a", count: 64),
        bytes: Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00,
        ]))
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .iconAsset,
            generation: generation,
            userUnlocked: true,
            userSerial: 42,
            iconAsset: icon),
        over: connection)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .replaceActivities,
            generation: generation,
            userUnlocked: true,
            userSerial: 42,
            activities: activities),
        over: connection)
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .replacePackageActivities,
            generation: generation,
            userUnlocked: true,
            userSerial: 42,
            packageName: "org.example",
            activities: []),
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
    try send(
        AndroidRuntimeBridgeEnvelope(
            kind: .runtimeState,
            generation: generation,
            userUnlocked: false,
            userSerial: 42),
        over: connection)

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorder.events.count < 12,
        ContinuousClock.now < deadline
    {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(
        await recorder.events == [
            .connected(generation: generation),
            .inputReady(generation: generation),
            .taskChanged(generation: generation, task: taskState),
            .taskVanished(generation: generation, task: vanishedTask),
            .clipboardChanged(
                generation: generation,
                update: androidClipboard),
            .userUnlocked(generation: generation, userSerial: 42),
            .notificationsReplaced(
                generation: generation,
                userSerial: 42,
                notifications: [notification]),
            .iconAsset(
                generation: generation,
                userSerial: 42,
                asset: icon),
            .activitiesReplaced(
                generation: generation,
                userSerial: 42,
                activities: activities),
            .packageActivitiesReplaced(
                generation: generation,
                userSerial: 42,
                packageName: "org.example",
                activities: []),
            .cursorShapeChanged(
                generation: generation,
                update: cursor),
            .userLocked(generation: generation, userSerial: 42),
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
    #expect(
        await recorder.events == [
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
        presentationID: 0,
        configurationGeneration: 1,
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
    #expect(
        await recorder.events == [
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
