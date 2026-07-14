import NucleusTypes

/// Column-major 4×4 affine transform mirroring CALayer `transform`.
/// `m{row}{col}` matches the GPU convention (column-major storage,
/// row-major naming). This is the generated wire type itself; the
/// `.identity` / `.translation` / `.scale` constructors are the relocated
/// conveniences.
public typealias GeometryTransform = NucleusTypes.Transform

extension NucleusTypes.Transform {
    public static let identity = GeometryTransform(m00: 1, m11: 1, m22: 1, m33: 1)

    public static func translation(x: Double, y: Double, z: Double = 0) -> GeometryTransform {
        var t = identity
        t.m30 = x
        t.m31 = y
        t.m32 = z
        return t
    }

    public static func scale(x: Double, y: Double, z: Double = 1) -> GeometryTransform {
        var t = identity
        t.m00 = x
        t.m11 = y
        t.m22 = z
        return t
    }
}
