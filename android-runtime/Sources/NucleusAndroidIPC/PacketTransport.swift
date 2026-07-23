import Foundation
import Glibc
import NucleusAndroidGraphicsContract
import NucleusAndroidIPCC

public struct PeerCredentials: Equatable, Sendable {
    public var processID: Int32
    public var userID: UInt32
    public var groupID: UInt32

    public init(processID: Int32, userID: UInt32, groupID: UInt32) {
        self.processID = processID
        self.userID = userID
        self.groupID = groupID
    }
}

public enum PacketTransportError: Error, Equatable {
    case systemCall(operation: String, errno: Int32)
    case packetTooLarge(Int)
    case invalidPacket
    case unauthorizedPeer(expectedUserID: UInt32, actualUserID: UInt32)
}

public final class ReceivedBrokerPacket {
    public let envelope: BrokerEnvelope
    private var descriptors: [Int32]

    init(envelope: BrokerEnvelope, descriptors: [Int32]) {
        self.envelope = envelope
        self.descriptors = descriptors
    }

    public var descriptorCount: Int { descriptors.count }

    public func takeDescriptors() -> [Int32] {
        let taken = descriptors
        descriptors.removeAll(keepingCapacity: false)
        return taken
    }

    deinit {
        for descriptor in descriptors where descriptor >= 0 { _ = Glibc.close(descriptor) }
    }
}

public final class BrokerPacketConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let ownsDescriptor: Bool

    public init(owning fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        ownsDescriptor = true
    }

    init(borrowing fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        ownsDescriptor = false
    }

    public static func connect(path: String) throws -> BrokerPacketConnection {
        let descriptor = path.withCString { nucleus_android_ipc_connect($0) }
        guard descriptor >= 0 else { throw systemError("connect") }
        return BrokerPacketConnection(owning: descriptor)
    }

    public static func socketPair() throws -> (BrokerPacketConnection, BrokerPacketConnection) {
        var pair = [Int32](repeating: -1, count: 2)
        guard nucleus_android_ipc_socket_pair(&pair) == 0 else { throw systemError("socketpair") }
        return (
            BrokerPacketConnection(owning: pair[0]),
            BrokerPacketConnection(owning: pair[1]))
    }

    public var peerCredentials: PeerCredentials? {
        var credentials = nucleus_android_peer_credentials()
        guard nucleus_android_ipc_peer_credentials(fileDescriptor, &credentials) == 0 else {
            return nil
        }
        return PeerCredentials(
            processID: credentials.pid,
            userID: credentials.uid,
            groupID: credentials.gid)
    }

    public func requirePeer(userID: UInt32) throws {
        guard let peer = peerCredentials else { throw Self.systemError("getsockopt(SO_PEERCRED)") }
        guard peer.userID == userID else {
            throw PacketTransportError.unauthorizedPeer(
                expectedUserID: userID,
                actualUserID: peer.userID)
        }
    }

    public func send(_ envelope: BrokerEnvelope, descriptors: [Int32] = []) throws {
        try envelope.validate(receivedFileDescriptorCount: descriptors.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= AndroidGraphicsProtocol.maximumPacketBytes else {
            throw PacketTransportError.packetTooLarge(bytes.count)
        }
        let result = bytes.withUnsafeBytes { rawBytes in
            descriptors.withUnsafeBufferPointer { rawDescriptors in
                nucleus_android_ipc_send(
                    fileDescriptor,
                    rawBytes.baseAddress,
                    rawBytes.count,
                    rawDescriptors.baseAddress,
                    rawDescriptors.count)
            }
        }
        guard result == 0 else { throw Self.systemError("sendmsg") }
    }

    public func receive() throws -> ReceivedBrokerPacket {
        var bytes = [UInt8](repeating: 0, count: AndroidGraphicsProtocol.maximumPacketBytes)
        var descriptors = [Int32](
            repeating: -1,
            count: AndroidGraphicsProtocol.maximumFileDescriptors)
        var descriptorCount = 0
        let byteCount = bytes.withUnsafeMutableBytes { rawBytes in
            descriptors.withUnsafeMutableBufferPointer { rawDescriptors in
                nucleus_android_ipc_receive(
                    fileDescriptor,
                    rawBytes.baseAddress,
                    rawBytes.count,
                    rawDescriptors.baseAddress,
                    rawDescriptors.count,
                    &descriptorCount)
            }
        }
        guard byteCount > 0 else { throw Self.systemError("recvmsg") }
        descriptors.removeSubrange(descriptorCount..<descriptors.count)
        do {
            let envelope = try JSONDecoder().decode(
                BrokerEnvelope.self,
                from: Data(bytes.prefix(Int(byteCount))))
            try envelope.validate(receivedFileDescriptorCount: descriptorCount)
            return ReceivedBrokerPacket(envelope: envelope, descriptors: descriptors)
        } catch {
            for descriptor in descriptors where descriptor >= 0 { _ = Glibc.close(descriptor) }
            throw error
        }
    }

    deinit {
        if ownsDescriptor && fileDescriptor >= 0 { _ = Glibc.close(fileDescriptor) }
    }

    fileprivate static func systemError(_ operation: String) -> PacketTransportError {
        PacketTransportError.systemCall(operation: operation, errno: errno)
    }
}

public final class BrokerPacketListener: @unchecked Sendable {
    public let fileDescriptor: Int32
    public let path: String

    public init(path: String, mode: UInt32 = 0o600) throws {
        let descriptor = path.withCString { nucleus_android_ipc_listen($0, mode) }
        guard descriptor >= 0 else { throw BrokerPacketConnection.systemError("bind/listen") }
        self.fileDescriptor = descriptor
        self.path = path
    }

    public func accept(expectedUserID: UInt32) throws -> BrokerPacketConnection {
        let descriptor = nucleus_android_ipc_accept(fileDescriptor)
        guard descriptor >= 0 else { throw BrokerPacketConnection.systemError("accept") }
        let connection = BrokerPacketConnection(owning: descriptor)
        do {
            try connection.requirePeer(userID: expectedUserID)
            return connection
        } catch {
            throw error
        }
    }

    deinit {
        if fileDescriptor >= 0 { _ = Glibc.close(fileDescriptor) }
        _ = path.withCString { Glibc.unlink($0) }
    }
}
