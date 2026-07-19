import NucleusLayers

public enum Appearance: Sendable, Equatable {
    case light
    case dark

    package init(_ appearance: NucleusLayers.Appearance) {
        switch appearance {
        case .light:
            self = .light
        case .dark:
            self = .dark
        }
    }

    package var layersAppearance: NucleusLayers.Appearance {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    @MainActor
    public static var systemDefault: Appearance {
        get { Appearance(NucleusLayers.Appearance.systemDefault) }
        set { NucleusLayers.Appearance.systemDefault = newValue.layersAppearance }
    }
}

public struct Color: Sendable, Equatable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(r: Float, g: Float, b: Float, a: Float) {
        self.init(r, g, b, a)
    }

    package init(_ color: NucleusLayers.Color) {
        self.init(color.r, color.g, color.b, color.a)
    }

    package var layersColor: NucleusLayers.Color {
        .init(r, g, b, a)
    }

    /// Returns this color with its alpha replaced. Mirrors
    /// `NSColor.withAlphaComponent`.
    public func opacity(_ alpha: Float) -> Color {
        Color(r, g, b, alpha)
    }
}

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
        case .label:            return .role(.onSurface)
        case .secondaryLabel:   return .role(.onSurfaceVariant)
        case .tertiaryLabel:    return ColorSpec(role: .onSurface, alpha: 0.56)
        case .quaternaryLabel:  return ColorSpec(role: .onSurface, alpha: 0.15)
        case .separator:        return .role(.outline)
        // Full strength, deliberately. The old values were 0.82 in dark and
        // 0.95 in light — one multiplier cannot serve both, and an accent's
        // strength is the theme's business rather than a constant here. A
        // palette wanting a muted accent gives `primary` that alpha.
        case .accent:           return .role(.primary)
        case .accentLabel:      return .role(.secondary)
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

/// Drop shadow authored by UI code. The layers wire layer receives the
/// converted shadow only at publication / property-write boundaries.
public struct Shadow: Sendable, Equatable {
    public var offsetX: Double
    public var offsetY: Double
    public var blurRadius: Double
    public var cornerRadius: Double
    public var opacity: Double
    public var color: Color

    public init(
        offsetX: Double = 0,
        offsetY: Double = 3,
        blurRadius: Double = 3,
        cornerRadius: Double = 0,
        opacity: Double = 0,
        color: Color = Color(0, 0, 0, 1)
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.color = color
    }

    package init(_ shadow: NucleusLayers.Shadow) {
        self.init(
            offsetX: shadow.offsetX,
            offsetY: shadow.offsetY,
            blurRadius: shadow.blurRadius,
            cornerRadius: shadow.cornerRadius,
            opacity: shadow.opacity,
            color: Color(shadow.color)
        )
    }

    package var layersShadow: NucleusLayers.Shadow {
        .init(
            offsetX: offsetX,
            offsetY: offsetY,
            blurRadius: blurRadius,
            cornerRadius: cornerRadius,
            opacity: opacity,
            color: color.layersColor
        )
    }

    public static let none = Shadow()
}
