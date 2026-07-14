import NucleusTypes

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

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
