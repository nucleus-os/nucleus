public import NucleusConfig
import FoundationEssentials
public import NucleusFoundation

public enum ControlProtocolVersion {
    public static let current: UInt16 = 2
}

public struct ControlRequestID:
    RawRepresentable, Codable, Hashable, Sendable
{
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ControlRequestEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: UInt16
    public var requestId: ControlRequestID
    public var requestID: ControlRequestID { requestId }
    public var request: ControlRequest

    public init(
        protocolVersion: UInt16 = ControlProtocolVersion.current,
        requestID: ControlRequestID,
        request: ControlRequest
    ) {
        self.protocolVersion = protocolVersion
        requestId = requestID
        self.request = request
    }
}

public struct ControlResponseEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: UInt16
    public var requestId: ControlRequestID
    public var requestID: ControlRequestID { requestId }
    public var response: ControlResponse

    public init(
        protocolVersion: UInt16 = ControlProtocolVersion.current,
        requestID: ControlRequestID,
        response: ControlResponse
    ) {
        self.protocolVersion = protocolVersion
        requestId = requestID
        self.response = response
    }
}

public enum ControlProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(expected: UInt16, actual: UInt16)
    case mismatchedRequestID(
        expected: ControlRequestID,
        actual: ControlRequestID)
}

/// One deterministic JSON envelope is carried in each `SOCK_SEQPACKET` packet.
public enum ControlRequest: Codable, Equatable, Sendable {
    case version
    case action(BindAction)
    case configuration
    case reloadConfiguration
    case validateConfiguration(String)
    case replaceConfiguration(String)
    case exportConfiguration
    case outputs
    case binds

    private enum CodingKeys: String, CodingKey {
        case request
        case action
        case source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .request)
        switch name {
        case "version": self = .version
        case "configuration": self = .configuration
        case "reload-configuration": self = .reloadConfiguration
        case "validate-configuration":
            self = .validateConfiguration(
                try container.decode(String.self, forKey: .source))
        case "replace-configuration":
            self = .replaceConfiguration(
                try container.decode(String.self, forKey: .source))
        case "export-configuration": self = .exportConfiguration
        case "outputs": self = .outputs
        case "binds": self = .binds
        case "action":
            self = .action(
                try container.decode(BindAction.self, forKey: .action))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.request],
                debugDescription: "unknown request '\(name)'"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .version:
            try container.encode("version", forKey: .request)
        case .configuration:
            try container.encode("configuration", forKey: .request)
        case .reloadConfiguration:
            try container.encode("reload-configuration", forKey: .request)
        case .validateConfiguration(let source):
            try container.encode("validate-configuration", forKey: .request)
            try container.encode(source, forKey: .source)
        case .replaceConfiguration(let source):
            try container.encode("replace-configuration", forKey: .request)
            try container.encode(source, forKey: .source)
        case .exportConfiguration:
            try container.encode("export-configuration", forKey: .request)
        case .outputs:
            try container.encode("outputs", forKey: .request)
        case .binds:
            try container.encode("binds", forKey: .request)
        case .action(let action):
            try container.encode("action", forKey: .request)
            try container.encode(action, forKey: .action)
        }
    }
}

public struct ControlOutput: Codable, Equatable, Sendable {
    public var id: OutputID
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var refreshMillihertz: UInt32
    public var scale: Double
    public var x: Int32
    public var y: Int32
    public var enabled: Bool

    public init(
        id: OutputID,
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

public enum ControlErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case ownerUnavailable
    case staleGeneration
    case unauthorized
    case rejected
    case internalTransport
    case unsupportedVersion
}

public struct ControlFailure: Codable, Equatable, Sendable {
    public var code: ControlErrorCode
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlOwnerAvailability: Codable, Equatable, Sendable {
    public var available: Bool
    public var version: String?

    public init(available: Bool, version: String? = nil) {
        self.available = available
        self.version = version
    }
}

public struct ControlVersionInfo: Codable, Equatable, Sendable {
    public var controlProtocolVersion: UInt16
    public var configurationService: ControlOwnerAvailability
    public var renderServer: ControlOwnerAvailability

