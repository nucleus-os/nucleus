import Foundation
import Glibc
import NucleusAndroidRuntimeCore
import NucleusIPCTransport
import Synchronization

package enum AndroidRuntimeBridgeProtocol {
    package static let maximumPacketBytes = 256 * 1_024
    package static let maximumActivities = 16_384
    package static let androidUserID: UInt32 = 2_900
}

package enum AndroidRuntimeBridgeMessageKind:
    String, Codable, Equatable, Sendable
{
    case bridgeHello
    case brokerHello
    case runtimeState
    case replaceActivities
    case inputState
    case inputEvent
    case cursorShape
}

package enum AndroidInputAction: String, Codable, Equatable, Sendable {
    case pointerMotion
    case pointerButton
    case pointerScroll
    case key
}

package struct AndroidInputEvent: Codable, Equatable, Sendable {
    package let displayID: Int32
    package let eventTimeNanoseconds: UInt64
    package let x: Double?
    package let y: Double?
    package let button: UInt32?
    package let keyCode: UInt32?
    package let pressed: Bool?
    package let scrollX: Double?
    package let scrollY: Double?
    package let action: AndroidInputAction

    package init(
        displayID: Int32,
        eventTimeNanoseconds: UInt64,
        x: Double? = nil,
        y: Double? = nil,
        button: UInt32? = nil,
        keyCode: UInt32? = nil,
        pressed: Bool? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        action: AndroidInputAction
    ) throws {
        self.displayID = displayID
        self.eventTimeNanoseconds = eventTimeNanoseconds
        self.x = x
        self.y = y
        self.button = button
        self.keyCode = keyCode
        self.pressed = pressed
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.action = action
        try validate()
    }

    package func validate() throws {
        guard displayID >= 0,
            x?.isFinite ?? true,
            y?.isFinite ?? true,
            (x ?? 0) >= 0, (y ?? 0) >= 0,
            (x ?? 0) <= 65_536, (y ?? 0) <= 65_536,
            scrollX?.isFinite ?? true,
            scrollY?.isFinite ?? true
        else {
            throw AndroidRuntimeFailure(
                "Android input event is invalid")
        }
        switch action {
        case .pointerMotion:
            guard x != nil, y != nil,
                button == nil, keyCode == nil, pressed == nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer motion has invalid fields")
            }
        case .pointerButton:
            guard let button,
                button == 0x110 || button == 0x111
                    || button == 0x112 || button == 0x113
                    || button == 0x114,
                x != nil, y != nil,
                keyCode == nil, pressed != nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer button is invalid")
            }
        case .pointerScroll:
            guard x != nil, y != nil,
                button == nil, keyCode == nil, pressed == nil,
                scrollX != nil || scrollY != nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer scroll is invalid")
            }
        case .key:
            guard x == nil, y == nil, button == nil,
                let keyCode, keyCode <= 0x2ff,
                pressed != nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android keyboard event is invalid")
            }
        }
    }
}

package struct AndroidCursorShapeUpdate: Codable, Equatable, Sendable {
    package let displayID: Int32
    package let pointerIconType: Int32

    package init(displayID: Int32, pointerIconType: Int32) throws {
        self.displayID = displayID
        self.pointerIconType = pointerIconType
        try validate()
    }

    package func validate() throws {
        guard displayID >= 0,
            pointerIconType >= -1,
            pointerIconType <= 10_000
        else {
            throw AndroidRuntimeFailure(
                "Android cursor-shape update is invalid")
        }
    }
}

package struct AndroidRuntimeBridgeActivity:
    Codable, Equatable, Sendable
{
    package let packageName: String
    package let activityName: String
    package let label: String

    package init(
        packageName: String,
        activityName: String,
        label: String
    ) {
        self.packageName = packageName
        self.activityName = activityName
        self.label = label
    }
}

