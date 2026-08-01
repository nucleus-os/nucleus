public import NucleusTypes

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public typealias Transform = NucleusTypes.Transform

extension Transform {
    /// The 2D affine part, as a point mapping.
    ///
    /// A `Transform` is a full 4x4 like `CATransform3D`, but hit testing and
    /// coordinate conversion are 2D questions. Rows and columns beyond the
    /// affine 2D block are ignored: a perspective or depth transform hit-tests
    /// as its flattened shadow, which is wrong in the same way `CALayer`'s
    /// `hitTest` is wrong for perspective, and for the same reason — the
    /// alternative is an unprojection with no obvious answer at z ≠ 0.
    public var affine2D: AffineTransform {
        let projection = affineProjection
        return AffineTransform(
            a: projection.a, b: projection.b,
            c: projection.c, d: projection.d,
            tx: projection.tx, ty: projection.ty)
    }
}

extension AffineTransform {
    /// The inverse, or `nil` when the transform collapses a dimension.
    ///
    /// A zero-determinant transform maps the plane onto a line or a point, and
    /// nothing on the far side maps back — a view scaled to zero is not hittable
    /// anywhere rather than hittable everywhere, which is what a fudged inverse
    /// would produce.
    public func inverted() -> AffineTransform? {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-12 else { return nil }
        let inverseDeterminant = 1 / determinant
        return AffineTransform(
            a: d * inverseDeterminant,
            b: -b * inverseDeterminant,
            c: -c * inverseDeterminant,
            d: a * inverseDeterminant,
            tx: (c * ty - d * tx) * inverseDeterminant,
            ty: (b * tx - a * ty) * inverseDeterminant)
    }
}