    public init(
        controlProtocolVersion: UInt16 = ControlProtocolVersion.current,
        configurationService: ControlOwnerAvailability,
        renderServer: ControlOwnerAvailability
    ) {
        self.controlProtocolVersion = controlProtocolVersion
        self.configurationService = configurationService
        self.renderServer = renderServer
    }
}

public struct ControlConfigurationSnapshot: Codable, Equatable, Sendable {
    public var canonicalSource: String
    public var configuredEpochHigh: UInt64
    public var configuredEpochLow: UInt64
    public var configuredGeneration: UInt64
    public var renderServerAppliedGeneration: UInt64?

    public init(
        canonicalSource: String,
        configuredEpochHigh: UInt64,
        configuredEpochLow: UInt64,
        configuredGeneration: UInt64,
        renderServerAppliedGeneration: UInt64?
    ) {
        self.canonicalSource = canonicalSource
        self.configuredEpochHigh = configuredEpochHigh
        self.configuredEpochLow = configuredEpochLow
        self.configuredGeneration = configuredGeneration
        self.renderServerAppliedGeneration = renderServerAppliedGeneration
    }
}

public struct ControlOutputSnapshot: Codable, Equatable, Sendable {
    public var outputs: [ControlOutput]
    public var appliedConfigurationGeneration: UInt64

    public init(
        outputs: [ControlOutput],
        appliedConfigurationGeneration: UInt64
    ) {
        self.outputs = outputs
        self.appliedConfigurationGeneration = appliedConfigurationGeneration
    }
}

public struct ControlBindingSnapshot: Codable, Equatable, Sendable {
    public var binds: [KeyBind]
    public var appliedConfigurationGeneration: UInt64

    public init(
        binds: [KeyBind],
        appliedConfigurationGeneration: UInt64
    ) {
        self.binds = binds
        self.appliedConfigurationGeneration = appliedConfigurationGeneration
    }
}

public enum ControlResponse: Codable, Equatable, Sendable {
    case version(ControlVersionInfo)
    case accepted
    case completed
    case configuration(ControlConfigurationSnapshot)
    case validation([String])
    case outputs(ControlOutputSnapshot)
    case binds(ControlBindingSnapshot)
    case error(ControlFailure)

    private enum CodingKeys: String, CodingKey {
        case response
        case version
        case configuration
        case diagnostics
        case outputs
        case binds
        case errorCode
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .response)
        switch name {
        case "accepted": self = .accepted
        case "completed": self = .completed
        case "version":
            self = .version(try container.decode(
                ControlVersionInfo.self, forKey: .version))
        case "configuration":
            self = .configuration(try container.decode(
                ControlConfigurationSnapshot.self,
                forKey: .configuration))
        case "validation":
            self = .validation(try container.decode(
                [String].self, forKey: .diagnostics))
        case "outputs":
            self = .outputs(try container.decode(
                ControlOutputSnapshot.self, forKey: .outputs))
        case "binds":
            self = .binds(try container.decode(
                ControlBindingSnapshot.self, forKey: .binds))
        case "error":
            self = .error(ControlFailure(
                code: try container.decode(
                    ControlErrorCode.self, forKey: .errorCode),
                message: try container.decode(
                    String.self, forKey: .message)))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.response],
                debugDescription: "unknown response '\(name)'"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted:
            try container.encode("accepted", forKey: .response)
        case .completed:
            try container.encode("completed", forKey: .response)
        case .version(let value):
            try container.encode("version", forKey: .response)
            try container.encode(value, forKey: .version)
        case .configuration(let value):
            try container.encode("configuration", forKey: .response)
            try container.encode(value, forKey: .configuration)
        case .validation(let diagnostics):
            try container.encode("validation", forKey: .response)
            try container.encode(diagnostics, forKey: .diagnostics)
        case .outputs(let value):
            try container.encode("outputs", forKey: .response)
            try container.encode(value, forKey: .outputs)
        case .binds(let value):
            try container.encode("binds", forKey: .response)
            try container.encode(value, forKey: .binds)
        case .error(let failure):
            try container.encode("error", forKey: .response)
            try container.encode(failure.code, forKey: .errorCode)
            try container.encode(failure.message, forKey: .message)
        }
    }
}

public enum ControlCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func packet(_ value: some Encodable) throws -> [UInt8] {
        [UInt8](try encoder().encode(value))
    }
}
