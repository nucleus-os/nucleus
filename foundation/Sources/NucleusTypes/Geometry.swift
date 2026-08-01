import Swift

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public struct Point: Swift.Equatable, Swift.Sendable {
    public var x: Swift.Double
    public var y: Swift.Double
    public init(x: Swift.Double = 0, y: Swift.Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = Point()
    public var isFinite: Swift.Bool { x.isFinite && y.isFinite }
}

public struct Size: Swift.Equatable, Swift.Sendable {
    public var width: Swift.Double
    public var height: Swift.Double
    public init(width: Swift.Double = 0, height: Swift.Double = 0) {
        self.width = width
        self.height = height
    }

    public static let zero = Size()
    public var isFinite: Swift.Bool { width.isFinite && height.isFinite }
}

public struct Rect: Swift.Equatable, Swift.Sendable {
    public var x: Swift.Double
    public var y: Swift.Double
    public var width: Swift.Double
    public var height: Swift.Double
    public init(
        x: Swift.Double = 0, y: Swift.Double = 0, width: Swift.Double = 0, height: Swift.Double = 0
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = Rect()

    public var origin: Point {
        get { Point(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    public var size: Size {
        get { Size(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }

    public var isEmpty: Swift.Bool { width <= 0 || height <= 0 }
    public var isFinite: Swift.Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public func insetBy(dx: Swift.Double, dy: Swift.Double) -> Rect {
        let insetWidth = Swift.max(0, width - dx * 2)
        let insetHeight = Swift.max(0, height - dy * 2)
        return Rect(
            x: x + (width - insetWidth) / 2,
            y: y + (height - insetHeight) / 2,
            width: insetWidth,
            height: insetHeight)
    }

    public func insetBy(_ amount: Swift.Double) -> Rect {
        insetBy(dx: amount, dy: amount)
    }

    public func union(_ other: Rect) -> Rect {
        let selfIsEmpty = !isFinite || isEmpty
        let otherIsEmpty = !other.isFinite || other.isEmpty
        if selfIsEmpty && otherIsEmpty { return .zero }
        if selfIsEmpty { return other }
        if otherIsEmpty { return self }
        let minX = Swift.min(x, other.x)
        let minY = Swift.min(y, other.y)
        let maxX = Swift.max(x + width, other.x + other.width)
        let maxY = Swift.max(y + height, other.y + other.height)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var corners: [Point] {
        [
            origin,
            Point(x: x + width, y: y),
            Point(x: x + width, y: y + height),
            Point(x: x, y: y + height),
        ]
    }

    public func contains(_ point: Point) -> Swift.Bool {
        isFinite && !isEmpty && point.isFinite
            && point.x >= x && point.y >= y
            && point.x < x + width && point.y < y + height
    }
}

public struct Transform: Swift.Equatable, Swift.Sendable {
    public struct AffineProjection: Swift.Equatable, Swift.Sendable {
        public let a: Swift.Double
        public let b: Swift.Double
        public let c: Swift.Double
        public let d: Swift.Double
        public let tx: Swift.Double
        public let ty: Swift.Double

        public init(
            a: Swift.Double, b: Swift.Double, c: Swift.Double,
            d: Swift.Double, tx: Swift.Double, ty: Swift.Double
        ) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.tx = tx
            self.ty = ty
        }
    }

    public var m00: Swift.Double
    public var m01: Swift.Double
    public var m02: Swift.Double
    public var m03: Swift.Double
    public var m10: Swift.Double
    public var m11: Swift.Double
    public var m12: Swift.Double
    public var m13: Swift.Double
    public var m20: Swift.Double
    public var m21: Swift.Double
    public var m22: Swift.Double
    public var m23: Swift.Double
    public var m30: Swift.Double
    public var m31: Swift.Double
    public var m32: Swift.Double
    public var m33: Swift.Double
    public init(
        m00: Swift.Double, m01: Swift.Double, m02: Swift.Double, m03: Swift.Double,
        m10: Swift.Double, m11: Swift.Double, m12: Swift.Double, m13: Swift.Double,
        m20: Swift.Double, m21: Swift.Double, m22: Swift.Double, m23: Swift.Double,
        m30: Swift.Double, m31: Swift.Double, m32: Swift.Double, m33: Swift.Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m03 = m03
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m13 = m13
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
        self.m23 = m23
        self.m30 = m30
        self.m31 = m31
        self.m32 = m32
        self.m33 = m33
    }

    public static let identity = Transform(
        m00: 1, m01: 0, m02: 0, m03: 0,
        m10: 0, m11: 1, m12: 0, m13: 0,
        m20: 0, m21: 0, m22: 1, m23: 0,
        m30: 0, m31: 0, m32: 0, m33: 1)

    public var isFinite: Swift.Bool {
        m00.isFinite && m01.isFinite && m02.isFinite && m03.isFinite
            && m10.isFinite && m11.isFinite && m12.isFinite && m13.isFinite
            && m20.isFinite && m21.isFinite && m22.isFinite && m23.isFinite
            && m30.isFinite && m31.isFinite && m32.isFinite && m33.isFinite
    }

    /// The flattened 2D affine block `(a, b, c, d, tx, ty)`.
    public var affineProjection: AffineProjection {
        AffineProjection(a: m00, b: m01, c: m10, d: m11, tx: m30, ty: m31)
    }

    public static func translation(
        x: Swift.Double, y: Swift.Double, z: Swift.Double = 0
    ) -> Transform {
        var transform = identity
        transform.m30 = x
        transform.m31 = y
        transform.m32 = z
        return transform
    }

    public static func rotation(radians: Swift.Double) -> Transform {
        let cosine = cos(radians)
        let sine = sin(radians)
        var transform = identity
        transform.m00 = cosine
        transform.m01 = sine
        transform.m10 = -sine
        transform.m11 = cosine
        return transform
    }

    public static func scale(
        x: Swift.Double, y: Swift.Double, z: Swift.Double = 1
    ) -> Transform {
        var transform = identity
        transform.m00 = x
        transform.m11 = y
        transform.m22 = z
        return transform
    }

    /// Returns `self × other`: `other` is applied first, then `self`.
    public func concatenating(_ other: Transform) -> Transform {
        let lhs = [
            m00, m01, m02, m03,
            m10, m11, m12, m13,
            m20, m21, m22, m23,
            m30, m31, m32, m33,
        ]
        let rhs = [
            other.m00, other.m01, other.m02, other.m03,
            other.m10, other.m11, other.m12, other.m13,
            other.m20, other.m21, other.m22, other.m23,
            other.m30, other.m31, other.m32, other.m33,
        ]
        var result = [Swift.Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                for index in 0..<4 {
                    result[column * 4 + row] += lhs[index * 4 + row] * rhs[column * 4 + index]
                }
            }
        }
        return Transform(
            m00: result[0], m01: result[1], m02: result[2], m03: result[3],
            m10: result[4], m11: result[5], m12: result[6], m13: result[7],
            m20: result[8], m21: result[9], m22: result[10], m23: result[11],
            m30: result[12], m31: result[13], m32: result[14], m33: result[15]
        )
    }
}
