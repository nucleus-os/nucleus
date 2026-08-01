import Foundation
import Glibc
public import NucleusConfig
internal import NucleusIPCTransport

public enum SessionProtocolVersion {
    public static let current: UInt16 = 2
}

/// A fresh identity generated whenever the configuration service starts.
public struct ConfigurationServiceEpoch:
    Codable, Equatable, Hashable, Sendable
{
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

public struct ConfigurationGeneration:
    RawRepresentable, Codable, Hashable, Comparable, Sendable
{
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: ConfigurationGeneration,
        rhs: ConfigurationGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ConfigurationSubscriberRole: String, Codable, Sendable {
    case renderServer
    case shell
}

/// Authority is granted by the supervisor-created channel, not by UID.
public enum ConfigurationCapability: String, Codable, Sendable {
    case renderServerSubscriber
    case shellSubscriber
    case shellSettingsMutation
    case control

    public var subscriberRole: ConfigurationSubscriberRole? {
        switch self {
        case .renderServerSubscriber: .renderServer
        case .shellSubscriber: .shell
        case .shellSettingsMutation, .control: nil
        }
    }
}

public struct ConfigurationSubscriptionRequest:
    Codable, Equatable, Sendable
{
    public enum Operation: String, Codable, Sendable {
        case subscribe
        case currentSnapshot
        case acknowledge
        case reject
        case reload
        case validate
        case replace
        case export
    }

    public var operation: Operation
    public var role: ConfigurationSubscriberRole?
    public var epoch: ConfigurationServiceEpoch?
    public var generation: ConfigurationGeneration?
    public var rejection: String?
    public var source: String?

    public static func subscribe(
        as role: ConfigurationSubscriberRole
    ) -> Self {
        Self(operation: .subscribe, role: role)
    }

    public static let currentSnapshot = Self(operation: .currentSnapshot)

    public static func acknowledge(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) -> Self {
        Self(
            operation: .acknowledge,
            epoch: epoch,
            generation: generation)
    }

    public static func reject(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        reason: String
    ) -> Self {
        Self(
            operation: .reject,
            epoch: epoch,
            generation: generation,
            rejection: reason)
    }

    public static func validate(source: String) -> Self {
        Self(operation: .validate, source: source)
    }

    public static let reload = Self(operation: .reload)

    public static func replace(source: String) -> Self {
        Self(operation: .replace, source: source)
    }

    public static let export = Self(operation: .export)

    private init(
        operation: Operation,
        role: ConfigurationSubscriberRole? = nil,
        epoch: ConfigurationServiceEpoch? = nil,
        generation: ConfigurationGeneration? = nil,
        rejection: String? = nil,
        source: String? = nil
    ) {
        self.operation = operation
        self.role = role
        self.epoch = epoch
        self.generation = generation
        self.rejection = rejection
        self.source = source
    }
}

public struct ConfigurationDiagnosticPublication:
    Codable, Equatable, Sendable
{
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var message: String
    public var keyPath: [String]

    public init(
        severity: Severity,
        message: String,
        keyPath: [String] = []
    ) {
        self.severity = severity
        self.message = message
        self.keyPath = keyPath
    }
}

public enum ConfigurationProjectionKind: String, Codable, Sendable {
    case renderServer
    case shell
}

public struct ConfigurationPublication: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ready
        case snapshot
        case diagnostics
        case validated
        case exported
        case accepted
        case rejected
    }

    public var kind: Kind
    public var epoch: ConfigurationServiceEpoch
    public var generation: ConfigurationGeneration
    public var schemaVersion: Int
    public var projectionKind: ConfigurationProjectionKind?
    public var renderServerConfiguration: RenderServerConfiguration?
    public var shellConfiguration: ShellConfiguration?
    public var diagnostics: [ConfigurationDiagnosticPublication]
    public var exportedSource: String?
    public var rejection: String?

    public static func ready(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        diagnostics: [ConfigurationDiagnosticPublication] = []
    ) -> Self {
        Self(
            kind: .ready,
            epoch: epoch,
            generation: generation,
            diagnostics: diagnostics)
    }

    public static func snapshot(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        configuration: RenderServerConfiguration,
        diagnostics: [ConfigurationDiagnosticPublication] = []
    ) -> Self {
        Self(
            kind: .snapshot,
            epoch: epoch,
            generation: generation,
            projectionKind: .renderServer,
            renderServerConfiguration: configuration,
            diagnostics: diagnostics)
    }

    public static func snapshot(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        configuration: ShellConfiguration,
        diagnostics: [ConfigurationDiagnosticPublication] = []
    ) -> Self {
        Self(
            kind: .snapshot,
            epoch: epoch,
            generation: generation,
            projectionKind: .shell,
            shellConfiguration: configuration,
            diagnostics: diagnostics)
    }

    public static func diagnostics(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        diagnostics: [ConfigurationDiagnosticPublication]
    ) -> Self {
        Self(
            kind: .diagnostics,
            epoch: epoch,
            generation: generation,
            diagnostics: diagnostics)
    }

    public static func validated(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        diagnostics: [ConfigurationDiagnosticPublication]
    ) -> Self {
        Self(
            kind: .validated,
            epoch: epoch,
            generation: generation,
            diagnostics: diagnostics)
    }

    public static func exported(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        source: String
    ) -> Self {
        Self(
            kind: .exported,
            epoch: epoch,
            generation: generation,
            exportedSource: source)
    }

    public static func accepted(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) -> Self {
        Self(kind: .accepted, epoch: epoch, generation: generation)
    }

    public static func rejected(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        reason: String
    ) -> Self {
        Self(
            kind: .rejected,
            epoch: epoch,
            generation: generation,
            rejection: reason)
    }

    private init(
        kind: Kind,
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        schemaVersion: Int = NucleusConfiguration.currentVersion,
        projectionKind: ConfigurationProjectionKind? = nil,
        renderServerConfiguration: RenderServerConfiguration? = nil,
        shellConfiguration: ShellConfiguration? = nil,
        diagnostics: [ConfigurationDiagnosticPublication] = [],
        exportedSource: String? = nil,
        rejection: String? = nil
    ) {
        self.kind = kind
        self.epoch = epoch
        self.generation = generation
        self.schemaVersion = schemaVersion
        self.projectionKind = projectionKind
        self.renderServerConfiguration = renderServerConfiguration
        self.shellConfiguration = shellConfiguration
        self.diagnostics = diagnostics
        self.exportedSource = exportedSource
        self.rejection = rejection
    }
}

