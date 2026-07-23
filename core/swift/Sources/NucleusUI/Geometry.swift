#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif
package import NucleusTypes

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public static let zero = Point(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Whether both coordinates can safely cross the rendering boundary.
    public var isFinite: Bool { x.isFinite && y.isFinite }

    package init(wireValue: NucleusTypes.Point) {
        self.init(x: wireValue.x, y: wireValue.y)
    }

    package var wireValue: NucleusTypes.Point {
        .init(x: x, y: y)
    }
}

public struct Size: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public static let zero = Size(width: 0, height: 0)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Whether both dimensions can safely cross the rendering boundary.
    public var isFinite: Bool { width.isFinite && height.isFinite }

    package init(wireValue: NucleusTypes.Size) {
        self.init(width: wireValue.width, height: wireValue.height)
    }

    package var wireValue: NucleusTypes.Size {
        .init(width: width, height: height)
    }
}

public struct Rect: Equatable, Sendable {
    public var origin: Point
    public var size: Size

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    /// Nucleus treats a rectangle with either nonpositive dimension as empty.
    /// Negative dimensions are not implicitly standardized: accepting both
    /// conventions at different call sites makes bounds and damage ambiguous.
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    /// Whether every component can safely cross the rendering boundary.
    public var isFinite: Bool { origin.isFinite && size.isFinite }

    /// Shrink by `dx` horizontally and `dy` vertically, from both sides.
    /// Negative values grow it, which is how a highlight is drawn *around*
    /// something.
    ///
    /// A rectangle inset past its own size collapses to zero rather than
    /// inverting: a negative width is not a rectangle, and every consumer here
    /// would have to check for one.
    public func insetBy(dx: Double, dy: Double) -> Rect {
        let width = max(0, size.width - dx * 2)
        let height = max(0, size.height - dy * 2)
        return Rect(
            x: origin.x + (size.width - width) / 2,
            y: origin.y + (size.height - height) / 2,
            width: width, height: height)
    }

    /// Inset equally on every side.
    public func insetBy(_ amount: Double) -> Rect {
        insetBy(dx: amount, dy: amount)
    }

    /// The smallest rectangle containing both.
    ///
    /// An empty rectangle is ignored rather than included — a zero-size rect at
    /// the origin would otherwise drag every union back to it.
    public func union(_ other: Rect) -> Rect {
        let selfIsEmpty = !isFinite || isEmpty
        let otherIsEmpty = !other.isFinite || other.isEmpty
        if selfIsEmpty && otherIsEmpty { return .zero }
        if selfIsEmpty { return other }
        if otherIsEmpty { return self }
        let minX = min(origin.x, other.origin.x)
        let minY = min(origin.y, other.origin.y)
        let maxX = max(origin.x + size.width, other.origin.x + other.size.width)
        let maxY = max(origin.y + size.height, other.origin.y + other.size.height)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The four corners, clockwise from the origin. A rectangle under a rotation
    /// is a quadrilateral, and its corners are what survive the mapping.
    public var corners: [Point] {
        [
            origin,
            Point(x: origin.x + size.width, y: origin.y),
            Point(x: origin.x + size.width, y: origin.y + size.height),
            Point(x: origin.x, y: origin.y + size.height),
        ]
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = Point(x: x, y: y)
        self.size = Size(width: width, height: height)
    }

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    package init(wireValue: NucleusTypes.Rect) {
        self.init(x: wireValue.x, y: wireValue.y, width: wireValue.width, height: wireValue.height)
    }

    package var wireValue: NucleusTypes.Rect {
        .init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public func contains(_ point: Point) -> Bool {
        isFinite && !isEmpty && point.isFinite &&
            point.x >= origin.x &&
            point.y >= origin.y &&
            point.x < origin.x + size.width &&
            point.y < origin.y + size.height
    }
}

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
        a.isFinite && b.isFinite && c.isFinite && d.isFinite &&
            tx.isFinite && ty.isFinite
    }

    public static func translation(x: Double, y: Double) -> AffineTransform {
        AffineTransform(tx: x, ty: y)
    }

    public static func scale(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: x, d: y)
    }

    public static func rotation(degrees: Double) -> AffineTransform {
        let radians = degrees * .pi / 180
        let s = sin(radians), c = cos(radians)
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
