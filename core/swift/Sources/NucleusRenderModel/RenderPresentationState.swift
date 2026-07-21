// Shared animation timing and GPU presentation-update value types.

// MARK: - Timing function

/// A cubic-bezier timing curve (two control points; endpoints fixed at 0,0 and
/// 1,1). Mirrors `animation.TimingFunction`.
public struct TimingFunction: Equatable, Sendable {
    public var c1x: Float
    public var c1y: Float
    public var c2x: Float
    public var c2y: Float

    public init(c1x: Float, c1y: Float, c2x: Float, c2y: Float) {
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }

    public static let linear = TimingFunction(c1x: 0, c1y: 0, c2x: 1, c2y: 1)
    public static let easeIn = TimingFunction(c1x: 0.42, c1y: 0, c2x: 1, c2y: 1)
    public static let easeOut = TimingFunction(c1x: 0, c1y: 0, c2x: 0.58, c2y: 1)
    public static let easeInEaseOut = TimingFunction(c1x: 0.42, c1y: 0, c2x: 0.58, c2y: 1)
    public static let `default` = TimingFunction.easeInEaseOut

    /// Evaluate the curve at `t ∈ [0, 1]`: Newton-iterate x(u)=t, then return
    /// y(u). Linear short-circuits. Mirrors `TimingFunction.evaluate`.
    public func evaluate(_ t: Float) -> Float {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        if c1x == 0 && c1y == 0 && c2x == 1 && c2y == 1 { return t }

        var u = t
        for _ in 0..<8 {
            let bx = bezier3(c1x, c2x, u)
            let dx = bezier3Derivative(c1x, c2x, u)
            if abs(dx) < 1e-6 { break }
            u -= (bx - t) / dx
            u = max(0, min(1, u))
        }
        return bezier3(c1y, c2y, u)
    }
}

private func bezier3(_ a: Float, _ b: Float, _ t: Float) -> Float {
    let mt = 1.0 - t
    return 3.0 * a * mt * mt * t + 3.0 * b * mt * t * t + t * t * t
}

private func bezier3Derivative(_ a: Float, _ b: Float, _ t: Float) -> Float {
    let mt = 1.0 - t
    return 3.0 * a * mt * mt + (6.0 * b - 6.0 * a) * mt * t + (3.0 - 3.0 * b) * t * t
}

// MARK: - Presentation update

/// A GPU-side presentation update for one node. Mirrors `PresentationUpdate`.
public enum PresentationUpdate: Equatable, Sendable {
    case set(
        nodeId: UInt64,
        transform: M44?,
        opacity: Float?,
        clipExpansion: Float4?,
        blurOverride: Float?,
        tintOverride: Float4?,
        scrollPresentationOffset: Point2D?)
    case clear(nodeId: UInt64)

    public static func == (lhs: PresentationUpdate, rhs: PresentationUpdate) -> Bool {
        switch (lhs, rhs) {
        case let (.set(an, at, ao, ace, abo, ato, aso), .set(bn, bt, bo, bce, bbo, bto, bso)):
            return an == bn && at == bt && ao == bo &&
                optFloat4Equal(ace, bce) && abo == bbo &&
                optFloat4Equal(ato, bto) && aso == bso
        case let (.clear(a), .clear(b)):
            return a == b
        default:
            return false
        }
    }
}

private func optFloat4Equal(_ a: Float4?, _ b: Float4?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return float4Equal(x, y)
    default: return false
    }
}