public struct ConfigurationSubscriptionEnvelope<Payload>:
    Codable, Equatable, Sendable
where Payload: Codable & Equatable & Sendable {
    public var protocolVersion: UInt16
    public var payload: Payload

    public init(
        protocolVersion: UInt16 = SessionProtocolVersion.current,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.payload = payload
    }
}

public enum ConfigurationSubscriptionCodec {
    public static let maximumMessageBytes = 4 * 1024 * 1024

    public static func encode<Payload>(
        _ envelope: ConfigurationSubscriptionEnvelope<Payload>
    ) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return [UInt8](try encoder.encode(envelope))
    }

    public static func decode<Payload>(
        _ type: Payload.Type,
        from bytes: some Collection<UInt8>
    ) throws -> ConfigurationSubscriptionEnvelope<Payload> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            ConfigurationSubscriptionEnvelope<Payload>.self,
            from: Data(bytes))
    }
}

public enum ConfigurationChannelFailure: Error, CustomStringConvertible {
    case invalidDescriptor(String)
    case invalidProtocolVersion(UInt16)
    case unexpectedPublication

    public var description: String {
        switch self {
        case .invalidDescriptor(let value):
            "invalid configuration service descriptor '\(value)'"
        case .invalidProtocolVersion(let version):
            "unsupported configuration protocol version \(version)"
        case .unexpectedPublication:
            "configuration service sent an unexpected publication"
        }
    }
}

/// One capability-scoped packet channel inherited from the session supervisor.
public final class ConfigurationClientChannel {
    public static let descriptorArgument = "--nucleus-config-service-fd"

    private var descriptor: Int32

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> ConfigurationClientChannel? {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first,
            arguments.indices.contains(index + 1),
            let descriptor = Int32(arguments[index + 1]),
            descriptor >= 3
        else {
            let value =
                indices.first.flatMap { index in
                    arguments.indices.contains(index + 1)
                        ? arguments[index + 1] : nil
                } ?? "<missing>"
            throw ConfigurationChannelFailure.invalidDescriptor(value)
        }
        return ConfigurationClientChannel(descriptor: descriptor)
    }

    public init(descriptor: Int32) {
        precondition(descriptor >= 0)
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { _ = close(descriptor) }
    }

    public var fileDescriptor: Int32 { descriptor }

    public func send(_ request: ConfigurationSubscriptionRequest) throws {
        let bytes = try ConfigurationSubscriptionCodec.encode(
            ConfigurationSubscriptionEnvelope(payload: request))
        try SessionChannel.send(bytes, to: descriptor)
    }

    public func receive() throws -> ConfigurationPublication {
        let bytes = try SessionChannel.receive(
            from: descriptor,
            maximumBytes: ConfigurationSubscriptionCodec.maximumMessageBytes)
        let envelope = try ConfigurationSubscriptionCodec.decode(
            ConfigurationPublication.self,
            from: bytes)
        guard envelope.protocolVersion == SessionProtocolVersion.current else {
            throw ConfigurationChannelFailure.invalidProtocolVersion(
                envelope.protocolVersion)
        }
        return envelope.payload
    }

    public func subscribe(
        as role: ConfigurationSubscriberRole
    ) throws -> ConfigurationPublication {
        try send(.subscribe(as: role))
        let publication = try receive()
        guard publication.kind == .snapshot else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
        return publication
    }

    public func acknowledge(
        _ publication: ConfigurationPublication
    ) throws {
        try send(
            .acknowledge(
                epoch: publication.epoch,
                generation: publication.generation))
        let response = try receive()
        guard response.kind == .accepted,
            response.epoch == publication.epoch,
            response.generation == publication.generation
        else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
    }
}