package struct AndroidRuntimeBridgeEnvelope:
    Codable, Equatable, Sendable
{
    package let kind: AndroidRuntimeBridgeMessageKind
    package let generation: String?
    package let userUnlocked: Bool?
    package let userSerial: Int64?
    package let activities: [AndroidRuntimeBridgeActivity]?
    package let inputReady: Bool?
    package let inputError: String?
    package let inputEvent: AndroidInputEvent?
    package let cursorShape: AndroidCursorShapeUpdate?

    package init(
        kind: AndroidRuntimeBridgeMessageKind,
        generation: String? = nil,
        userUnlocked: Bool? = nil,
        userSerial: Int64? = nil,
        activities: [AndroidRuntimeBridgeActivity]? = nil,
        inputReady: Bool? = nil,
        inputError: String? = nil,
        inputEvent: AndroidInputEvent? = nil,
        cursorShape: AndroidCursorShapeUpdate? = nil
    ) throws {
        self.kind = kind
        self.generation = generation
        self.userUnlocked = userUnlocked
        self.userSerial = userSerial
        self.activities = activities
        self.inputReady = inputReady
        self.inputError = inputError
        self.inputEvent = inputEvent
        self.cursorShape = cursorShape
        try validate()
    }

    package func validate() throws {
        if let generation {
            guard !generation.isEmpty,
                generation.utf8.count <= 128,
                generation.utf8.allSatisfy({
                    $0 >= Character("a").asciiValue!
                        && $0 <= Character("z").asciiValue!
                        || $0 >= Character("0").asciiValue!
                            && $0 <= Character("9").asciiValue!
                        || $0 == Character("-").asciiValue!
                })
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge generation")
            }
        }
        guard (activities?.count ?? 0)
            <= AndroidRuntimeBridgeProtocol.maximumActivities
        else {
            throw AndroidRuntimeFailure(
                "Android bridge activity snapshot is oversized")
        }
        guard activities?.allSatisfy({
            Self.validActivityField($0.packageName)
                && Self.validActivityField($0.activityName)
                && Self.validActivityField($0.label)
        }) ?? true else {
            throw AndroidRuntimeFailure(
                "Android bridge activity metadata is invalid")
        }
        guard inputError?.utf8.count ?? 0 <= 16_384,
            !(inputError?.contains("\0") ?? false)
        else {
            throw AndroidRuntimeFailure(
                "Android input-service error is invalid")
        }
        switch kind {
        case .bridgeHello:
            guard generation == nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge hello")
            }
        case .brokerHello:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android broker hello")
            }
        case .runtimeState:
            guard generation != nil,
                userUnlocked != nil,
                userSerial != nil,
                activities == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge runtime state")
            }
        case .replaceActivities:
            guard generation != nil,
                userUnlocked == true,
                userSerial != nil,
                activities != nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android activity snapshot")
            }
        case .inputState:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil,
                let inputReady,
                inputReady ? inputError == nil : inputError?.isEmpty == false,
                inputEvent == nil,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android input-service state")
            }
        case .inputEvent:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil,
                inputReady == nil,
                inputError == nil,
                let inputEvent,
                cursorShape == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android input event")
            }
            try inputEvent.validate()
        case .cursorShape:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                let cursorShape
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android cursor-shape update")
            }
            try cursorShape.validate()
        }
    }

    private static func validActivityField(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.contains("\0")
    }
}

package enum AndroidRuntimeBridgeEvent: Equatable, Sendable {
    case connected(generation: String)
    case inputReady(generation: String)
    case inputFailed(generation: String, error: String)
    case userUnlocked(generation: String, userSerial: Int64)
    case activitiesReplaced(
        generation: String,
        userSerial: Int64,
        activities: [AndroidRuntimeBridgeActivity])
    case cursorShapeChanged(
        generation: String,
        update: AndroidCursorShapeUpdate)
    case disconnected(generation: String)
}

