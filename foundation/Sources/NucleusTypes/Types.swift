import Swift

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public enum ActionPolicy: Swift.UInt8, Swift.Sendable {
    case none = 0
    case `default` = 1
    case explicit = 2
}

public enum AnimationCurveKind: Swift.UInt32, Swift.Sendable {
    case linear = 0
    case bezier = 1
    case spring = 2
}

public enum AnimationKeyPath: Swift.UInt32, Swift.Sendable {
    case none = 0
    case opacity = 1
    case cornerRadius = 2
    case positionX = 3
    case positionY = 4
    case boundsW = 5
    case boundsH = 6
    case anchorPointX = 7
    case anchorPointY = 8
    case transform = 9
    case scrollOffsetX = 10
    case scrollOffsetY = 11
    case borderTopWidth = 12
    case borderRightWidth = 13
    case borderBottomWidth = 14
    case borderLeftWidth = 15
}

public enum BackdropAppearance: Swift.UInt8, Swift.Sendable {
    case auto = 0
    case light = 1
    case dark = 2
}

public enum BackdropBlendingMode: Swift.UInt32, Swift.Sendable {
    case none = 0
    case behindWindow = 1
    case withinWindow = 2
}

public enum BackdropMask: Swift.UInt8, Swift.Sendable {
    case none = 0
    case roundedRect = 1
    case image = 2
}

public enum BackdropMaterialKind: Swift.UInt32, Swift.Sendable {
    case none = 0
    case `default` = 1
    case sidebar = 2
    case hudWindow = 3
    case menu = 4
    case popover = 5
    case titlebar = 6
    case sheet = 7
    case headerView = 8
    case selection = 9
    case underWindowBackground = 10
    case underPageBackground = 11
    case fullScreenUi = 12
    case toolTip = 13
    case windowBackground = 14
    case contentBackground = 15
    case shellOverlay = 16
}

public enum BackdropState: Swift.UInt32, Swift.Sendable {
    case active = 0
    case inactive = 1
    case followsWindowActiveState = 2
}

public enum EffectShape: Swift.UInt8, Swift.Sendable {
    case none = 0
    case rect = 1
    case rrect = 2
}

public enum ForegroundVibrancyMode: Swift.UInt8, Swift.Sendable {
    case inherit = 0
    case none = 1
    case light = 2
    case dark = 3
}

public enum LayerKind: Swift.UInt32, Swift.Sendable {
    case none = 0
    case container = 1
    case backdrop = 2
    case host = 3
}

public enum LayerRole: Swift.UInt8, Swift.Sendable {
    case generic = 0
    case windowRoot = 1
    case windowContentViewport = 2
    case notification = 3
    case hotkeyOverlay = 4
    case wallpaper = 5
    case dock = 6
}

public enum PaintCommandKind: Swift.UInt32, Swift.Sendable {
    case rect = 0
    case roundedRect = 1
    case image = 2
    /// Arbitrary geometry, with verbs and points in the payload. Subsumes the
    /// former `.line`, which was a second way to say the same thing.
    case path = 3
    case textLayout = 4
    /// Intersect the clip with the payload's path. Scoped by `save`/`restore`;
    /// the canvas is a state machine, so clipping cannot be baked into geometry
    /// the way a transform can.
    case clipPath = 5
    case save = 6
    case restore = 7
}

/// Source-over and the compositing modes the rasterizer's `Paint` already
/// carries. Mirrors `nucleus::skia::BlendMode` one-for-one.
public enum PaintBlendMode: Swift.UInt32, Swift.Sendable {
    case srcOver = 0
    case src = 1
    case multiply = 2
    case screen = 3
    case plus = 4
    case overlay = 5
    case dstIn = 6
    case dstOut = 7
}

public enum PaintStrokeCap: Swift.UInt8, Swift.Sendable, Swift.Equatable {
    case butt = 0
    case round = 1
    case square = 2
}

public enum PaintStrokeJoin: Swift.UInt8, Swift.Sendable, Swift.Equatable {
    case miter = 0
    case round = 1
    case bevel = 2
}

public struct PaintTransform: Swift.Sendable, Swift.Equatable {
    public var a: Swift.Float
    public var b: Swift.Float
    public var c: Swift.Float
    public var d: Swift.Float
    public var tx: Swift.Float
    public var ty: Swift.Float

    public init(
        a: Swift.Float, b: Swift.Float, c: Swift.Float,
        d: Swift.Float, tx: Swift.Float, ty: Swift.Float
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }
}

