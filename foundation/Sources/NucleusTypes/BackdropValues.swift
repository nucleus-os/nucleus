import Swift

public enum BackdropAppearance: Swift.Sendable {
    case auto
    case light
    case dark
}

public enum BackdropBlendingMode: Swift.Sendable {
    case behindWindow
    case withinWindow
}

public enum BackdropMask: Swift.Sendable {
    case none
    case roundedRect
    case image
}

public enum BackdropMaterialKind: Swift.Sendable {
    case none
    case `default`
    case sidebar
    case hudWindow
    case menu
    case popover
    case titlebar
    case sheet
    case headerView
    case selection
    case underWindowBackground
    case underPageBackground
    case fullScreenUi
    case toolTip
    case windowBackground
    case contentBackground
    case shellOverlay
}

public enum BackdropState: Swift.Sendable {
    case active
    case inactive
    case followsWindowActiveState
}

public enum EffectShape: Swift.Sendable {
    case none
    case rect
    case rrect
}

public struct VisualEffect: Swift.Equatable, Swift.Sendable {
    public let material: BackdropMaterialKind
    public let blendingMode: BackdropBlendingMode
    public let state: BackdropState
    public let appearance: BackdropAppearance
    public let emphasized: Swift.Bool
    public let maskKind: BackdropMask
    public let shapeKind: EffectShape
    public let cornerRadius: Swift.Double
    public let opacity: Swift.Double
    public let tint: NucleusTypes.Color
    public let maskImageHandle: Swift.UInt64
    public let shapeRect: SIMD4<Float>
    public let shapeRadius: SIMD4<Float>

    public init(
        material: BackdropMaterialKind = .none,
        blendingMode: BackdropBlendingMode = .behindWindow,
        state: BackdropState = .active,
        appearance: BackdropAppearance = .auto,
        emphasized: Swift.Bool = false,
        maskKind: BackdropMask = .none,
        shapeKind: EffectShape = .none,
        cornerRadius: Swift.Double = 0,
        opacity: Swift.Double = 0,
        tint: NucleusTypes.Color = NucleusTypes.Color(),
        maskImageHandle: Swift.UInt64 = Swift.UInt64(),
        shapeRect: SIMD4<Float> = SIMD4<Float>(repeating: 0),
        shapeRadius: SIMD4<Float> = SIMD4<Float>(repeating: 0)
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.appearance = appearance
        self.emphasized = emphasized
        self.maskKind = maskKind
        self.shapeKind = shapeKind
        self.cornerRadius = cornerRadius.isFinite ? Swift.max(0, cornerRadius) : 0
        self.opacity = opacity.isFinite ? Swift.min(Swift.max(opacity, 0), 1) : 0
        self.tint = tint
        self.maskImageHandle = maskImageHandle
        self.shapeRect = SIMD4<Float>(
            Self.finite(shapeRect.x),
            Self.finite(shapeRect.y),
            Self.nonnegative(shapeRect.z),
            Self.nonnegative(shapeRect.w))
        self.shapeRadius = SIMD4<Float>(
            Self.nonnegative(shapeRadius.x),
            Self.nonnegative(shapeRadius.y),
            Self.nonnegative(shapeRadius.z),
            Self.nonnegative(shapeRadius.w))
    }

    public func withTint(_ tint: NucleusTypes.Color) -> VisualEffect {
        VisualEffect(
            material: material,
            blendingMode: blendingMode,
            state: state,
            appearance: appearance,
            emphasized: emphasized,
            maskKind: maskKind,
            shapeKind: shapeKind,
            cornerRadius: cornerRadius,
            opacity: opacity,
            tint: tint,
            maskImageHandle: maskImageHandle,
            shapeRect: shapeRect,
            shapeRadius: shapeRadius)
    }

    private static func finite(_ value: Swift.Float) -> Swift.Float {
        value.isFinite ? value : 0
    }

    private static func nonnegative(_ value: Swift.Float) -> Swift.Float {
        value.isFinite ? Swift.max(0, value) : 0
    }
}
