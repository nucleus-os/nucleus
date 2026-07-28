public import NucleusConfig
public import NucleusConfigIO
public import NucleusSessionProtocol

public struct ConfigurationServiceSnapshot: Equatable, Sendable {
    public var epoch: ConfigurationServiceEpoch
    public var generation: ConfigurationGeneration
    public var configuration: NucleusConfiguration
    public var diagnostics: [ConfigurationDiagnosticPublication]

    public init(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration,
        configuration: NucleusConfiguration,
        diagnostics: [ConfigurationDiagnosticPublication]
    ) {
        self.epoch = epoch
        self.generation = generation
        self.configuration = configuration
        self.diagnostics = diagnostics
    }

    public func publication(
        for role: ConfigurationSubscriberRole
    ) -> ConfigurationPublication {
        switch role {
        case .renderServer:
            .snapshot(
                epoch: epoch,
                generation: generation,
                configuration: configuration.renderServerProjection,
                diagnostics: diagnostics)
        case .shell:
            .snapshot(
                epoch: epoch,
                generation: generation,
                configuration: configuration.shellProjection,
                diagnostics: diagnostics)
        }
    }
}

public enum ConfigurationServiceUpdate: Sendable {
    case unchanged([ConfigurationDiagnosticPublication])
    case diagnostics([ConfigurationDiagnosticPublication])
    case adopted(ConfigurationServiceSnapshot)
}

/// Pure state machine behind the configuration service process.
///
/// Filesystem and channel ownership stay in the composition root; this type
/// defines generation, last-known-good, validation, and projection semantics.
public struct ConfigurationServiceState: Sendable {
    public private(set) var snapshot: ConfigurationServiceSnapshot

    public init(
        epoch: ConfigurationServiceEpoch,
        startup result: ConfigLoadOutcome
    ) {
        switch result {
        case .loaded(let configuration, let warnings):
            snapshot = ConfigurationServiceSnapshot(
                epoch: epoch,
                generation: ConfigurationGeneration(rawValue: 1),
                configuration: configuration,
                diagnostics: warnings.publications)
        case .failed(let diagnostics):
            snapshot = ConfigurationServiceSnapshot(
                epoch: epoch,
                generation: ConfigurationGeneration(rawValue: 1),
                configuration: .defaults,
                diagnostics: diagnostics.publications)
        }
    }

    public mutating func reload(
        _ result: ConfigLoadOutcome,
        forceGeneration: Bool = false
    ) -> ConfigurationServiceUpdate {
        switch result {
        case .failed(let diagnostics):
            return .diagnostics(diagnostics.publications)
        case .loaded(let configuration, let warnings):
            let publications = warnings.publications
            guard forceGeneration || configuration != snapshot.configuration
            else {
                snapshot.diagnostics = publications
                return .unchanged(publications)
            }
            snapshot = ConfigurationServiceSnapshot(
                epoch: snapshot.epoch,
                generation: ConfigurationGeneration(
                    rawValue: snapshot.generation.rawValue + 1),
                configuration: configuration,
                diagnostics: publications)
            return .adopted(snapshot)
        }
    }

    public mutating func fileRemoved() -> ConfigurationServiceUpdate {
        reload(
            .loaded(.defaults, warnings: []),
            forceGeneration: true)
    }

    public func validate(source: String) -> ConfigurationPublication {
        let diagnostics: [ConfigurationDiagnosticPublication]
        switch ConfigLoader.load(text: source) {
        case .loaded(_, let warnings):
            diagnostics = warnings.publications
        case .failed(let failures):
            diagnostics = failures.publications
        }
        return .validated(
            epoch: snapshot.epoch,
            generation: snapshot.generation,
            diagnostics: diagnostics)
    }

    public func export() throws -> ConfigurationPublication {
        .exported(
            epoch: snapshot.epoch,
            generation: snapshot.generation,
            source: try ConfigExport.json(snapshot.configuration))
    }

    public mutating func replace(
        source: String,
        activeFile: ActiveConfigurationFile
    ) throws -> ConfigurationServiceUpdate {
        let resolved = try activeFile.replace(source: source)
        return reload(resolved, forceGeneration: true)
    }
}

public extension Array where Element == ConfigDiagnostic {
    var publications: [ConfigurationDiagnosticPublication] {
        map {
            ConfigurationDiagnosticPublication(
                severity: $0.severity == .error ? .error : .warning,
                message: $0.message,
                keyPath: $0.keyPath)
        }
    }
}
