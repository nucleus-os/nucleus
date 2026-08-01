import Swift

public enum PaintCommandKind: Swift.Hashable, Swift.Sendable {
    case rect
    case roundedRect
    case image
    /// Arbitrary geometry, with verbs and points in the payload. Subsumes the
    /// former `.line`, which was a second way to say the same thing.
    case path
    case textLayout
    /// Intersect the clip with the payload's path. Scoped by `save`/`restore`;
    /// the canvas is a state machine, so clipping cannot be baked into geometry
    /// the way a transform can.
    case clipPath
    case save
    case restore
}

/// Source-over and the compositing modes the rasterizer's `Paint` already
/// carries. Raw values map directly to the C++ `nucleus::skia::BlendMode`
/// entry point used by `PaintRasterizer`.
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

/// Raw values map directly to the C++ Skia paint-cap entry point.
public enum PaintStrokeCap: Swift.UInt8, Swift.Sendable, Swift.Equatable {
    case butt = 0
    case round = 1
    case square = 2
}

/// Raw values map directly to the C++ Skia paint-join entry point.
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
