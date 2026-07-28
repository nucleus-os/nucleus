import FoundationEssentials
import NucleusConfig
import NucleusIPCTransport

/// A fresh identity generated whenever the render-server process starts.
public struct RenderServerEpoch: Codable, Equatable, Hashable, Sendable {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

public struct OwnerControlRequestID:
    RawRepresentable, Codable, Equatable, Hashable, Sendable
{
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct RenderServerOutputSnapshot: Codable, Equatable, Sendable {
    public var id: UInt64
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var refreshMillihertz: UInt32
    public var scale: Double
    public var x: Int32
    public var y: Int32
    public var enabled: Bool

    public init(
        id: UInt64,
        name: String,
        width: UInt32,
        height: UInt32,
        refreshMillihertz: UInt32,
        scale: Double,
        x: Int32,
        y: Int32,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.refreshMillihertz = refreshMillihertz
        self.scale = scale
        self.x = x
        self.y = y
        self.enabled = enabled
    }
}

public enum RenderServerControlRequest: Codable, Equatable, Sendable {
    case version
    case outputs
    case activeBindings
    case action(BindAction)
}

public struct RenderServerControlRequestEnvelope:
    Codable, Equatable, Sendable
{
    public var protocolVersion: UInt16
    public var requestId: OwnerControlRequestID
    public var requestID: OwnerControlRequestID { requestId }
    public var request: RenderServerControlRequest

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        requestID: OwnerControlRequestID,
        request: RenderServerControlRequest
    ) {
        self.protocolVersion = protocolVersion
        requestId = requestID
        self.request = request
    }
}

public enum OwnerControlResult: String, Codable, Equatable, Sendable {
    case ready
    case accepted
    case completed
    case unavailable
    case rejected
}

public enum OwnerControlFailureCode:
    String, Codable, Equatable, Sendable
{
    case unavailable
    case staleGeneration
    case unauthorized
    case invalidRequest
    case rejected
    case internalTransport
}

public struct RenderServerControlPublication:
    Codable, Equatable, Sendable
{
    public var protocolVersion: UInt16
    public var requestId: OwnerControlRequestID?
    public var requestID: OwnerControlRequestID? { requestId }
    public var result: OwnerControlResult
    public var ownerEpoch: RenderServerEpoch
    public var configurationEpoch: ConfigurationServiceEpoch
    public var appliedConfigurationGeneration: ConfigurationGeneration
    public var version: String?
    public var outputs: [RenderServerOutputSnapshot]?
    public var activeBindings: [KeyBind]?
    public var failureCode: OwnerControlFailureCode?
    public var rejection: String?

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        requestID: OwnerControlRequestID? = nil,
        result: OwnerControlResult,
        ownerEpoch: RenderServerEpoch,
        configurationEpoch: ConfigurationServiceEpoch,
        appliedConfigurationGeneration: ConfigurationGeneration,
        version: String? = nil,
        outputs: [RenderServerOutputSnapshot]? = nil,
        activeBindings: [KeyBind]? = nil,
        failureCode: OwnerControlFailureCode? = nil,
        rejection: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        requestId = requestID
        self.result = result
        self.ownerEpoch = ownerEpoch
        self.configurationEpoch = configurationEpoch
        self.appliedConfigurationGeneration = appliedConfigurationGeneration
        self.version = version
        self.outputs = outputs
        self.activeBindings = activeBindings
        self.failureCode = failureCode
        self.rejection = rejection
    }
}

public enum OwnerControlCodec {
    public static let maximumMessageBytes = 4 * 1024 * 1024

    public static func encode(_ value: some Encodable) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return [UInt8](try encoder.encode(value))
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from bytes: some Collection<UInt8>
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(bytes))
    }
}

public final class RenderServerControlChannel: @unchecked Sendable {
    public static let descriptorArgument =
        "--nucleus-render-server-control-fd"

    private let connection: PacketConnection

    public var fileDescriptor: Int32 { connection.fileDescriptor }

    public init(owning descriptor: Int32) {
        connection = PacketConnection(owning: descriptor)
    }

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> RenderServerControlChannel {
        guard let index = arguments.firstIndex(of: descriptorArgument),
              arguments.indices.contains(index + 1),
              let descriptor = Int32(arguments[index + 1]),
              descriptor >= 3
        else {
            throw ConfigurationChannelFailure.invalidDescriptor(
                arguments.firstIndex(of: descriptorArgument).flatMap {
                    arguments.indices.contains($0 + 1)
                        ? arguments[$0 + 1] : nil
                } ?? "<missing>")
        }
        return RenderServerControlChannel(owning: descriptor)
    }

    public func send(_ value: some Encodable) throws {
        try connection.send(OwnerControlCodec.encode(value))
    }

    public func receive<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let packet = try connection.receive(
            maximumBytes: OwnerControlCodec.maximumMessageBytes,
            maximumDescriptors: 0)
        return try OwnerControlCodec.decode(type, from: packet.bytes)
    }
}
