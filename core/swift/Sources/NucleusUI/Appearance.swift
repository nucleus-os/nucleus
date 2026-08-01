public import NucleusTypes

public enum Appearance: Sendable, Equatable {
    case light
    case dark
}

public typealias Color = NucleusTypes.Color

/// Named UI color roles, mirroring `NSColor`'s semantic color tokens.
public enum SemanticColor: Sendable, Equatable {
    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel
    case separator
    case accent
    case accentLabel

    /// The role and alpha this semantic colour stands for.
    ///
    /// `SemanticColor` is AppKit's vocabulary and stays, but it is now a *view*
    /// onto the palette rather than a parallel colour system: a themed palette
    /// retints every existing `SemanticColor` call site for free, and the two
    /// can no longer drift apart.
    ///
    /// The label ramp is `onSurface` at descending alpha, which is what the
    /// hardcoded values already were — 0.92, 0.70, 0.52, 0.14 — expressed as
    /// intent rather than as constants.
    public var spec: ColorSpec {
        switch self {
        case .label: return .role(.onSurface)
        case .secondaryLabel: return .role(.onSurfaceVariant)
        case .tertiaryLabel: return ColorSpec(role: .onSurface, alpha: 0.56)
        case .quaternaryLabel: return ColorSpec(role: .onSurface, alpha: 0.15)
        case .separator: return .role(.outline)
        // Full strength, deliberately. The old values were 0.82 in dark and
        // 0.95 in light — one multiplier cannot serve both, and an accent's
        // strength is the theme's business rather than a constant here. A
        // palette wanting a muted accent gives `primary` that alpha.
        case .accent: return .role(.primary)
        case .accentLabel: return .role(.secondary)
        }
    }

    public func resolve(in palette: Palette) -> Color {
        spec.resolve(in: palette)
    }

    /// Resolve against an appearance's standard palette.
    ///
    /// Kept so call sites that only know a light/dark appearance still work, but
    /// it cannot see a themed palette — prefer `View.resolve(_:)`, which
    /// resolves against the palette the view actually paints under.
    public func resolve(in appearance: Appearance) -> Color {
        spec.resolve(in: Palette.standard(for: appearance))
    }
}

public typealias Shadow = NucleusTypes.Shadow
