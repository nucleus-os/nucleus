/// Scale between AppKit-style logical points and backing pixels.
///
/// Public UI APIs stay in points. Producers convert only at explicit
/// platform/host boundaries: inbound compositor frame/input data arrives in
/// backing pixels, while NucleusUI view layout, radii, shadows, and text remain
/// point-space model values.
public struct BackingScaleFactor: Sendable, Equatable {
    public var value: Float

    public static let one = BackingScaleFactor(Float(1))

    public init(_ value: Float) {
        self.value = value > 0 ? value : 1
    }

    public init(_ value: Double) {
        self.init(Float(value))
    }

    public var backingPixelsPerPoint: Float {
        value
    }

    public var singlePixelLength: Double {
        1 / Double(value)
    }

    public func points(fromBackingPixels value: Double) -> Double {
        value / Double(self.value)
    }

    public func points(fromBackingPixels value: Float) -> Float {
        value / self.value
    }

    public func backingPixels(fromPoints value: Double) -> Double {
        value * Double(self.value)
    }

    public func backingPixels(fromPoints value: Float) -> Float {
        value * self.value
    }

    public func points(fromBackingPixels point: Point) -> Point {
        Point(
            x: points(fromBackingPixels: point.x),
            y: points(fromBackingPixels: point.y)
        )
    }

    public func points(fromBackingPixels size: Size) -> Size {
        Size(
            width: points(fromBackingPixels: size.width),
            height: points(fromBackingPixels: size.height)
        )
    }

    public func points(fromBackingPixels rect: Rect) -> Rect {
        Rect(
            origin: points(fromBackingPixels: rect.origin),
            size: points(fromBackingPixels: rect.size)
        )
    }

    public func backingPixels(fromPoints point: Point) -> Point {
        Point(
            x: backingPixels(fromPoints: point.x),
            y: backingPixels(fromPoints: point.y)
        )
    }

    public func backingPixels(fromPoints size: Size) -> Size {
        Size(
            width: backingPixels(fromPoints: size.width),
            height: backingPixels(fromPoints: size.height)
        )
    }

    public func backingPixels(fromPoints rect: Rect) -> Rect {
        Rect(
            origin: backingPixels(fromPoints: rect.origin),
            size: backingPixels(fromPoints: rect.size)
        )
    }
}
