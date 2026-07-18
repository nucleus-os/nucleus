import NucleusTypes

// `PaintCommandKind` and `PaintCommand` are `NucleusTypes`' own types. The
// domain `PaintCommand` used to be a field-for-field copy whose `.wireValue`
// was an identity map — a duplicate maintained for a wire that does not exist.
// Same treatment `Color` already had.
public typealias PaintCommandKind = NucleusTypes.PaintCommandKind
public typealias PaintCommand = NucleusTypes.PaintCommand
public typealias PaintCommandFlags = NucleusTypes.PaintCommandFlags
public typealias PaintBlendMode = NucleusTypes.PaintBlendMode

// `Color` is the generated wire color itself (r/g/b/a: Float, Equatable,
// Sendable). The positional initializer and `opacity(_:)` are the only
// relocated conveniences; the labeled `init(r:g:b:a:)` is already memberwise.
public typealias Color = NucleusTypes.Color

extension NucleusTypes.Color {
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        self.init(r: r, g: g, b: b, a: a)
    }

    /// Returns this color with its alpha replaced. Mirrors
    /// `NSColor.withAlphaComponent`. Used to derive faded variants of a
    /// semantic color (e.g. an accent fill at 0.22 alpha for a status pill)
    /// without introducing per-variant tokens.
    public func opacity(_ alpha: Float) -> Color {
        Color(r, g, b, alpha)
    }
}
