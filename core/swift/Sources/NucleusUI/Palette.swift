/// A named colour slot in a theme.
///
/// The Material-3 role set the reference shell themes against, so a palette
/// authored for one is expressible in the other. Sixteen roles, paired as
/// container/on-container: whatever sits on `surface` is drawn in `onSurface`,
/// and a theme that gets that pairing right stays legible however it is
/// recoloured.
public enum ColorRole: String, Sendable, Equatable, CaseIterable {
    case primary = "primary"
    case onPrimary = "on_primary"
    case secondary = "secondary"
    case onSecondary = "on_secondary"
    case tertiary = "tertiary"
    case onTertiary = "on_tertiary"
    case error = "error"
    case onError = "on_error"
    case surface = "surface"
    case onSurface = "on_surface"
    case surfaceVariant = "surface_variant"
    case onSurfaceVariant = "on_surface_variant"
    case outline = "outline"
    case shadow = "shadow"
    case hover = "hover"
    case onHover = "on_hover"

    /// The snake_case token a serialized theme uses. Themes travel as tokens
    /// rather than as ordinal positions, so adding a role later cannot silently
    /// reinterpret an existing file.
    public var token: String { rawValue }

    public init?(token: String) {
        self.init(rawValue: token)
    }
}

/// A complete set of theme colours.
///
/// Replaceable at runtime — that is the whole point, and what a closed enum of
/// hardcoded values could not do. A user-authored theme is a `Palette`, and so
/// is a palette extracted from a wallpaper.
public struct Palette: Sendable, Equatable {
    public var primary: Color
    public var onPrimary: Color
    public var secondary: Color
    public var onSecondary: Color
    public var tertiary: Color
    public var onTertiary: Color
    public var error: Color
    public var onError: Color
    public var surface: Color
    public var onSurface: Color
    public var surfaceVariant: Color
    public var onSurfaceVariant: Color
    public var outline: Color
    public var shadow: Color
    public var hover: Color
    public var onHover: Color

    public init(
        primary: Color, onPrimary: Color,
        secondary: Color, onSecondary: Color,
        tertiary: Color, onTertiary: Color,
        error: Color, onError: Color,
        surface: Color, onSurface: Color,
        surfaceVariant: Color, onSurfaceVariant: Color,
        outline: Color, shadow: Color,
        hover: Color, onHover: Color
    ) {
        self.primary = primary
        self.onPrimary = onPrimary
        self.secondary = secondary
        self.onSecondary = onSecondary
        self.tertiary = tertiary
        self.onTertiary = onTertiary
        self.error = error
        self.onError = onError
        self.surface = surface
        self.onSurface = onSurface
        self.surfaceVariant = surfaceVariant
        self.onSurfaceVariant = onSurfaceVariant
        self.outline = outline
        self.shadow = shadow
        self.hover = hover
        self.onHover = onHover
    }

    public subscript(role: ColorRole) -> Color {
        get {
            switch role {
            case .primary: return primary
            case .onPrimary: return onPrimary
            case .secondary: return secondary
            case .onSecondary: return onSecondary
            case .tertiary: return tertiary
            case .onTertiary: return onTertiary
            case .error: return error
            case .onError: return onError
            case .surface: return surface
            case .onSurface: return onSurface
            case .surfaceVariant: return surfaceVariant
            case .onSurfaceVariant: return onSurfaceVariant
            case .outline: return outline
            case .shadow: return shadow
            case .hover: return hover
            case .onHover: return onHover
            }
        }
        set {
            switch role {
            case .primary: primary = newValue
            case .onPrimary: onPrimary = newValue
            case .secondary: secondary = newValue
            case .onSecondary: onSecondary = newValue
            case .tertiary: tertiary = newValue
            case .onTertiary: onTertiary = newValue
            case .error: error = newValue
            case .onError: onError = newValue
            case .surface: surface = newValue
            case .onSurface: onSurface = newValue
            case .surfaceVariant: surfaceVariant = newValue
            case .onSurfaceVariant: onSurfaceVariant = newValue
            case .outline: outline = newValue
            case .shadow: shadow = newValue
            case .hover: hover = newValue
            case .onHover: onHover = newValue
            }
        }
    }

    /// Whether this palette reads as light. Derived from the surface rather than
    /// declared, because a caller choosing chrome needs to know what it is
    /// actually drawing onto.
    public var isLight: Bool {
        // Rec. 601 luma, which is the cheap approximation everyone uses for
        // this decision and is accurate enough to pick between two chrome sets.
        let luma = 0.299 * surface.r + 0.587 * surface.g + 0.114 * surface.b
        return luma > 0.5
    }

    /// Interpolate, for cross-fading between themes.
    public static func lerp(_ a: Palette, _ b: Palette, _ t: Double) -> Palette {
        let amount = Float(min(max(0, t), 1))
        var result = a
        for role in ColorRole.allCases {
            result[role] = Color.lerp(a[role], b[role], amount)
        }
        return result
    }
}

