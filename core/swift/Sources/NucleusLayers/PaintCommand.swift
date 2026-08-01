public import NucleusTypes

// `PaintCommandKind` and `PaintCommand` are `NucleusTypes`' own types. The
// domain `PaintCommand` used to be a field-for-field copy whose `.wireValue`
// was an identity map — a duplicate maintained for a wire that does not exist.
// Same treatment `Color` already had.
public typealias PaintCommandKind = NucleusTypes.PaintCommandKind
public typealias PaintCommand = NucleusTypes.PaintCommand
public typealias PaintCommandFlags = NucleusTypes.PaintCommandFlags
public typealias PaintBlendMode = NucleusTypes.PaintBlendMode

// `Color` is the normalized shared render color.
public typealias Color = NucleusTypes.Color
