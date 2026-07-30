import FoundationEssentials

public enum SessionCapabilityRestartPolicy:
    String, Codable, Equatable, Sendable
{
    case never
    case onFailure
    case always
}

public enum SessionCapabilityDeclarationFailure:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case invalidProtocolVersion(UInt16)
    case invalidIdentifier
    case invalidExecutable
    case invalidArguments
    case invalidMaximumRestarts
    case invalidShutdownTimeout

    public var description: String {
        switch self {
        case .invalidProtocolVersion(let version):
            "unsupported session capability protocol version \(version)"
        case .invalidIdentifier:
            "session capability identifier is invalid"
        case .invalidExecutable:
            "session capability executable must be an absolute path"
        case .invalidArguments:
            "session capability arguments exceed the protocol bounds"
        case .invalidMaximumRestarts:
            "session capability maximum restarts must be between 0 and 16"
        case .invalidShutdownTimeout:
            "session capability shutdown timeout must be between 1 and 600 seconds"
        }
    }
}

public struct SessionCapabilityDeclaration:
    Codable, Equatable, Sendable
{
    public var protocolVersion: UInt16
    public var identifier: String
    public var executable: String
    public var arguments: [String]
    public var restartPolicy: SessionCapabilityRestartPolicy
    public var maximumRestarts: UInt8
    public var shutdownTimeoutSeconds: UInt16

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        identifier: String,
        executable: String,
        arguments: [String] = [],
        restartPolicy: SessionCapabilityRestartPolicy = .onFailure,
        maximumRestarts: UInt8 = 3,
        shutdownTimeoutSeconds: UInt16 = 10
    ) throws {
        guard protocolVersion == SessionProtocolVersion.current else {
            throw SessionCapabilityDeclarationFailure.invalidProtocolVersion(
                protocolVersion)
        }
        guard Self.validIdentifier(identifier) else {
            throw SessionCapabilityDeclarationFailure.invalidIdentifier
        }
        guard executable.first == "/",
              !executable.contains("\0"),
              executable.utf8.count <= 4_096
        else {
            throw SessionCapabilityDeclarationFailure.invalidExecutable
        }
        guard arguments.count <= 64,
              arguments.allSatisfy({
                  !$0.contains("\0") && $0.utf8.count <= 4_096
              })
        else {
            throw SessionCapabilityDeclarationFailure.invalidArguments
        }
        guard maximumRestarts <= 16 else {
            throw SessionCapabilityDeclarationFailure.invalidMaximumRestarts
        }
        guard (1...600).contains(shutdownTimeoutSeconds) else {
            throw SessionCapabilityDeclarationFailure.invalidShutdownTimeout
        }
        self.protocolVersion = protocolVersion
        self.identifier = identifier
        self.executable = executable
        self.arguments = arguments
        self.restartPolicy = restartPolicy
        self.maximumRestarts = maximumRestarts
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case identifier
        case executable
        case arguments
        case restartPolicy
        case maximumRestarts
        case shutdownTimeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decodeIfPresent(
                UInt16.self, forKey: .protocolVersion)
                ?? SessionProtocolVersion.current,
            identifier: try container.decode(
                String.self, forKey: .identifier),
            executable: try container.decode(
                String.self, forKey: .executable),
            arguments: try container.decodeIfPresent(
                [String].self, forKey: .arguments) ?? [],
            restartPolicy: try container.decodeIfPresent(
                SessionCapabilityRestartPolicy.self,
                forKey: .restartPolicy) ?? .onFailure,
            maximumRestarts: try container.decodeIfPresent(
                UInt8.self, forKey: .maximumRestarts) ?? 3,
            shutdownTimeoutSeconds: try container.decodeIfPresent(
                UInt16.self, forKey: .shutdownTimeoutSeconds) ?? 10)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            byte >= Character("a").asciiValue!
                && byte <= Character("z").asciiValue!
                || byte >= Character("0").asciiValue!
                    && byte <= Character("9").asciiValue!
                || byte == Character(".").asciiValue!
                || byte == Character("-").asciiValue!
        }
    }
}

public enum SessionCapabilityProcess {
    public static let identifierArgument =
        "--nucleus-session-capability-id"
}