extension Color {
    /// Component-wise interpolation. Not gamma-correct — the reference's is not
    /// either, and a cross-fade between two nearby theme colours does not need
    /// it.
    public static func lerp(_ a: Color, _ b: Color, _ t: Float) -> Color {
        let amount = min(max(0, t), 1)
        // Exact at the endpoints. `a + (b - a) * 1` is not `b` in binary
        // floating point, and a finished cross-fade that lands a rounding error
        // away from its target palette would never compare equal to it.
        if amount == 0 { return a }
        if amount == 1 { return b }
        return Color(
            a.r + (b.r - a.r) * amount,
            a.g + (b.g - a.g) * amount,
            a.b + (b.b - a.b) * amount,
            a.a + (b.a - a.a) * amount)
    }
}

// MARK: - Built-ins

extension Palette {
    public static let dark = Palette(
        primary: Color(0.44, 0.96, 0.82, 1.0),
        onPrimary: Color(0.02, 0.16, 0.13, 1.0),
        secondary: Color(0.72, 0.84, 1.0, 1.0),
        onSecondary: Color(0.05, 0.10, 0.20, 1.0),
        tertiary: Color(0.90, 0.76, 1.0, 1.0),
        onTertiary: Color(0.16, 0.07, 0.24, 1.0),
        error: Color(0.95, 0.45, 0.40, 1.0),
        onError: Color(0.20, 0.03, 0.02, 1.0),
        surface: Color(0.05, 0.06, 0.09, 1.0),
        onSurface: Color(1.0, 1.0, 1.0, 0.92),
        surfaceVariant: Color(0.11, 0.12, 0.16, 1.0),
        onSurfaceVariant: Color(0.90, 0.93, 0.96, 0.70),
        outline: Color(1.0, 1.0, 1.0, 0.14),
        shadow: Color(0, 0, 0, 0.55),
        hover: Color(1.0, 1.0, 1.0, 0.10),
        onHover: Color(1.0, 1.0, 1.0, 0.92))

    public static let light = Palette(
        primary: Color(0.18, 0.55, 0.45, 1.0),
        onPrimary: Color(1.0, 1.0, 1.0, 1.0),
        secondary: Color(0.20, 0.40, 0.85, 1.0),
        onSecondary: Color(1.0, 1.0, 1.0, 1.0),
        tertiary: Color(0.45, 0.28, 0.65, 1.0),
        onTertiary: Color(1.0, 1.0, 1.0, 1.0),
        error: Color(0.72, 0.16, 0.14, 1.0),
        onError: Color(1.0, 1.0, 1.0, 1.0),
        surface: Color(0.98, 0.98, 0.99, 1.0),
        onSurface: Color(0.05, 0.05, 0.08, 0.92),
        surfaceVariant: Color(0.92, 0.93, 0.95, 1.0),
        onSurfaceVariant: Color(0.10, 0.10, 0.15, 0.70),
        outline: Color(0.05, 0.05, 0.08, 0.14),
        shadow: Color(0, 0, 0, 0.30),
        hover: Color(0.05, 0.05, 0.08, 0.06),
        onHover: Color(0.05, 0.05, 0.08, 0.92))

    /// The palette used where none has been set.
    public static func standard(for appearance: Appearance) -> Palette {
        appearance == .light ? .light : .dark
    }
}

// MARK: - ColorSpec

/// A colour that is *either* a theme role or a literal, with an alpha
/// multiplier.
///
/// The key abstraction, and what makes retheming work without rebuilding a
/// tree: a view stores the *intent* and resolves it at draw time, so replacing
/// the palette changes what it paints without touching what it holds. A stored
/// `Color` cannot do that — it has already forgotten why it was that colour.
public struct ColorSpec: Sendable, Equatable {
    /// The role to resolve, or `nil` when this is a literal.
    public var role: ColorRole?
    /// Used when `role` is `nil`.
    public var fixed: Color
    /// Multiplies the resolved colour's alpha. Lets one role serve a solid fill
    /// and a faint wash without needing a role for each.
    public var alpha: Float

    public init(role: ColorRole, alpha: Float = 1) {
        self.role = role
        self.fixed = Color(0, 0, 0, 1)
        self.alpha = alpha
    }

    public init(fixed: Color, alpha: Float = 1) {
        self.role = nil
        self.fixed = fixed
        self.alpha = alpha
    }

    public static func role(_ role: ColorRole, alpha: Float = 1) -> ColorSpec {
        ColorSpec(role: role, alpha: alpha)
    }

    public static func fixed(_ color: Color, alpha: Float = 1) -> ColorSpec {
        ColorSpec(fixed: color, alpha: alpha)
    }

    public func resolve(in palette: Palette) -> Color {
        let base = role.map { palette[$0] } ?? fixed
        return alpha == 1 ? base : base.opacity(base.a * alpha)
    }

    /// The same spec at a different alpha, for the very common "this, but
    /// fainter".
    public func opacity(_ alpha: Float) -> ColorSpec {
        var copy = self
        copy.alpha = self.alpha * alpha
        return copy
    }
}
