// Phase 8.9 — Swift presentation-side semantic state helpers.
//
// The render-server presentation-side semantic surface: the GPU-bound
// `PresentationUpdate`, the timing-template → timing-function mapping, the
// material-rect extraction over an 8.8 `PresentationTransition`, and the
// content-reveal default action. Pure value types + functions; nothing imports
// this yet. The render-server consume/queue plumbing that produces these (ArrayList
// results, pending-animation records) is renderer/animation-owned and co-lands
// with the renderer move (10b).
//
// `TimingFunction` is defined here as its first Swift consumer; it migrates to
// a shared animation file when that subsystem is ported.

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

/// Map a wire timing-template id to its concrete timing function. Mirrors
/// `timingFunction`.
public func timingFunction(_ timing: TimingTemplateId) -> TimingFunction {
    switch timing {
    case .default: return .default
    case .linear: return .linear
    case .easeIn: return .easeIn
    case .easeOut: return .easeOut
    case .easeInEaseOut: return .easeInEaseOut
    }
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

// MARK: - Geometry material extraction

/// A from/to rect pair sampled from a geometry material. Mirrors `GeometryRects`.
public struct GeometryRects: Equatable, Sendable {
    public var from: Rect
    public var to: Rect

    public init(from: Rect, to: Rect) {
        self.from = from
        self.to = to
    }
}

/// The rect carried by a material `from` source, if it is a concrete rect value.
/// Mirrors `rectFromMaterialSource`.
public func rectFromMaterialSource(_ source: MaterialSource) -> Rect? {
    if case .value(.rect(let rect)) = source { return rect }
    return nil
}

/// The rect carried by a material `to` target, if it is a concrete rect value.
/// Mirrors `rectFromMaterialTarget`.
public func rectFromMaterialTarget(_ target: MaterialTarget) -> Rect? {
    if case .value(.rect(let rect)) = target { return rect }
    return nil
}

/// Extract the geometry field's from/to rects from a transition, or `nil` if
/// either side is not a concrete rect. Mirrors `geometryMaterialRects`.
public func geometryMaterialRects(_ trans: PresentationTransition) -> GeometryRects? {
    let material = trans.materials[fieldIndex(.geometry)]
    guard let from = rectFromMaterialSource(material.from),
          let to = rectFromMaterialTarget(material.to) else { return nil }
    return GeometryRects(from: from, to: to)
}

/// The retired `to` side of a transition, handed back when an in-flight
/// transition is retargeted. Mirrors `RetargetSnapshot`.
public struct RetargetSnapshot: Equatable, Sendable {
    public var handle: SnapshotHandle
    public var size: Bounds
    public var position: Point2D
    public var sample: ContentSample
    public var progress: Float

    public init(
        handle: SnapshotHandle,
        size: Bounds,
        position: Point2D,
        sample: ContentSample,
        progress: Float
    ) {
        self.handle = handle
        self.size = size
        self.position = position
        self.sample = sample
        self.progress = progress
    }
}

// MARK: - Content reveal default action

/// Resolved duration + curve for a content-reveal crossfade. Mirrors
/// `ContentRevealParams`.
public struct ContentRevealParams: Equatable, Sendable {
    public var duration: Double
    public var timingFunction: TimingFunction

    public init(duration: Double, timingFunction: TimingFunction) {
        self.duration = duration
        self.timingFunction = timingFunction
    }
}

/// The default content-reveal action (role-independent today): a 0.22s ease-out
/// crossfade. Mirrors `defaultActionForContentReveal`.
public func defaultActionForContentReveal(_ role: LayerRole) -> ContentRevealParams {
    _ = role
    return ContentRevealParams(duration: 0.22, timingFunction: .easeOut)
}
