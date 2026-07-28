import FoundationEssentials
import NucleusConfig
import NucleusIPCTransport

public enum ShellPolicyChannelFailure: Error, CustomStringConvertible {
    case invalidDescriptor(String)
    case invalidProtocolVersion(UInt16)
    case invalidAttachment

    public var description: String {
        switch self {
        case .invalidDescriptor(let value):
            "invalid shell policy descriptor '\(value)'"
        case .invalidProtocolVersion(let version):
            "unsupported shell policy protocol version \(version)"
        case .invalidAttachment:
            "shell policy attachment must carry exactly one endpoint"
        }
    }
}

public enum ShellPolicyRequestKind:
    String, Codable, Sendable, Equatable
{
    case setCursorTheme
    case selectWindowMenuItem
}

public struct ShellPolicyRequest: Codable, Sendable, Equatable {
    public var protocolVersion: UInt16
    public var kind: ShellPolicyRequestKind
    public var cursorTheme: String?
    public var windowID: UInt64?
    public var windowMenuVerb: UInt32?

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        kind: ShellPolicyRequestKind,
        cursorTheme: String? = nil,
        windowID: UInt64? = nil,
        windowMenuVerb: UInt32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.cursorTheme = cursorTheme
        self.windowID = windowID
        self.windowMenuVerb = windowMenuVerb
    }
}

public enum ShellPolicyPublicationKind:
    String, Codable, Sendable, Equatable
{
    case ready
    case acceptedAction
    case windowMenuOffered
}

public struct ShellPolicyPublication: Codable, Sendable, Equatable {
    public var protocolVersion: UInt16
    public var kind: ShellPolicyPublicationKind
    public var action: BindAction?
    public var configurationIndex: UInt32?
    public var configurationEpoch: ConfigurationServiceEpoch?
    public var configurationGeneration: ConfigurationGeneration?
    public var windowID: UInt64?
    public var x: Double?
    public var y: Double?
    public var windowCapabilities: UInt32?

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        kind: ShellPolicyPublicationKind,
        action: BindAction? = nil,
        configurationIndex: UInt32? = nil,
        configurationEpoch: ConfigurationServiceEpoch? = nil,
        configurationGeneration: ConfigurationGeneration? = nil,
        windowID: UInt64? = nil,
        x: Double? = nil,
        y: Double? = nil,
        windowCapabilities: UInt32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.action = action
        self.configurationIndex = configurationIndex
        self.configurationEpoch = configurationEpoch
        self.configurationGeneration = configurationGeneration
        self.windowID = windowID
        self.x = x
        self.y = y
        self.windowCapabilities = windowCapabilities
    }
}

/// One private, supervisor-provisioned shell-policy endpoint.
public final class ShellPolicyChannel: @unchecked Sendable {
    public static let descriptorArgument =
        "--nucleus-shell-policy-fd"
    public static let maximumMessageBytes = 256 * 1024

    private let connection: PacketConnection

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    public init(owning descriptor: Int32) {
        connection = PacketConnection(owning: descriptor)
    }

    public init(borrowing descriptor: Int32) {
        connection = PacketConnection(borrowing: descriptor)
    }

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> ShellPolicyChannel? {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first else {
            throw ShellPolicyChannelFailure.invalidDescriptor("<duplicate>")
        }
        guard arguments.indices.contains(index + 1),
              let descriptor = Int32(arguments[index + 1]),
              descriptor >= 3
        else {
            throw ShellPolicyChannelFailure.invalidDescriptor(
                arguments.indices.contains(index + 1)
                    ? arguments[index + 1] : "<missing>")
        }
        return ShellPolicyChannel(owning: descriptor)
    }

    public func send(_ request: ShellPolicyRequest) throws {
        try sendValue(request)
    }

    public func send(_ publication: ShellPolicyPublication) throws {
        try sendValue(publication)
    }

    public func receiveRequest() throws -> ShellPolicyRequest {
        let value: ShellPolicyRequest = try receiveValue()
        guard value.protocolVersion == SessionProtocolVersion.current else {
            throw ShellPolicyChannelFailure.invalidProtocolVersion(
                value.protocolVersion)
        }
        return value
    }

    public func receivePublication() throws -> ShellPolicyPublication {
        let value: ShellPolicyPublication = try receiveValue()
        guard value.protocolVersion == SessionProtocolVersion.current else {
            throw ShellPolicyChannelFailure.invalidProtocolVersion(
                value.protocolVersion)
        }
        return value
    }

    private func sendValue(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        try connection.send(encoder.encode(value))
    }

    private func receiveValue<Value: Decodable>() throws -> Value {
        let packet = try connection.receive(
            maximumBytes: Self.maximumMessageBytes,
            maximumDescriptors: 0)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: Data(packet.bytes))
    }
}

/// Supervisor-to-compositor transfer of the policy endpoint for one shell
/// generation.
public final class ShellPolicyAttachmentChannel: @unchecked Sendable {
    public static let descriptorArgument =
        "--nucleus-shell-policy-attachment-fd"

    private let connection: PacketConnection

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    public init(owning descriptor: Int32) {
        connection = PacketConnection(owning: descriptor)
    }

    public init(borrowing descriptor: Int32) {
        connection = PacketConnection(borrowing: descriptor)
    }

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> ShellPolicyAttachmentChannel? {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first else {
            throw ShellPolicyChannelFailure.invalidDescriptor("<duplicate>")
        }
        guard arguments.indices.contains(index + 1),
              let descriptor = Int32(arguments[index + 1]),
              descriptor >= 3
        else {
            throw ShellPolicyChannelFailure.invalidDescriptor(
                arguments.indices.contains(index + 1)
                    ? arguments[index + 1] : "<missing>")
        }
        return ShellPolicyAttachmentChannel(owning: descriptor)
    }

    public func send(policyDescriptor: Int32) throws {
        try connection.send(
            [UInt8](repeating: 0, count: 1),
            descriptors: [policyDescriptor])
    }

    public func receive() throws -> OwnedFileDescriptor {
        let packet = try connection.receive(
            maximumBytes: 1,
            maximumDescriptors: 1)
        guard packet.bytes == [0], packet.descriptors.count == 1 else {
            throw ShellPolicyChannelFailure.invalidAttachment
        }
        return packet.descriptors[0]
    }
}
