public import NucleusTypes

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public typealias Point = NucleusTypes.Point
public typealias Size = NucleusTypes.Size
public typealias Rect = NucleusTypes.Rect

public struct EdgeInsets: Equatable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public static let zero = EdgeInsets()

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// A 2D affine transform, row-major `[a c tx; b d ty; 0 0 1]`, using the same
/// six scalar vocabulary as `CGAffineTransform`.
///
/// `GraphicsContext` records geometry in local coordinates and carries this
/// complete transform on each paint operation. The renderer applies it once,
/// after the backing-pixel scale.
public struct AffineTransform: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(
        a: Double = 1, b: Double = 0, c: Double = 0,
        d: Double = 1, tx: Double = 0, ty: Double = 0
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = AffineTransform()

    public var isIdentity: Bool { self == .identity }
    public var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
    }

    public static func translation(x: Double, y: Double) -> AffineTransform {
        AffineTransform(tx: x, ty: y)
    }

    public static func scale(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: x, d: y)
    }

    public static func rotation(degrees: Double) -> AffineTransform {
        let radians = degrees * .pi / 180
        let s = sin(radians)
        let c = cos(radians)
        return AffineTransform(a: c, b: s, c: -s, d: c)
    }

    public func apply(_ point: Point) -> Point {
        Point(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }

    /// `self` applied after `other` — i.e. `other` is the outer transform, so
    /// successive `translateBy`/`scaleBy` calls compose in call order.
    public func concatenating(_ other: AffineTransform) -> AffineTransform {
        AffineTransform(
            a: other.a * a + other.b * c,
            b: other.a * b + other.b * d,
            c: other.c * a + other.d * c,
            d: other.c * b + other.d * d,
            tx: other.tx * a + other.ty * c + tx,
            ty: other.tx * b + other.ty * d + ty)
    }

    public func translated(x: Double, y: Double) -> AffineTransform {
        AffineTransform.translation(x: x, y: y).concatenating(self)
    }

    public func scaled(x: Double, y: Double) -> AffineTransform {
        AffineTransform.scale(x: x, y: y).concatenating(self)
    }

    public func rotated(degrees: Double) -> AffineTransform {
        AffineTransform.rotation(degrees: degrees).concatenating(self)
    }

}
