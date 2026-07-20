import Foundation
import NucleusLayers

/// Column-major 4x4 transform used by public view APIs. The layers
/// substrate receives `GeometryTransform` only when view state is published.
public struct Transform: Sendable, Equatable {
    public var m00: Double, m01: Double, m02: Double, m03: Double
    public var m10: Double, m11: Double, m12: Double, m13: Double
    public var m20: Double, m21: Double, m22: Double, m23: Double
    public var m30: Double, m31: Double, m32: Double, m33: Double

    public static let identity = Transform(
        m00: 1, m01: 0, m02: 0, m03: 0,
        m10: 0, m11: 1, m12: 0, m13: 0,
        m20: 0, m21: 0, m22: 1, m23: 0,
        m30: 0, m31: 0, m32: 0, m33: 1
    )

    public var isFinite: Bool {
        m00.isFinite && m01.isFinite && m02.isFinite && m03.isFinite
            && m10.isFinite && m11.isFinite && m12.isFinite && m13.isFinite
            && m20.isFinite && m21.isFinite && m22.isFinite && m23.isFinite
            && m30.isFinite && m31.isFinite && m32.isFinite && m33.isFinite
    }

    public init(
        m00: Double, m01: Double, m02: Double, m03: Double,
        m10: Double, m11: Double, m12: Double, m13: Double,
        m20: Double, m21: Double, m22: Double, m23: Double,
        m30: Double, m31: Double, m32: Double, m33: Double
    ) {
        self.m00 = m00; self.m01 = m01; self.m02 = m02; self.m03 = m03
        self.m10 = m10; self.m11 = m11; self.m12 = m12; self.m13 = m13
        self.m20 = m20; self.m21 = m21; self.m22 = m22; self.m23 = m23
        self.m30 = m30; self.m31 = m31; self.m32 = m32; self.m33 = m33
    }

    public static func translation(x: Double, y: Double, z: Double = 0) -> Transform {
        var t = identity
        t.m30 = x
        t.m31 = y
        t.m32 = z
        return t
    }

    /// A rotation about the Z axis, in the plane the UI lives in.
    ///
    /// Matches `AffineTransform.rotation` so the two agree about which way is
    /// positive — a disagreement there is invisible until something rotates and
    /// hit-tests in opposite directions.
    public static func rotation(radians: Double) -> Transform {
        let c = cos(radians), s = sin(radians)
        var t = identity
        t.m00 = c
        t.m01 = s
        t.m10 = -s
        t.m11 = c
        return t
    }

    public static func scale(x: Double, y: Double, z: Double = 1) -> Transform {
        var t = identity
        t.m00 = x
        t.m11 = y
        t.m22 = z
        return t
    }

    package init(_ transform: NucleusLayers.GeometryTransform) {
        self.init(
            m00: transform.m00, m01: transform.m01, m02: transform.m02, m03: transform.m03,
            m10: transform.m10, m11: transform.m11, m12: transform.m12, m13: transform.m13,
            m20: transform.m20, m21: transform.m21, m22: transform.m22, m23: transform.m23,
            m30: transform.m30, m31: transform.m31, m32: transform.m32, m33: transform.m33
        )
    }

    package var layersTransform: NucleusLayers.GeometryTransform {
        .init(
            m00: m00, m01: m01, m02: m02, m03: m03,
            m10: m10, m11: m11, m12: m12, m13: m13,
            m20: m20, m21: m21, m22: m22, m23: m23,
            m30: m30, m31: m31, m32: m32, m33: m33
        )
    }
}

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
        AffineTransform(a: m00, b: m01, c: m10, d: m11, tx: m30, ty: m31)
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
