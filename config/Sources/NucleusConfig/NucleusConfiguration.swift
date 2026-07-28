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
    /// The complete binding table. A file's `binds` replaces this outright
    /// rather than merging, so the file is the whole truth about what is bound.
    public var binds: [KeyBind]
    /// Per-output overrides, keyed by connector name. Empty by default: an
    /// unnamed output takes the session defaults and automatic placement.
    public var outputs: [OutputConfig]

    public static let currentVersion = 1

    public static let defaults = NucleusConfiguration(
        configVersion: currentVersion,
        input: .defaults,
        binds: DefaultBinds.table,
        outputs: [])

    /// The value the unknown-key audit compares against.
    ///
    /// Identical to `defaults` except that every array carries at least one
    /// element. The auditor derives valid keys from a reference value, so an
    /// array that is empty by default would leave its elements unaudited — a
    /// typo inside `outputs` would pass silently. Populating a reference here
    /// rather than in `defaults` keeps the shipped defaults honest while still
    /// deriving the key set from the real types, so it cannot drift.
    static let auditReference = NucleusConfiguration(
        configVersion: currentVersion,
        input: .defaults,
        binds: DefaultBinds.table,
        outputs: [OutputConfig(
            name: "",
            scale: 1,
            position: OutputPosition(x: 0, y: 0))])

    public func applying(_ part: NucleusConfigurationPart) -> NucleusConfiguration {
        NucleusConfiguration(
            configVersion: part.configVersion ?? configVersion,
            input: input.applying(part.input ?? InputConfigPart()),
            binds: part.binds ?? binds,
            outputs: part.outputs ?? outputs)
    }
}

public struct NucleusConfigurationPart: Decodable, Equatable, Sendable {
    public var configVersion: Int?
    public var input: InputConfigPart?
    public var binds: [KeyBind]?
    public var outputs: [OutputConfig]?

    public init() {}
}
