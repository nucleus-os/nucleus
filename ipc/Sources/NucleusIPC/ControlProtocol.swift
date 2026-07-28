public import NucleusConfig
import FoundationEssentials

/// The compositor control protocol.
///
/// One typed vocabulary shared by the compositor, the CLI, and anything else
/// that drives a session. Requests carry the same `BindAction` a key binding
/// carries, because "close the focused window" is one operation regardless of
/// whether a keypress or a command asked for it — describing it twice would
/// guarantee the two descriptions drift.
///
/// The wire format is newline-delimited JSON: one request per line, one
/// response per line. That keeps the socket inspectable with `socat` and makes
/// a partial write detectable, which a length-prefixed binary frame would not.
public enum ControlRequest: Codable, Equatable, Sendable {
    /// Liveness plus version, so a client can tell an old compositor from a
    /// missing one.
    case version
    /// Perform an action from the shared vocabulary.
    case action(BindAction)
    /// The resolved configuration currently in force.
    case configuration
    /// Re-read the configuration file now, rather than waiting for a save.
    case reloadConfiguration
    /// Everything known about the attached outputs.
    case outputs
    /// The current binding table.
    case binds

    private enum CodingKeys: String, CodingKey {
        case request
        case action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .request)
        switch name {
        case "version": self = .version
        case "configuration": self = .configuration
        case "reload-configuration": self = .reloadConfiguration
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
        case .version: try container.encode("version", forKey: .request)
        case .configuration:
            try container.encode("configuration", forKey: .request)
        case .reloadConfiguration:
            try container.encode("reload-configuration", forKey: .request)
        case .outputs: try container.encode("outputs", forKey: .request)
        case .binds: try container.encode("binds", forKey: .request)
        case .action(let action):
            try container.encode("action", forKey: .request)
            try container.encode(action, forKey: .action)
        }
    }
}

/// One attached output, as the control protocol reports it.
public struct ControlOutput: Codable, Equatable, Sendable {
    public var name: String
    public var width: UInt32
    public var height: UInt32
    /// Refresh in millihertz, preserving fractional rates like 59.94 Hz that
    /// an integer would round away.
    public var refreshMillihertz: UInt32
    public var scale: Double
    public var x: Int32
    public var y: Int32
    public var enabled: Bool

    public init(
        name: String,
        width: UInt32,
        height: UInt32,
        refreshMillihertz: UInt32,
        scale: Double,
        x: Int32,
        y: Int32,
        enabled: Bool
    ) {
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

public enum ControlResponse: Codable, Equatable, Sendable {
    case version(String)
    /// The request was accepted. Actions that the compositor performs
    /// asynchronously still answer `ok` — it means accepted, not completed.
    case ok
    case configuration(NucleusConfiguration)
    case outputs([ControlOutput])
    case binds([KeyBind])
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case response
        case version
        case configuration
        case outputs
        case binds
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .response)
        switch name {
        case "ok": self = .ok
        case "version":
            self = .version(try container.decode(String.self, forKey: .version))
        case "configuration":
            self = .configuration(try container.decode(
                NucleusConfiguration.self, forKey: .configuration))
        case "outputs":
            self = .outputs(try container.decode(
                [ControlOutput].self, forKey: .outputs))
        case "binds":
            self = .binds(try container.decode([KeyBind].self, forKey: .binds))
        case "error":
            self = .error(try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.response],
                debugDescription: "unknown response '\(name)'"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok: try container.encode("ok", forKey: .response)
        case .version(let value):
            try container.encode("version", forKey: .response)
            try container.encode(value, forKey: .version)
        case .configuration(let value):
            try container.encode("configuration", forKey: .response)
            try container.encode(value, forKey: .configuration)
        case .outputs(let value):
            try container.encode("outputs", forKey: .response)
            try container.encode(value, forKey: .outputs)
        case .binds(let value):
            try container.encode("binds", forKey: .response)
            try container.encode(value, forKey: .binds)
        case .error(let message):
            try container.encode("error", forKey: .response)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Newline-delimited JSON framing, shared by both ends so they cannot disagree.
public enum ControlCoding {
    /// Keys match the configuration file's spelling, so a `configuration`
    /// response can be pasted straight back into `config.json`.
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

    /// Encode one message as a single line, newline included.
    public static func line(_ value: some Encodable) throws -> Data {
        var data = try encoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
