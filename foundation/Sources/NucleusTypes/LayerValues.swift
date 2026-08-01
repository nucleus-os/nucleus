import Swift

public enum ActionPolicy: Swift.Sendable {
    case none
    case `default`
    case explicit
}

public enum ForegroundVibrancyMode: Swift.Sendable {
    case inherit
    case none
    case light
    case dark
}

public enum LayerKind: Swift.Sendable {
    case none
    case container
    case backdrop
    case host
}

/// Raw values are the dense indices used by `RenderImplicitActionTable`.
public enum LayerRole: Swift.UInt8, Swift.Sendable {
    case generic = 0
    case windowRoot = 1
    case windowContentViewport = 2
    case notification = 3
    case hotkeyOverlay = 4
    case wallpaper = 5
    case dock = 6
}

public struct BorderEdge: Swift.Equatable, Swift.Sendable {
    public var width: Swift.Float
    public var color: NucleusTypes.Color
    public init(width: Swift.Float = 0, color: NucleusTypes.Color = NucleusTypes.Color()) {
        self.width = width
        self.color = color
    }
}

public struct ClipOp: Swift.Equatable, Swift.Sendable {
    public let rect: SIMD4<Float>
    public let radii: SIMD4<Float>
    public let antiAlias: Swift.Bool
    /// Row-major 3×3 transform applied to the clip path.
    public let transform: [Swift.Float]

    public init(
        rect: SIMD4<Float> = SIMD4<Float>(repeating: 0),
        radii: SIMD4<Float> = SIMD4<Float>(repeating: 0),
        antiAlias: Swift.Bool = false,
        transform: [Swift.Float] = [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        ]
    ) {
        precondition(transform.count == 9, "clip transform must contain nine elements")
        self.rect = rect
        self.radii = radii
        self.antiAlias = antiAlias
        self.transform = transform
    }
}

public struct Shadow: Swift.Equatable, Swift.Sendable {
    public let offsetX: Swift.Double
    public let offsetY: Swift.Double
    public let blurRadius: Swift.Double
    public let cornerRadius: Swift.Double
    public let opacity: Swift.Double
    public let color: NucleusTypes.Color
    public init(
        offsetX: Swift.Double = 0, offsetY: Swift.Double = 3, blurRadius: Swift.Double = 3,
        cornerRadius: Swift.Double = 0, opacity: Swift.Double = 0,
        color: NucleusTypes.Color = NucleusTypes.Color(0, 0, 0, 1)
    ) {
        self.offsetX = offsetX.isFinite ? offsetX : 0
        self.offsetY = offsetY.isFinite ? offsetY : 0
        self.blurRadius = blurRadius.isFinite ? Swift.max(0, blurRadius) : 0
        self.cornerRadius = cornerRadius.isFinite ? Swift.max(0, cornerRadius) : 0
        self.opacity = opacity.isFinite ? Swift.min(Swift.max(opacity, 0), 1) : 0
        self.color = color
    }

    public static let none = Shadow()

    public func withColor(_ color: NucleusTypes.Color) -> Shadow {
        Shadow(
            offsetX: offsetX, offsetY: offsetY, blurRadius: blurRadius,
            cornerRadius: cornerRadius, opacity: opacity, color: color)
    }

    public func withOpacity(_ opacity: Swift.Double) -> Shadow {
        Shadow(
            offsetX: offsetX, offsetY: offsetY, blurRadius: blurRadius,
            cornerRadius: cornerRadius, opacity: opacity, color: color)
    }

    public func withOffset(x: Swift.Double, y: Swift.Double) -> Shadow {
        Shadow(
            offsetX: x, offsetY: y, blurRadius: blurRadius,
            cornerRadius: cornerRadius, opacity: opacity, color: color)
    }

    public func withBlurRadius(_ blurRadius: Swift.Double) -> Shadow {
        Shadow(
            offsetX: offsetX, offsetY: offsetY, blurRadius: blurRadius,
            cornerRadius: cornerRadius, opacity: opacity, color: color)
    }
}
