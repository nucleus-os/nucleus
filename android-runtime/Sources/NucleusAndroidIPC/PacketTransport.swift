import FoundationEssentials
import NucleusAndroidGraphicsContract
import NucleusIPCTransport

public typealias PeerCredentials = IPCPeerCredentials

public enum PacketTransportError: Error, Equatable {
    case systemCall(operation: String, errno: Int32)
    case packetTooLarge(Int)
    case invalidPacket
    case unauthorizedPeer(expectedUserID: UInt32, actualUserID: UInt32)
}

public final class ReceivedBrokerPacket {
    public let envelope: BrokerEnvelope
    private var descriptors: [OwnedFileDescriptor]

    init(envelope: BrokerEnvelope, descriptors: [OwnedFileDescriptor]) {
        self.envelope = envelope
        self.descriptors = descriptors
    }

    public var descriptorCount: Int { descriptors.count }

    public func takeDescriptors() -> [Int32] {
        let taken = descriptors.map { $0.take() }
        descriptors.removeAll(keepingCapacity: false)
        return taken
    }
}

public final class BrokerPacketConnection: @unchecked Sendable {
    private let connection: PacketConnection

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    fileprivate init(_ connection: PacketConnection) {
        self.connection = connection
    }

    public init(owning fileDescriptor: Int32) {
        connection = PacketConnection(owning: fileDescriptor)
    }

    init(borrowing fileDescriptor: Int32) {
        connection = PacketConnection(borrowing: fileDescriptor)
    }

    public static func connect(path: String) throws -> BrokerPacketConnection {
        do {
            return BrokerPacketConnection(
                try PacketConnection.connect(path: path))
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public static func socketPair() throws
        -> (BrokerPacketConnection, BrokerPacketConnection)
    {
        do {
            let pair = try PacketConnection.socketPair()
            return (
                BrokerPacketConnection(pair.0),
                BrokerPacketConnection(pair.1))
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public var peerCredentials: PeerCredentials? {
        connection.peerCredentials
    }

    public func requirePeer(userID: UInt32) throws {
        do {
            try connection.requirePeer(userID: userID)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func send(
        _ envelope: BrokerEnvelope,
        descriptors: [Int32] = []
    ) throws {
        try envelope.validate(
            receivedFileDescriptorCount: descriptors.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= AndroidGraphicsProtocol.maximumPacketBytes else {
            throw PacketTransportError.packetTooLarge(bytes.count)
        }
        do {
            try connection.send(bytes, descriptors: descriptors)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func receive() throws -> ReceivedBrokerPacket {
        let packet: ReceivedPacket
        do {
            packet = try connection.receive(
                maximumBytes: AndroidGraphicsProtocol.maximumPacketBytes,
                maximumDescriptors:
                    AndroidGraphicsProtocol.maximumFileDescriptors)
        } catch {
            throw Self.mapTransportError(error)
        }
        let envelope = try JSONDecoder().decode(
            BrokerEnvelope.self,
            from: Data(packet.bytes))
        try envelope.validate(
            receivedFileDescriptorCount: packet.descriptors.count)
        return ReceivedBrokerPacket(
            envelope: envelope,
            descriptors: packet.descriptors)
    }

    fileprivate static func mapTransportError(
        _ error: any Error
    ) -> PacketTransportError {
        guard let transport = error as? IPCTransportError else {
            return .invalidPacket
        }
        switch transport {
        case .systemCall(let operation, let code):
            return .systemCall(operation: operation, errno: code)
        case .packetTooLarge(let actual, _):
            return .packetTooLarge(actual)
        case .descriptorCountTooLarge:
            return .invalidPacket
        case .unauthorizedPeer(let expected, let actual):
            return .unauthorizedPeer(
                expectedUserID: expected,
                actualUserID: actual)
        }
    }
}

public final class BrokerPacketListener: @unchecked Sendable {
    private let listener: PacketListener

    public var fileDescriptor: Int32 { listener.fileDescriptor }
    public var path: String { listener.path }

    public init(path: String, mode: UInt32 = 0o600) throws {
        do {
            listener = try PacketListener(path: path, mode: mode)
        } catch {
            throw BrokerPacketConnection.mapTransportError(error)
        }
    }

    public func accept(expectedUserID: UInt32) throws
        -> BrokerPacketConnection
    {
        do {
            return BrokerPacketConnection(
                try listener.accept(expectedUserID: expectedUserID))
        } catch {
            throw BrokerPacketConnection.mapTransportError(error)
        }
    }
}