/// Style/behavior bits on a paint command. `stroke` selects
/// `SkPaint::kStroke_Style` — without it a `strokeWidth` renders as a fill,
/// which is why borders paint solid today.
public struct PaintCommandFlags: Swift.OptionSet, Swift.Sendable {
    public var rawValue: Swift.UInt32
    public init(rawValue: Swift.UInt32) { self.rawValue = rawValue }

    public static let stroke = PaintCommandFlags(rawValue: 1 << 0)
    public static let antialias = PaintCommandFlags(rawValue: 1 << 1)
    public static let evenOddFill = PaintCommandFlags(rawValue: 1 << 2)
    /// Recolour an image draw by its alpha, keeping shape and dropping colour.
    public static let tintImage = PaintCommandFlags(rawValue: 1 << 3)

    /// Stroke cap and join. Absent bits mean the defaults — butt and miter —
    /// which is why neither needs a bit of its own.
    public static let capRound = PaintCommandFlags(rawValue: 1 << 4)
    public static let capSquare = PaintCommandFlags(rawValue: 1 << 5)
    public static let joinRound = PaintCommandFlags(rawValue: 1 << 6)
    public static let joinBevel = PaintCommandFlags(rawValue: 1 << 7)

    /// The command carries its own transform, and its geometry is stated in the
    /// space that transform maps from. Every paint and clip operation authored by
    /// `GraphicsContext` sets this bit, including for the identity matrix, so
    /// geometry and scalar style never take a separate pre-transformed path.
    public static let hasTransform = PaintCommandFlags(rawValue: 1 << 8)

    public static let `default`: PaintCommandFlags = [.antialias]

    public static let known: PaintCommandFlags = [
        .stroke, .antialias, .evenOddFill, .tintImage,
        .capRound, .capSquare, .joinRound, .joinBevel, .hasTransform,
    ]
}

public enum ImplicitActionKeyPath: Swift.UInt8, Swift.Sendable {
    case frame = 1
    case opacity = 2
}

public enum ImplicitActionKind: Swift.UInt8, Swift.Sendable {
    case spring = 1
    case scalar = 2
}

public let rootContextId: Swift.UInt32 = 1
public let shellOverlayContextId: Swift.UInt32 = 62

public struct ImageHandle: Swift.Equatable, Swift.Hashable, Swift.Sendable {
    public let id: Swift.UInt64
    public init(id: Swift.UInt64 = Swift.UInt64()) {
        self.id = id
    }
}

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

public struct PresentReport: Swift.Equatable, Swift.Sendable {
    public var predictedPresentationNs: Swift.UInt64
    public var targetPresentationNs: Swift.UInt64
    public var nextPresentId: Swift.UInt64
    public init(
        predictedPresentationNs: Swift.UInt64 = Swift.UInt64(),
        targetPresentationNs: Swift.UInt64 = Swift.UInt64(),
        nextPresentId: Swift.UInt64 = Swift.UInt64()
    ) {
        self.predictedPresentationNs = predictedPresentationNs
        self.targetPresentationNs = targetPresentationNs
        self.nextPresentId = nextPresentId
    }
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

public struct BorderEdge: Swift.Equatable, Swift.Sendable {
    public var width: Swift.Float
    public var color: NucleusTypes.Color
    public init(width: Swift.Float = 0, color: NucleusTypes.Color = NucleusTypes.Color()) {
        self.width = width
        self.color = color
    }
}

public struct Transform: Swift.Equatable, Swift.Sendable {
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
}

public struct ClipOp: Swift.Equatable, Swift.Sendable {
    public var rect: SIMD4<Float>
    public var radii: SIMD4<Float>
    public var antiAlias: Swift.Bool
    /// Row-major 3×3 transform applied to the clip path.
    public var transform: [Swift.Float]

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

public struct VisualEffect: Swift.Equatable, Swift.Sendable {
    public var material: BackdropMaterialKind
    public var blendingMode: BackdropBlendingMode
    public var state: BackdropState
    public var appearance: BackdropAppearance
    public var emphasized: Swift.Bool
    public var maskKind: BackdropMask
    public var shapeKind: EffectShape
    public var cornerRadius: Swift.Double
    public var opacity: Swift.Double
    public var tint: NucleusTypes.Color
    public var maskImageHandle: Swift.UInt64
    public var shapeRect: SIMD4<Float>
    public var shapeRadius: SIMD4<Float>

