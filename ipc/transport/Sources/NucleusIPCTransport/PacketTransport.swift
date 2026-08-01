import Foundation
import Glibc
import NucleusIPCTransportC

package struct IPCPeerCredentials: Equatable, Sendable {
    package var processID: Int32
    package var userID: UInt32
    package var groupID: UInt32

    package init(processID: Int32, userID: UInt32, groupID: UInt32) {
        self.processID = processID
        self.userID = userID
        self.groupID = groupID
    }
}

package enum IPCTransportError: Error, Equatable, Sendable {
    case systemCall(operation: String, errno: Int32)
    case packetTooLarge(actual: Int, maximum: Int)
    case descriptorCountTooLarge(actual: Int, maximum: Int)
    case unauthorizedPeer(expectedUserID: UInt32, actualUserID: UInt32)
}

public final class OwnedFileDescriptor: @unchecked Sendable {
    private var storage: Int32

    public init(owning descriptor: Int32) {
        storage = descriptor
    }

    public var rawValue: Int32 { storage }

    public func take() -> Int32 {
        let descriptor = storage
        storage = -1
        return descriptor
    }

    deinit {
        if storage >= 0 { _ = Glibc.close(storage) }
    }
}

package struct ReceivedPacket: Sendable {
    package var bytes: [UInt8]
    package var descriptors: [OwnedFileDescriptor]

    package init(bytes: [UInt8], descriptors: [OwnedFileDescriptor]) {
        self.bytes = bytes
        self.descriptors = descriptors
    }
}

package final class PacketConnection: @unchecked Sendable {
    package static let maximumDescriptorCount = 64
    package static let defaultMaximumPacketBytes = 1024 * 1024

    package private(set) var fileDescriptor: Int32
    private var ownsDescriptor: Bool

    package init(owning fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        ownsDescriptor = true
    }

    package init(borrowing fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        ownsDescriptor = false
    }

    package func takeFileDescriptor() -> Int32 {
        precondition(ownsDescriptor && fileDescriptor >= 0)
        let descriptor = fileDescriptor
        fileDescriptor = -1
        ownsDescriptor = false
        return descriptor
    }

    package static func connect(path: String) throws -> PacketConnection {
        let descriptor = path.withCString { unsafe nucleus_ipc_connect($0) }
        guard descriptor >= 0 else { throw systemError("connect") }
        return PacketConnection(owning: descriptor)
    }

    package static func socketPair() throws -> (PacketConnection, PacketConnection) {
        var pair = [Int32](repeating: -1, count: 2)
        guard unsafe nucleus_ipc_socket_pair(&pair) == 0 else {
            throw systemError("socketpair")
        }
        return (
            PacketConnection(owning: pair[0]),
            PacketConnection(owning: pair[1])
        )
    }

    package var peerCredentials: IPCPeerCredentials? {
        var credentials = nucleus_ipc_peer_credentials()
        guard
            unsafe nucleus_ipc_peer_credentials(
                fileDescriptor, &credentials) == 0
        else { return nil }
        return IPCPeerCredentials(
            processID: credentials.pid,
            userID: credentials.uid,
            groupID: credentials.gid)
    }

    package func requirePeer(userID: UInt32) throws {
        guard let peer = peerCredentials else {
            throw Self.systemError("getsockopt(SO_PEERCRED)")
        }
        guard peer.userID == userID else {
            throw IPCTransportError.unauthorizedPeer(
                expectedUserID: userID,
                actualUserID: peer.userID)
        }
    }

    package func send(
        _ bytes: some Collection<UInt8>,
        descriptors: [Int32] = []
    ) throws {
        let packet = Array(bytes)
        guard !packet.isEmpty,
            packet.count <= Self.defaultMaximumPacketBytes
        else {
            throw IPCTransportError.packetTooLarge(
                actual: packet.count,
                maximum: Self.defaultMaximumPacketBytes)
        }
        guard descriptors.count <= Self.maximumDescriptorCount else {
            throw IPCTransportError.descriptorCountTooLarge(
                actual: descriptors.count,
                maximum: Self.maximumDescriptorCount)
        }
        let result = packet.withUnsafeBytes { rawBytes in
            descriptors.withUnsafeBufferPointer { rawDescriptors in
                unsafe nucleus_ipc_send(
                    fileDescriptor,
                    rawBytes.baseAddress,
                    rawBytes.count,
                    rawDescriptors.baseAddress,
                    rawDescriptors.count)
            }
        }
        guard result == 0 else { throw Self.systemError("sendmsg") }
    }

    package func receive(
        maximumBytes: Int = PacketConnection.defaultMaximumPacketBytes,
        maximumDescriptors: Int = PacketConnection.maximumDescriptorCount
    ) throws -> ReceivedPacket {
        precondition(maximumBytes > 0)
        precondition(
            maximumDescriptors >= 0
                && maximumDescriptors <= Self.maximumDescriptorCount)
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        var descriptors = [Int32](repeating: -1, count: maximumDescriptors)
        var descriptorCount = 0
        let byteCount = bytes.withUnsafeMutableBytes { rawBytes in
            descriptors.withUnsafeMutableBufferPointer { rawDescriptors in
                unsafe nucleus_ipc_receive(
                    fileDescriptor,
                    rawBytes.baseAddress,
                    rawBytes.count,
                    rawDescriptors.baseAddress,
                    rawDescriptors.count,
                    &descriptorCount)
            }
        }
        guard byteCount > 0 else { throw Self.systemError("recvmsg") }
        bytes.removeSubrange(Int(byteCount)..<bytes.count)
        descriptors.removeSubrange(descriptorCount..<descriptors.count)
        return ReceivedPacket(
            bytes: bytes,
            descriptors: descriptors.map(OwnedFileDescriptor.init(owning:)))
    }

    deinit {
        if ownsDescriptor && fileDescriptor >= 0 {
            _ = Glibc.close(fileDescriptor)
        }
    }

    static func systemError(_ operation: String) -> IPCTransportError {
        IPCTransportError.systemCall(operation: operation, errno: errno)
    }
}

