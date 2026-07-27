/// The complete Nucleus configuration.
///
/// Two parallel shapes, and the split is load-bearing rather than stylistic:
///
/// - `NucleusConfiguration` is what the runtime reads. Every field is present.
/// - `NucleusConfigurationPart` is what a file decodes into. Every field is
///   optional, so a file that sets one setting is valid and says nothing about
///   the rest.
///
/// Synthesized `Decodable` does not apply a property's default for a missing
/// key — it throws `keyNotFound` — so a single struct carrying defaults could
/// not decode a partial file at all. Resolution is therefore a merge, which is
/// also what gives layering (built-in defaults ← file ← runtime override) for
/// free instead of as a retrofit.
public struct NucleusConfiguration: Codable, Equatable, Sendable {
    /// Schema version of the file this was resolved from. Written by the
    /// exporter so a future reader knows which migrations to run.
    public var configVersion: Int
    public var input: InputConfig

    public static let currentVersion = 1

    public static let defaults = NucleusConfiguration(
        configVersion: currentVersion,
        input: .defaults)

    public func applying(_ part: NucleusConfigurationPart) -> NucleusConfiguration {
        NucleusConfiguration(
            configVersion: part.configVersion ?? configVersion,
            input: input.applying(part.input ?? InputConfigPart()))
    }
}

public struct NucleusConfigurationPart: Decodable, Equatable, Sendable {
    public var configVersion: Int?
    public var input: InputConfigPart?

    public init() {}
}