    public init(
        material: BackdropMaterialKind = .none,
        blendingMode: BackdropBlendingMode = .none,
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
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.tint = tint
        self.maskImageHandle = maskImageHandle
        self.shapeRect = shapeRect
        self.shapeRadius = shapeRadius
    }
}

public struct Shadow: Swift.Equatable, Swift.Sendable {
    public var offsetX: Swift.Double
    public var offsetY: Swift.Double
    public var blurRadius: Swift.Double
    public var cornerRadius: Swift.Double
    public var opacity: Swift.Double
    public var color: NucleusTypes.Color
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
}

public struct AnimationCurve: Swift.Equatable, Swift.Sendable {
    public var kind: AnimationCurveKind
    public var bezierP1x: Swift.Float
    public var bezierP1y: Swift.Float
    public var bezierP2x: Swift.Float
    public var bezierP2y: Swift.Float
    public var springStiffness: Swift.Float
    public var springDamping: Swift.Float
    public var springMass: Swift.Float
    public var springInitialVelocity: Swift.Float
    public init(
        kind: AnimationCurveKind = .linear,
        bezierP1x: Swift.Float = 0, bezierP1y: Swift.Float = 0, bezierP2x: Swift.Float = 0,
        bezierP2y: Swift.Float = 0, springStiffness: Swift.Float = 0,
        springDamping: Swift.Float = 0, springMass: Swift.Float = 0,
        springInitialVelocity: Swift.Float = 0
    ) {
        self.kind = kind
        self.bezierP1x = bezierP1x
        self.bezierP1y = bezierP1y
        self.bezierP2x = bezierP2x
        self.bezierP2y = bezierP2y
        self.springStiffness = springStiffness
        self.springDamping = springDamping
        self.springMass = springMass
        self.springInitialVelocity = springInitialVelocity
    }
}

public struct AnimationEndpoint: Swift.Equatable, Swift.Sendable {
    public var scalar: Swift.Double
    public var point: NucleusTypes.Point
    public var size: NucleusTypes.Size
    public var rect: NucleusTypes.Rect
    public var transform: NucleusTypes.Transform
    public init(
        scalar: Swift.Double = 0, point: NucleusTypes.Point = NucleusTypes.Point(),
        size: NucleusTypes.Size = NucleusTypes.Size(),
        rect: NucleusTypes.Rect = NucleusTypes.Rect(),
        transform: NucleusTypes.Transform = .identity
    ) {
        self.scalar = scalar
        self.point = point
        self.size = size
        self.rect = rect
        self.transform = transform
    }
}

/// One paint draw command. Passed as a `Span` between Swift modules in the
/// same process — there is no serialization and no second implementation, so
/// `kind` is stored as the enum itself rather than a raw discriminant plus a
/// lossy accessor.
///
/// Variable-length data (path verbs/points, gradient stops, effect uniforms)
/// is not inlined here: it rides a parallel payload blob at
/// `payloadOffset ..< payloadOffset + payloadLength`. That split is by
/// *lifetime* — per-frame data goes in the blob, while stable expensive
/// resources (images, text layouts, compiled SkSL) keep handle registrars.
public struct PaintCommand: Swift.Equatable, Swift.Sendable {
    public var kind: PaintCommandKind
    public var flags: PaintCommandFlags
    public var shading: PaintShading
    public var blend: PaintBlendMode
    public var x: Swift.Float
    public var y: Swift.Float
    public var w: Swift.Float
    public var h: Swift.Float
    public var radius: Swift.Float
    public var strokeWidth: Swift.Float
    public var fontSize: Swift.Float
    public var alpha: Swift.Float
    public var blurSigma: Swift.Float
    public var saturation: Swift.Float
    public var color: NucleusTypes.Color
    public var imageHandle: Swift.UInt64
    public var textLayoutHandle: Swift.UInt64
    public var effectHandle: Swift.UInt64
    public var payloadOffset: Swift.UInt32
    public var payloadLength: Swift.UInt32
    /// An affine transform (a, b, c, d, tx, ty), meaningful only with
    /// `.hasTransform`. Geometry remains local and the renderer composes this
    /// matrix with backing scale.
    public var transformA: Swift.Float
    public var transformB: Swift.Float
    public var transformC: Swift.Float
    public var transformD: Swift.Float
    public var transformTX: Swift.Float
    public var transformTY: Swift.Float

