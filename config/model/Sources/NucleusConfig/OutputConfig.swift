/// Where an output sits in the desktop's logical coordinate space.
public struct OutputPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Per-output configuration.
///
/// Deliberately narrow: it carries only settings the compositor can actually
/// apply today. Mode and transform remain absent — both need renderer work that
/// does not exist — because a settings key that silently does nothing is worse
/// than a missing one: a user who writes it concludes the compositor is broken
/// rather than that the feature is unimplemented.
public struct OutputConfig: Codable, Equatable, Sendable {
    /// Connector name, as `nucleus msg outputs` reports it — `DP-1`, `HDMI-A-1`.
    public var name: String
    /// Fractional scale. Absent means the session default.
    public var scale: Double?
    /// Logical position. Absent means automatic placement, which is a real
    /// choice rather than a missing value, so it stays optional after
    /// resolution too.
    public var position: OutputPosition?
    /// Variable refresh rate. Absent means the compositor's own default, which
    /// drives VRR for fullscreen direct scanout on any capable connector — so
    /// the value that matters most here is an explicit `false`, for a panel
    /// that flickers or shifts brightness under it.
    public var adaptiveSync: Bool?

    public init(
        name: String,
        scale: Double? = nil,
        position: OutputPosition? = nil,
        adaptiveSync: Bool? = nil
    ) {
        self.name = name
        self.scale = scale
        self.position = position
        self.adaptiveSync = adaptiveSync
    }
}

extension Array where Element == OutputConfig {
    /// The entry for a connector, if the file names it.
    public func entry(named name: String) -> OutputConfig? {
        first { $0.name == name }
    }
}
