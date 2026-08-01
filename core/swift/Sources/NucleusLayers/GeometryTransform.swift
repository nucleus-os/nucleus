public import NucleusTypes

/// Column-major 4×4 affine transform mirroring CALayer `transform`.
/// `m{row}{col}` matches the GPU convention (column-major storage,
/// row-major naming).
public typealias GeometryTransform = NucleusTypes.Transform
