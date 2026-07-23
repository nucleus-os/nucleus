public import NucleusTypes

// Geometry value types are the generated wire types themselves: a wire
// `nucleus_point`/`nucleus_size`/`nucleus_rect` already carries the exact
// `Double` fields the producer needs, and the generated structs are
// `Equatable, Sendable`. These typealiases preserve the domain names; the
// `.zero` conveniences are the only relocated logic. No domain↔wire adapter
// remains.

public typealias GeometryPoint = NucleusTypes.Point
public typealias GeometrySize = NucleusTypes.Size
public typealias GeometryRect = NucleusTypes.Rect

extension NucleusTypes.Point {
    public static let zero = NucleusTypes.Point()
}

extension NucleusTypes.Size {
    public static let zero = NucleusTypes.Size()
}

extension NucleusTypes.Rect {
    public static let zero = NucleusTypes.Rect()
}

#if NUCLEUS_LAYERS_PUBLIC_NAMES
public typealias Rect = GeometryRect
public typealias Size = GeometrySize
#endif
