public import NucleusTypes

// Authored animation properties pass unchanged through the commit stage.
public typealias LayerAnimationKeyPath = NucleusTypes.LayerAnimationKeyPath

/// Animation timing descriptor. Carries one of: linear (no
/// params), cubic-bezier control points, or spring physics parameters —
/// the consumer evaluator switches exhaustively over the enum.
public typealias AnimationCurve = NucleusTypes.AnimationCurve

/// Producer-owned animation value. Associated values prevent a scalar
/// animation from carrying unused geometry and transform storage.
public enum AnimationEndpoint: Sendable, Equatable {
    case scalar(Double)
    case transform(GeometryTransform)

    public static let zero = AnimationEndpoint.scalar(0)
}

/// Cubic-bezier timing function. Apple `CAMediaTimingFunction` layout:
/// two control points in [0, 1] × [0, 1] define the easing curve between
/// (0, 0) and (1, 1). The consumer evaluator solves for `y(t)` per frame.
public struct BezierCurve: Sendable, Equatable {
    public var p1x: Float
    public var p1y: Float
    public var p2x: Float
    public var p2y: Float

    public init(_ p1x: Float, _ p1y: Float, _ p2x: Float, _ p2y: Float) {
        self.p1x = p1x
        self.p1y = p1y
        self.p2x = p2x
        self.p2y = p2y
    }

    public static let linear = BezierCurve(0, 0, 1, 1)
    public static let easeIn = BezierCurve(0.42, 0, 1, 1)
    public static let easeOut = BezierCurve(0, 0, 0.58, 1)
    public static let easeInEaseOut = BezierCurve(0.42, 0, 0.58, 1)
    /// Apple `CAMediaTimingFunction.default` — the implicit-action curve
    /// for unconfigured property writes.
    public static let `default` = BezierCurve(0.25, 0.1, 0.25, 1)
}

/// Spring physics descriptor (Apple `CASpringAnimation` semantics). The
/// consumer evaluator integrates a damped harmonic oscillator each frame
/// and seeds re-targets with the current sampled velocity.
public struct SpringCurve: Sendable, Equatable {
    public var stiffness: Float
    public var damping: Float
    public var mass: Float
    public var initialVelocity: Float

    public init(stiffness: Float, damping: Float, mass: Float = 1, initialVelocity: Float = 0) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        self.initialVelocity = initialVelocity
    }

    /// AppKit-shaped default for an interactive snap-back: stiff but
    /// well-damped, no overshoot.
    public static let snappy = SpringCurve(stiffness: 300, damping: 30)
}

extension AnimationCurve {
    public static func bezier(_ curve: BezierCurve) -> AnimationCurve {
        .bezier(p1x: curve.p1x, p1y: curve.p1y, p2x: curve.p2x, p2y: curve.p2y)
    }

    public static func spring(_ curve: SpringCurve) -> AnimationCurve {
        .spring(
            stiffness: curve.stiffness,
            damping: curve.damping,
            mass: curve.mass,
            initialVelocity: curve.initialVelocity)
    }
}

/// Producer-side animation specification. Keyed by `keyPath`; the
/// consumer reads `from`/`to` against the endpoint case that matches the
/// key path. `curve` selects the per-frame sampling rule (linear,
/// cubic-bezier, or spring physics — all evaluated consumer-side).
public struct Animation: Sendable, Equatable {
    public var id: UInt64
    public var completionToken: UInt64
    public var keyPath: LayerAnimationKeyPath
    public var duration: Double
    public var fromEndpoint: AnimationEndpoint
    public var toEndpoint: AnimationEndpoint
    public var curve: AnimationCurve

    public init(
        id: UInt64 = 0,
        completionToken: UInt64 = 0,
        keyPath: LayerAnimationKeyPath = .opacity,
        duration: Double,
        from: AnimationEndpoint = .zero,
        to: AnimationEndpoint = .zero,
        curve: AnimationCurve = .bezier(.default)
    ) {
        self.id = id
        self.completionToken = completionToken
        self.keyPath = keyPath
        self.duration = duration
        self.fromEndpoint = from
        self.toEndpoint = to
        self.curve = curve
    }

    /// Convenience: scalar animation on a property whose endpoint is
    /// read via `endpoint.scalar` (opacity, corner_radius, scroll_offset_*,
    /// position_*, anchor_point_*, bounds_*, border_*_width).
    public static func scalar(
        keyPath: LayerAnimationKeyPath,
        from: Double,
        to: Double,
        duration: Double,
        curve: AnimationCurve = .bezier(.default),
        id: UInt64 = 0,
        completionToken: UInt64 = 0
    ) -> Animation {
        Animation(
            id: id, completionToken: completionToken,
            keyPath: keyPath, duration: duration,
            from: .scalar(from), to: .scalar(to), curve: curve
        )
    }

    /// Complete 4×4 transform animation. The model transform remains the final
    /// value while the renderer owns the in-flight presentation override.
    public static func transform(
        from: GeometryTransform,
        to: GeometryTransform,
        duration: Double,
        curve: AnimationCurve = .bezier(.default),
        id: UInt64 = 0,
        completionToken: UInt64 = 0
    ) -> Animation {
        Animation(
            id: id,
            completionToken: completionToken,
            keyPath: .transform,
            duration: duration,
            from: .transform(from),
            to: .transform(to),
            curve: curve
        )
    }

}
