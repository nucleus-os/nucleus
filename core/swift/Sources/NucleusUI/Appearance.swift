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

    public func resolve(in appearance: Appearance) -> Color {
        switch (self, appearance) {
        case (.label, .dark):            Color(1.0, 1.0, 1.0, 0.92)
        case (.secondaryLabel, .dark):   Color(0.90, 0.93, 0.96, 0.70)
        case (.tertiaryLabel, .dark):    Color(1.0, 1.0, 1.0, 0.52)
        case (.quaternaryLabel, .dark):  Color(1.0, 1.0, 1.0, 0.14)
        case (.separator, .dark):        Color(1.0, 1.0, 1.0, 0.14)
        case (.accent, .dark):           Color(0.44, 0.96, 0.82, 0.82)
        case (.accentLabel, .dark):      Color(0.72, 0.84, 1.0, 0.96)
        case (.label, .light):           Color(0.05, 0.05, 0.08, 0.92)
        case (.secondaryLabel, .light):  Color(0.10, 0.10, 0.15, 0.70)
        case (.tertiaryLabel, .light):   Color(0.05, 0.05, 0.08, 0.52)
        case (.quaternaryLabel, .light): Color(0.05, 0.05, 0.08, 0.14)
        case (.separator, .light):       Color(0.05, 0.05, 0.08, 0.14)
        case (.accent, .light):          Color(0.18, 0.55, 0.45, 0.95)
        case (.accentLabel, .light):     Color(0.20, 0.40, 0.85, 0.96)
        }
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