package final class AndroidRuntimeBridgeServer: @unchecked Sendable {
    private let listener: PacketListener
    private let expectedUserID: UInt32
    package let generation: String
    private let writer = Mutex<PacketConnection?>(nil)

    package init(
        socketPath: URL,
        expectedUserID: UInt32,
        generation: String = UUID().uuidString.lowercased()
    ) throws {
        self.expectedUserID = expectedUserID
        self.generation = generation
        listener = try PacketListener(
            path: socketPath.path,
            mode: 0o666,
            nonblocking: true)
    }

    package func send(_ inputEvent: AndroidInputEvent) throws {
        try writer.withLock { connection in
            guard let connection else {
                throw AndroidRuntimeFailure(
                    "Android runtime bridge is not connected")
            }
            try send(
                AndroidRuntimeBridgeEnvelope(
                    kind: .inputEvent,
                    generation: generation,
                    inputEvent: inputEvent),
                over: connection)
        }
    }

    package func run(
        onEvent: @escaping @Sendable (
            AndroidRuntimeBridgeEvent
        ) async -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(listener.fileDescriptor) else {
                continue
            }
            let connection: PacketConnection
            do {
                connection = try listener.accept(
                    expectedUserID: expectedUserID)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    continue
                }
                throw error
            }
            do {
                try await serve(connection, onEvent: onEvent)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as AndroidRuntimeFailure {
                throw failure
            } catch {
                await onEvent(.disconnected(generation: generation))
            }
        }
    }

    private func serve(
        _ connection: PacketConnection,
        onEvent: @escaping @Sendable (
            AndroidRuntimeBridgeEvent
        ) async -> Void
    ) async throws {
        let hello = try receive(connection)
        guard hello.kind == .bridgeHello else {
            throw AndroidRuntimeFailure(
                "Android bridge did not begin with hello")
        }
        writer.withLock { $0 = connection }
        defer {
            writer.withLock { current in
                if current === connection {
                    current = nil
                }
            }
        }
        try send(
            AndroidRuntimeBridgeEnvelope(
                kind: .brokerHello,
                generation: generation),
            over: connection)
        await onEvent(.connected(generation: generation))
        var inputStatePublished = false
        var unlockedPublished = false
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(connection.fileDescriptor) else {
                continue
            }
            let envelope = try receive(connection)
            guard envelope.generation == generation else {
                throw AndroidRuntimeFailure(
                    "Android bridge sent a stale generation")
            }
            switch envelope.kind {
            case .inputState:
                guard !inputStatePublished,
                    let ready = envelope.inputReady
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge duplicated input-service state")
                }
                inputStatePublished = true
                if ready {
                    await onEvent(.inputReady(generation: generation))
                } else {
                    let error = envelope.inputError
                        ?? "Android omitted the input-service error"
                    await onEvent(.inputFailed(
                        generation: generation,
                        error: error))
                }
            case .runtimeState:
                guard inputStatePublished else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published runtime state before input")
                }
                if envelope.userUnlocked == true {
                    guard !unlockedPublished,
                        let serial = envelope.userSerial
                    else {
                        throw AndroidRuntimeFailure(
                            "Android bridge duplicated user unlock")
                    }
                    unlockedPublished = true
                    await onEvent(.userUnlocked(
                        generation: generation,
                        userSerial: serial))
                }
            case .replaceActivities:
                guard unlockedPublished,
                    let serial = envelope.userSerial,
                    let activities = envelope.activities
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published activities before unlock")
                }
                await onEvent(.activitiesReplaced(
                    generation: generation,
                    userSerial: serial,
                    activities: activities))
            case .cursorShape:
                guard let update = envelope.cursorShape else {
                    throw AndroidRuntimeFailure(
                        "Android bridge omitted cursor-shape update")
                }
                await onEvent(.cursorShapeChanged(
                    generation: generation,
                    update: update))
            case .bridgeHello, .brokerHello, .inputEvent:
                throw AndroidRuntimeFailure(
                    "unexpected Android bridge handshake message")
            }
        }
    }

    private func send(
        _ envelope: AndroidRuntimeBridgeEnvelope,
        over connection: PacketConnection
    ) throws {
        let bytes = try JSONEncoder().encode(envelope)
        guard bytes.count
            <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android bridge packet is oversized")
        }
        try connection.send(bytes)
    }

    private func receive(
        _ connection: PacketConnection
    ) throws -> AndroidRuntimeBridgeEnvelope {
        let packet = try connection.receive(
            maximumBytes:
                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw AndroidRuntimeFailure(
                "Android bridge packets cannot carry descriptors")
        }
        let envelope = try JSONDecoder().decode(
            AndroidRuntimeBridgeEnvelope.self,
            from: Data(packet.bytes))
        try envelope.validate()
        return envelope
    }

    private func waitUntilReadable(
        _ descriptor: Int32
    ) throws -> Bool {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
        let result = unsafe poll(&pollDescriptor, 1, 250)
        if result < 0, errno != EINTR {
            throw IPCTransportError.systemCall(
                operation: "poll(Android bridge)",
                errno: errno)
        }
        return result > 0
    }
}

private enum AndroidDisplayInteractionKind:
    String, Codable, Sendable
{
    case inputEvent
    case cursorShape
}

private struct AndroidDisplayInteractionEnvelope:
    Codable, Sendable
{
    let kind: AndroidDisplayInteractionKind
    let inputEvent: AndroidInputEvent?
    let cursorShape: AndroidCursorShapeUpdate?

    init(inputEvent: AndroidInputEvent) {
        kind = .inputEvent
        self.inputEvent = inputEvent
        cursorShape = nil
    }

    init(cursorShape: AndroidCursorShapeUpdate) {
        kind = .cursorShape
        inputEvent = nil
        self.cursorShape = cursorShape
    }
}

package enum AndroidDisplayInteractionEvent: Sendable {
    case input(AndroidInputEvent)
}