package final class PacketListener: @unchecked Sendable {
    package let fileDescriptor: Int32
    package let path: String
    private let removesPathOnDeinit: Bool
    private let pathDevice: dev_t
    private let pathInode: ino_t

    package init(
        path: String,
        mode: UInt32 = 0o600,
        nonblocking: Bool = false,
        removesPathOnDeinit: Bool = true
    ) throws {
        let descriptor = path.withCString {
            unsafe nucleus_ipc_listen($0, mode)
        }
        guard descriptor >= 0 else {
            throw PacketConnection.systemError("bind/listen")
        }
        if nonblocking {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                let code = errno
                _ = Glibc.close(descriptor)
                _ = path.withCString { unsafe Glibc.unlink($0) }
                throw IPCTransportError.systemCall(
                    operation: "fcntl(O_NONBLOCK)",
                    errno: code)
            }
        }
        var metadata = stat()
        guard
            path.withCString({
                unsafe Glibc.lstat($0, &metadata)
            }) == 0
        else {
            let code = errno
            _ = Glibc.close(descriptor)
            _ = path.withCString { unsafe Glibc.unlink($0) }
            throw IPCTransportError.systemCall(
                operation: "lstat(listener)",
                errno: code)
        }
        fileDescriptor = descriptor
        self.path = path
        self.removesPathOnDeinit = removesPathOnDeinit
        pathDevice = metadata.st_dev
        pathInode = metadata.st_ino
    }

    package func accept() throws -> PacketConnection {
        let descriptor = nucleus_ipc_accept(fileDescriptor)
        guard descriptor >= 0 else {
            throw PacketConnection.systemError("accept")
        }
        return PacketConnection(owning: descriptor)
    }

    package func accept(expectedUserID: UInt32) throws -> PacketConnection {
        let connection = try accept()
        try connection.requirePeer(userID: expectedUserID)
        return connection
    }

    deinit {
        _ = Glibc.close(fileDescriptor)
        if removesPathOnDeinit {
            var metadata = stat()
            let stillOwnsPath =
                path.withCString {
                    unsafe Glibc.lstat($0, &metadata)
                } == 0
                && metadata.st_dev == pathDevice
                && metadata.st_ino == pathInode
            if stillOwnsPath {
                _ = path.withCString { unsafe Glibc.unlink($0) }
            }
        }
    }
}