    public init(
        kind: PaintCommandKind,
        flags: PaintCommandFlags = .default,
        shading: PaintShading = .color,
        blend: PaintBlendMode = .srcOver,
        x: Swift.Float = 0, y: Swift.Float = 0, w: Swift.Float = 0, h: Swift.Float = 0,
        radius: Swift.Float = 0, strokeWidth: Swift.Float = 0, fontSize: Swift.Float = 0,
        alpha: Swift.Float = 1, blurSigma: Swift.Float = 0, saturation: Swift.Float = 1,
        color: NucleusTypes.Color = NucleusTypes.Color(r: 1, g: 1, b: 1, a: 1),
        imageHandle: Swift.UInt64 = Swift.UInt64(),
        textLayoutHandle: Swift.UInt64 = Swift.UInt64(),
        effectHandle: Swift.UInt64 = Swift.UInt64(),
        payloadOffset: Swift.UInt32 = 0, payloadLength: Swift.UInt32 = 0,
        transformA: Swift.Float = 1, transformB: Swift.Float = 0,
        transformC: Swift.Float = 0, transformD: Swift.Float = 1,
        transformTX: Swift.Float = 0, transformTY: Swift.Float = 0,
        stroke: Swift.Bool? = nil, antialias: Swift.Bool? = nil,
        evenOddFill: Swift.Bool? = nil, tintsImage: Swift.Bool? = nil,
        strokeCap: PaintStrokeCap? = nil,
        strokeJoin: PaintStrokeJoin? = nil,
        transform: PaintTransform? = nil
    ) {
        self.kind = kind
        self.flags = flags
        self.shading = shading
        self.blend = blend
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.alpha = alpha
        self.blurSigma = blurSigma
        self.saturation = saturation
        self.color = color
        self.imageHandle = imageHandle
        self.textLayoutHandle = textLayoutHandle
        self.effectHandle = effectHandle
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.transformA = transformA
        self.transformB = transformB
        self.transformC = transformC
        self.transformD = transformD
        self.transformTX = transformTX
        self.transformTY = transformTY
        if let stroke { self.stroke = stroke }
        if let antialias { self.antialias = antialias }
        if let evenOddFill { self.evenOddFill = evenOddFill }
        if let tintsImage { self.tintsImage = tintsImage }
        if let strokeCap { self.strokeCap = strokeCap }
        if let strokeJoin { self.strokeJoin = strokeJoin }
        if let transform { self.transform = transform }
    }

    public var stroke: Swift.Bool {
        get { flags.contains(.stroke) }
        set { flags.set(.stroke, to: newValue) }
    }

    public var antialias: Swift.Bool {
        get { flags.contains(.antialias) }
        set { flags.set(.antialias, to: newValue) }
    }

    public var evenOddFill: Swift.Bool {
        get { flags.contains(.evenOddFill) }
        set { flags.set(.evenOddFill, to: newValue) }
    }

    public var tintsImage: Swift.Bool {
        get { flags.contains(.tintImage) }
        set { flags.set(.tintImage, to: newValue) }
    }

    public var strokeCap: PaintStrokeCap {
        get {
            if flags.contains(.capRound) { return .round }
            if flags.contains(.capSquare) { return .square }
            return .butt
        }
        set {
            flags.subtract([.capRound, .capSquare])
            switch newValue {
            case .butt: break
            case .round: flags.insert(.capRound)
            case .square: flags.insert(.capSquare)
            }
        }
    }

    public var strokeJoin: PaintStrokeJoin {
        get {
            if flags.contains(.joinRound) { return .round }
            if flags.contains(.joinBevel) { return .bevel }
            return .miter
        }
        set {
            flags.subtract([.joinRound, .joinBevel])
            switch newValue {
            case .miter: break
            case .round: flags.insert(.joinRound)
            case .bevel: flags.insert(.joinBevel)
            }
        }
    }

    public var transform: PaintTransform? {
        get {
            guard flags.contains(.hasTransform) else { return nil }
            return PaintTransform(
                a: transformA, b: transformB, c: transformC,
                d: transformD, tx: transformTX, ty: transformTY)
        }
        set {
            guard let newValue else {
                flags.remove(.hasTransform)
                return
            }
            flags.insert(.hasTransform)
            transformA = newValue.a
            transformB = newValue.b
            transformC = newValue.c
            transformD = newValue.d
            transformTX = newValue.tx
            transformTY = newValue.ty
        }
    }

    public var hasValidFlags: Swift.Bool {
        flags.subtracting(.known).isEmpty
            && !flags.isSuperset(of: [.capRound, .capSquare])
            && !flags.isSuperset(of: [.joinRound, .joinBevel])
    }

    public func hasValidPayloadRange(count: Swift.Int) -> Swift.Bool {
        guard let offset = Swift.Int(exactly: payloadOffset),
            let length = Swift.Int(exactly: payloadLength)
        else { return false }
        let end = offset.addingReportingOverflow(length)
        return !end.overflow && offset <= count && end.partialValue <= count
    }
}

extension PaintCommandFlags: Swift.Equatable {}

extension PaintCommandFlags {
    fileprivate mutating func set(_ member: PaintCommandFlags, to enabled: Swift.Bool) {
        if enabled { insert(member) } else { remove(member) }
    }
}
