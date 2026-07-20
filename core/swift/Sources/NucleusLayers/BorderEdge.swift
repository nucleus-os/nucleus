import NucleusTypes

/// One edge of a layer's border. Corresponds to the per-edge subset of CSS
/// `border-{top|right|bottom|left}`. Width is in points; color carries its
/// own alpha. A zero-width edge contributes nothing to the rendered stroke.
///
/// This is the generated wire type itself (`width: Float`, `color: Color`);
/// `.none` is the only relocated convenience.
public typealias BorderEdge = NucleusTypes.BorderEdge

extension NucleusTypes.BorderEdge {
    public static let none = BorderEdge(width: 0, color: Color(0, 0, 0, 0))
}
