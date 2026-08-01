import Swift

public struct Color: Swift.Equatable, Swift.Sendable {
    public let r: Swift.Float
    public let g: Swift.Float
    public let b: Swift.Float
    public let a: Swift.Float

    public init(r: Swift.Float = 0, g: Swift.Float = 0, b: Swift.Float = 0, a: Swift.Float = 0) {
        self.r = Self.normalized(r)
        self.g = Self.normalized(g)
        self.b = Self.normalized(b)
        self.a = Self.normalized(a)
    }

    public init(_ r: Swift.Float, _ g: Swift.Float, _ b: Swift.Float, _ a: Swift.Float) {
        self.init(r: r, g: g, b: b, a: a)
    }

    public func opacity(_ alpha: Swift.Float) -> Color {
        Color(r, g, b, alpha)
    }

    private static func normalized(_ value: Swift.Float) -> Swift.Float {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }
}
