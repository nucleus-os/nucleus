import Foundation
import Glibc
import NucleusAndroidRuntimeCore
import NucleusIPCTransport

public enum AndroidRuntimeBridgeProtocol {
    public static let version: UInt16 = 1
    public static let maximumPacketBytes = 256 * 1_024
    public static let maximumActivities = 16_384
}

public enum AndroidRuntimeBridgeMessageKind:
    String, Codable, Equatable, Sendable
{
    case bridgeHello
    case brokerHello
    case runtimeState
    case replaceActivities
}

public struct AndroidRuntimeBridgeActivity:
    Codable, Equatable, Sendable
{
    public let packageName: String
    public let activityName: String
    public let label: String

    public init(
        packageName: String,
        activityName: String,
        label: String
    ) {
        self.packageName = packageName
        self.activityName = activityName
        self.label = label
    }
}

public struct AndroidRuntimeBridgeEnvelope:
    Codable, Equatable, Sendable
{
    public let protocolVersion: UInt16
    public let kind: AndroidRuntimeBridgeMessageKind
    public let generation: String?
    public let userUnlocked: Bool?
    public let userSerial: Int64?
    public let activities: [AndroidRuntimeBridgeActivity]?

    public init(
        protocolVersion: UInt16 =
            AndroidRuntimeBridgeProtocol.version,
        kind: AndroidRuntimeBridgeMessageKind,
        generation: String? = nil,
        userUnlocked: Bool? = nil,
        userSerial: Int64? = nil,
        activities: [AndroidRuntimeBridgeActivity]? = nil
    ) throws {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.generation = generation
        self.userUnlocked = userUnlocked
        self.userSerial = userSerial
        self.activities = activities
        try validate()
    }

    public func validate() throws {
        guard protocolVersion == AndroidRuntimeBridgeProtocol.version else {
            throw AndroidRuntimeFailure(
                "unsupported Android bridge protocol version")
        }
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
        switch kind {
        case .bridgeHello:
            guard generation == nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge hello")
            }
        case .brokerHello:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                activities == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android broker hello")
            }
        case .runtimeState:
            guard generation != nil,
                userUnlocked != nil,
                userSerial != nil,
                activities == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge runtime state")
            }
        case .replaceActivities:
            guard generation != nil,
                userUnlocked == true,
                userSerial != nil,
                activities != nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android activity snapshot")
            }
        }
    }
}

public enum AndroidRuntimeBridgeEvent: Equatable, Sendable {
    case connected(generation: String)
    case userUnlocked(generation: String, userSerial: Int64)
    case activitiesReplaced(
        generation: String,
        userSerial: Int64,
        activities: [AndroidRuntimeBridgeActivity])
    case disconnected(generation: String)
}

public final class AndroidRuntimeBridgeServer: @unchecked Sendable {
    private let listener: PacketListener
    private let expectedUserID: UInt32
    public let generation: String

    public init(
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

    public func run(
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
        try send(
            AndroidRuntimeBridgeEnvelope(
                kind: .brokerHello,
                generation: generation),
            over: connection)
        await onEvent(.connected(generation: generation))
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
            case .runtimeState:
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
            case .bridgeHello, .brokerHello:
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
