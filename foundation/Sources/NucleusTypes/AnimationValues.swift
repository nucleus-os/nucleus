import Swift

public enum AnimationCurve: Swift.Equatable, Swift.Sendable {
    case linear
    case bezier(
        p1x: Swift.Float,
        p1y: Swift.Float,
        p2x: Swift.Float,
        p2y: Swift.Float)
    case spring(
        stiffness: Swift.Float,
        damping: Swift.Float,
        mass: Swift.Float,
        initialVelocity: Swift.Float)
}

public enum LayerAnimationKeyPath: Swift.CaseIterable, Swift.Hashable, Swift.Sendable {
    case none
    case opacity
    case cornerRadius
    case positionX
    case positionY
    case boundsW
    case boundsH
    case anchorPointX
    case anchorPointY
    case transform
    case scrollOffsetX
    case scrollOffsetY
    case borderTopWidth
    case borderRightWidth
    case borderBottomWidth
    case borderLeftWidth
}

public enum ImplicitActionKeyPath: Swift.Sendable {
    case frame
    case opacity
}

public enum ImplicitActionKind: Swift.Sendable {
    case spring
    case scalar
}

public struct ImplicitActionRow: Swift.Equatable, Swift.Sendable {
    public var role: LayerRole
    public var keyPath: ImplicitActionKeyPath
    public var kind: ImplicitActionKind
    public var mass: Swift.Float
    public var stiffness: Swift.Float
    public var damping: Swift.Float
    public var duration: Swift.Double
    public var c1x: Swift.Float
    public var c1y: Swift.Float
    public var c2x: Swift.Float
    public var c2y: Swift.Float
    public init(
        role: LayerRole = .generic, keyPath: ImplicitActionKeyPath = .frame,
        kind: ImplicitActionKind = .spring,
        mass: Swift.Float = 0, stiffness: Swift.Float = 0, damping: Swift.Float = 0,
        duration: Swift.Double = 0, c1x: Swift.Float = 0, c1y: Swift.Float = 0,
        c2x: Swift.Float = 0, c2y: Swift.Float = 0
    ) {
        self.role = role
        self.keyPath = keyPath
        self.kind = kind
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
        self.duration = duration
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }
}
