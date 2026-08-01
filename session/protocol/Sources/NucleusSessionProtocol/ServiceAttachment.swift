import Foundation
import NucleusIPCTransport

public enum SessionServiceAttachmentRole:
    String, Codable, Equatable, Sendable
{
    case configurationControl
    case renderServerControl
    case renderServerConfigurationSubscriber
    case shellConfigurationSubscriber
}

public struct SessionServiceAttachment:
    Codable, Equatable, Sendable
{
    public var protocolVersion: UInt16
    public var role: SessionServiceAttachmentRole

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        role: SessionServiceAttachmentRole
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
    }
}

/// A private supervisor capability. Each packet declares one role and carries
/// exactly one replacement `SOCK_SEQPACKET` endpoint.
public final class SupervisorAttachmentChannel: @unchecked Sendable {
    public static let descriptorArgument =
        "--nucleus-supervisor-attachment-fd"

    private let connection: PacketConnection

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    public init(owning descriptor: Int32) {
        connection = PacketConnection(owning: descriptor)
    }

    public init(borrowing descriptor: Int32) {
        connection = PacketConnection(borrowing: descriptor)
    }

    public func send(
        role: SessionServiceAttachmentRole,
        descriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(SessionServiceAttachment(role: role))
        try connection.send(bytes, descriptors: [descriptor])
    }

    public func receive() throws -> (
        role: SessionServiceAttachmentRole,
        descriptor: OwnedFileDescriptor
    ) {
        let packet = try connection.receive(
            maximumBytes: 4 * 1024,
            maximumDescriptors: 1)
        guard packet.descriptors.count == 1 else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let attachment = try decoder.decode(
            SessionServiceAttachment.self,
            from: Data(packet.bytes))
        guard attachment.protocolVersion == SessionProtocolVersion.current
        else {
            throw ConfigurationChannelFailure.invalidProtocolVersion(
                attachment.protocolVersion)
        }
        return (attachment.role, packet.descriptors[0])
    }
}