package final class AndroidDisplayInteractionServer: @unchecked Sendable {
    private struct State {
        var connection: PacketConnection?
        var latestCursorShapeByDisplay: [
            Int32: AndroidCursorShapeUpdate
        ] = [:]
    }

    private let listener: PacketListener
    private let expectedUserID: UInt32
    private let state = Mutex(State())

    package init(socketPath: URL, expectedUserID: UInt32) throws {
        self.expectedUserID = expectedUserID
        listener = try PacketListener(
            path: socketPath.path,
            mode: 0o600,
            nonblocking: true)
    }

    package func run(
        onEvent: @escaping @Sendable (
            AndroidDisplayInteractionEvent
        ) throws -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(listener.fileDescriptor) else {
                continue
            }
            let connection: PacketConnection
            do {
                connection = try listener.accept(
                    expectedUserID: expectedUserID)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    continue
                }
                throw error
            }
            do {
                try state.withLock { state in
                    state.connection = connection
                    for update in state.latestCursorShapeByDisplay
                        .values.sorted(by: {
                            $0.displayID < $1.displayID
                        })
                    {
                        try connection.send(
                            try Self.encode(cursorShape: update))
                    }
                }
                defer {
                    state.withLock { state in
                        if state.connection === connection {
                            state.connection = nil
                        }
                    }
                }
                while true {
                    try Task.checkCancellation()
                    guard try waitUntilReadable(connection.fileDescriptor) else {
                        continue
                    }
                    do {
                        let packet = try connection.receive(
                            maximumBytes:
                                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
                            maximumDescriptors: 0)
                        guard packet.descriptors.isEmpty else {
                            throw AndroidRuntimeFailure(
                                "Android display interaction packets cannot carry descriptors")
                        }
                        let envelope = try JSONDecoder().decode(
                            AndroidDisplayInteractionEnvelope.self,
                            from: Data(packet.bytes))
                        switch envelope.kind {
                        case .inputEvent:
                            guard let event = envelope.inputEvent,
                                envelope.cursorShape == nil
                            else {
                                throw AndroidRuntimeFailure(
                                    "invalid Android display input")
                            }
                            try event.validate()
                            try onEvent(.input(event))
                        case .cursorShape:
                            throw AndroidRuntimeFailure(
                                "Android display host sent a cursor shape")
                        }
                    } catch let error as IPCTransportError {
                        if case .systemCall(_, let code) = error,
                            code == ECONNRESET || code == EPIPE
                        {
                            break
                        }
                        throw error
                    }
                }
            }
        }
    }

    package func send(_ update: AndroidCursorShapeUpdate) throws {
        try update.validate()
        let bytes = try Self.encode(cursorShape: update)
        try state.withLock { state in
            state.latestCursorShapeByDisplay[update.displayID] = update
            guard let connection = state.connection else { return }
            try connection.send(bytes)
        }
    }

    private static func encode(
        cursorShape update: AndroidCursorShapeUpdate
    ) throws -> Data {
        let bytes = try JSONEncoder().encode(
            AndroidDisplayInteractionEnvelope(cursorShape: update))
        guard bytes.count
            <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android display interaction packet is oversized")
        }
        return bytes
    }

    private func waitUntilReadable(_ descriptor: Int32) throws -> Bool {
        var state = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
        let result = unsafe poll(&state, 1, 50)
        if result < 0, errno != EINTR {
            throw IPCTransportError.systemCall(
                operation: "poll(Android display input)",
                errno: errno)
        }
        return result > 0
    }
}

package final class AndroidDisplayInteractionClient: @unchecked Sendable {
    private let connection: PacketConnection
    package var fileDescriptor: Int32 { connection.fileDescriptor }

    package init(socketPath: String) throws {
        connection = try PacketConnection.connect(path: socketPath)
    }

    package func send(_ event: AndroidInputEvent) throws {
        try send(AndroidDisplayInteractionEnvelope(inputEvent: event))
    }

    private func send(
        _ envelope: AndroidDisplayInteractionEnvelope
    ) throws {
        let bytes = try JSONEncoder().encode(envelope)
        guard bytes.count
            <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android display-input packet is oversized")
        }
        try connection.send(bytes)
    }

    package func receiveCursorShape() throws -> AndroidCursorShapeUpdate {
        let packet = try connection.receive(
            maximumBytes:
                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw AndroidRuntimeFailure(
                "Android display interaction packets cannot carry descriptors")
        }
        let envelope = try JSONDecoder().decode(
            AndroidDisplayInteractionEnvelope.self,
            from: Data(packet.bytes))
        guard envelope.kind == .cursorShape,
            envelope.inputEvent == nil,
            let update = envelope.cursorShape
        else {
            throw AndroidRuntimeFailure(
                "Android display interaction expected cursor shape")
        }
        try update.validate()
        return update
    }
}
