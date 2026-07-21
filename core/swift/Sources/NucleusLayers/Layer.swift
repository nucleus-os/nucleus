import NucleusTypes

public struct LayerID: RawRepresentable, Hashable, Sendable, Equatable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

// The producer-side discriminant enums are wire-owned (the generated
// discriminant enums in NucleusTypes). The composite domain structs below are
// kept (`LayerDescriptor` carries the non-wire `targetContextID` Optional;
// `LayerPropertyUpdate` carries the mask-gated Optional fields), and their
// `.wireValue`/`init(wireValue:)` adapters live in DirectBridge.swift.
public typealias LayerKind = NucleusTypes.LayerKind
public typealias LayerRole = NucleusTypes.LayerRole
public typealias ActionPolicy = NucleusTypes.ActionPolicy
public typealias ForegroundVibrancyMode = NucleusTypes.ForegroundVibrancyMode

public struct LayerDescriptor: Sendable, Equatable {
    public var kind: LayerKind
    public var role: LayerRole
    public var frame: GeometryRect
    public var opacity: Double
    public var isHidden: Bool
    public var backdropMaterial: BackdropMaterial
    public var backdropGroupID: UInt64
    public var shadow: Shadow
    public var targetContextID: ContextID?
    public var initialContent: LayerContent

    public init(
        kind: LayerKind = .container,
        role: LayerRole = .generic,
        frame: GeometryRect = .zero,
        opacity: Double = 1,
        isHidden: Bool = false,
        backdropMaterial: BackdropMaterial = .none,
        backdropGroupID: UInt64 = 0,
        shadow: Shadow = .none,
        targetContextID: ContextID? = nil,
        initialContent: LayerContent = .none
    ) {
        self.kind = kind
        self.role = role
        self.frame = frame
        self.opacity = opacity
        self.isHidden = isHidden
        self.backdropMaterial = backdropMaterial
        self.backdropGroupID = backdropGroupID
        self.shadow = shadow
        self.targetContextID = targetContextID
        self.initialContent = initialContent
    }
}

/// Per-corner radii bundle. One mask bit gates all four. Layered on top
/// of the layer's clip / decoration shape.
public struct CornerRadii: Sendable, Equatable {
    public var tl: Float, tr: Float, br: Float, bl: Float

    public static let zero = CornerRadii(uniform: 0)

    public init(tl: Float, tr: Float, br: Float, bl: Float) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }

    public init(uniform: Float) {
        self.init(tl: uniform, tr: uniform, br: uniform, bl: uniform)
    }
}

public struct ContentSample: Sendable, Equatable {
    public var sourceSurfaceID: UInt64
    public var srcX: Float
    public var srcY: Float
    public var srcWidth: Float
    public var srcHeight: Float
    public var logicalWidth: Float
    public var logicalHeight: Float
    public var opaqueFullSurface: Bool

    public init(
        sourceSurfaceID: UInt64 = 0,
        srcX: Float = 0,
        srcY: Float = 0,
        srcWidth: Float = 0,
        srcHeight: Float = 0,
        logicalWidth: Float = 0,
        logicalHeight: Float = 0,
        opaqueFullSurface: Bool = false
    ) {
        self.sourceSurfaceID = sourceSurfaceID
        self.srcX = srcX
        self.srcY = srcY
        self.srcWidth = srcWidth
        self.srcHeight = srcHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.opaqueFullSurface = opaqueFullSurface
    }
}

public struct BackgroundEffectRect: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float = 0, y: Float = 0, width: Float = 0, height: Float = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct BackgroundEffectRegions: Sendable, Equatable {
    public static let maxRects = 8

    public var rects: [BackgroundEffectRect]
    public var wholeSurface: Bool

    public init(rects: [BackgroundEffectRect] = [], wholeSurface: Bool = false) {
        self.rects = Array(rects.prefix(Self.maxRects))
        self.wholeSurface = wholeSurface
    }
}

/// Sparse property write: each Optional field is "present iff the
/// corresponding mask bit is set". The mask is auto-derived in
/// `wireValue` (see DirectBridge.swift). Compound frame writes are
/// producer-side convenience only and expand to synchronized `position`
/// + `bounds` writes before encoding.
public struct LayerPropertyUpdate: Sendable, Equatable {
    public var opacity: Double?
    public var isHidden: Bool?
    public var actionPolicy: ActionPolicy
    public var foregroundVibrancy: ForegroundVibrancyMode?
    public var backdropMaterial: BackdropMaterial?
    public var backdropGroupID: UInt64?
    public var shadow: Shadow?
    public var position: GeometryPoint?
    public var bounds: GeometrySize?
    public var anchorPoint: GeometryPoint?
    public var scrollOffset: GeometryPoint?
    public var transform: GeometryTransform?
    public var clip: ClipOp?
    public var cornerRadii: CornerRadii?
    public var borderTop: BorderEdge?
    public var borderRight: BorderEdge?
    public var borderBottom: BorderEdge?
    public var borderLeft: BorderEdge?
    public var content: LayerContent?
    /// Layer-local logical region whose pixels changed with `content`.
    ///
    /// `nil` means the complete content bounds. The field is meaningful only
    /// when `content` is present; keeping it on the content update makes damage
    /// a per-layer publication fact rather than metadata baked into a reusable
    /// paint registration.
    public var contentDamage: GeometryRect?
    public var contentSample: ContentSample?
    public var backgroundEffect: Bool?
    public var backgroundEffectRegions: BackgroundEffectRegions?

    public init(
        isHidden: Bool? = nil,
        opacity: Double? = nil,
        backdropMaterial: BackdropMaterial? = nil,
        backdropGroupID: UInt64? = nil,
        shadow: Shadow? = nil,
        actionPolicy: ActionPolicy = .none,
        foregroundVibrancy: ForegroundVibrancyMode? = nil,
        position: GeometryPoint? = nil,
        bounds: GeometrySize? = nil,
        anchorPoint: GeometryPoint? = nil,
        scrollOffset: GeometryPoint? = nil,
        transform: GeometryTransform? = nil,
        clip: ClipOp? = nil,
        cornerRadii: CornerRadii? = nil,
        borderTop: BorderEdge? = nil,
        borderRight: BorderEdge? = nil,
        borderBottom: BorderEdge? = nil,
        borderLeft: BorderEdge? = nil,
        content: LayerContent? = nil,
        contentDamage: GeometryRect? = nil,
        contentSample: ContentSample? = nil,
        backgroundEffect: Bool? = nil,
        backgroundEffectRegions: BackgroundEffectRegions? = nil
    ) {
        self.opacity = opacity
        self.isHidden = isHidden
        self.actionPolicy = actionPolicy
        self.foregroundVibrancy = foregroundVibrancy
        self.backdropMaterial = backdropMaterial
        self.backdropGroupID = backdropGroupID
        self.shadow = shadow
        self.position = position
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.scrollOffset = scrollOffset
        self.transform = transform
        self.clip = clip
        self.cornerRadii = cornerRadii
        self.borderTop = borderTop
        self.borderRight = borderRight
        self.borderBottom = borderBottom
        self.borderLeft = borderLeft
        self.content = content
        self.contentDamage = contentDamage
        self.contentSample = contentSample
        self.backgroundEffect = backgroundEffect
        self.backgroundEffectRegions = backgroundEffectRegions
    }

    /// Producer-side convenience that decomposes a frame rect into a
    /// position + bounds pair. The wire never carries FRAME (Pillar B);
    /// callers reaching for "set the frame" are routed through this.
    public static func decomposedFrame(_ rect: GeometryRect, actionPolicy: ActionPolicy = .none) -> LayerPropertyUpdate {
        LayerPropertyUpdate(
            actionPolicy: actionPolicy,
            position: GeometryPoint(x: rect.x, y: rect.y),
            bounds: GeometrySize(width: rect.width, height: rect.height)
        )
    }
}

public enum LayerMutation: Sendable, Equatable {
    case created(LayerID, LayerDescriptor)
    case inserted(layer: LayerID, parent: LayerID?, index: UInt32)
    case removed(LayerID)
    case detached(LayerID)
    case properties(layer: LayerID, LayerPropertyUpdate)
    case animationAdded(layer: LayerID, Animation)
    case animationRemoved(layer: LayerID, AnimationKeyPath)
}

extension LayerMutation {
    package func retainResourceHandles() {
        switch self {
        case .created(_, let descriptor):
            descriptor.initialContent.retainHandle()
        case .properties(_, let update):
            update.content?.retainHandle()
        case .inserted, .removed, .detached, .animationAdded, .animationRemoved:
            break
        }
    }

    package func releaseResourceHandles() {
        switch self {
        case .created(_, let descriptor):
            descriptor.initialContent.releaseHandle()
        case .properties(_, let update):
            update.content?.releaseHandle()
        case .inserted, .removed, .detached, .animationAdded, .animationRemoved:
            break
        }
    }

    package static func releaseResourceHandles(in mutations: [LayerMutation]) {
        for mutation in mutations {
            mutation.releaseResourceHandles()
        }
    }
}

@MainActor
open class Layer: ~Sendable {
    /// Borrowed owning context.
    ///
    /// The context retains every live layer. A layer must not be used after its
    /// context is released; keeping only a layer reference does not extend the
    /// native commit sink or context lifetime.
    public unowned let context: Context
    public let id: LayerID
    public private(set) var descriptor: LayerDescriptor
    public private(set) weak var parent: Layer?
    public private(set) var sublayers: [Layer]

    package init(context: Context, id: LayerID, descriptor: LayerDescriptor) {
        self.context = context
        self.id = id
        self.descriptor = descriptor
        self.descriptor.initialContent.retainHandle()
        self.sublayers = []
    }

    deinit {
        descriptor.initialContent.releaseHandle()
    }

    public var frame: GeometryRect { descriptor.frame }
    public var opacity: Double { descriptor.opacity }
    public var isHidden: Bool { descriptor.isHidden }

    /// CALayer-style split shadow accessors. Each setter writes the
    /// matching component of the layer's `Shadow` composite and commits a
    /// property update. To set multiple shadow properties atomically, use
    /// `setProperties(.init(shadow: ...))` or batch in a `LayerTransaction`.
    public var shadowColor: Color { descriptor.shadow.color }
    public var shadowOpacity: Double { descriptor.shadow.opacity }
    public var shadowOffset: GeometrySize {
        GeometrySize(
            width: descriptor.shadow.offsetX,
            height: descriptor.shadow.offsetY
        )
    }
    public var shadowRadius: Double { descriptor.shadow.blurRadius }

    public func setShadowColor(_ color: Color) throws(LayerError) {
        try setShadowComponent { $0.color = color }
    }

    public func setShadowOpacity(_ opacity: Double) throws(LayerError) {
        try setShadowComponent { $0.opacity = opacity }
    }

    public func setShadowOffset(_ offset: GeometrySize) throws(LayerError) {
        try setShadowComponent {
            $0.offsetX = offset.width
            $0.offsetY = offset.height
        }
    }

    public func setShadowRadius(_ radius: Double) throws(LayerError) {
        try setShadowComponent { $0.blurRadius = radius }
    }

    private func setShadowComponent(
        _ mutate: (inout Shadow) -> Void
    ) throws(LayerError) {
        var next = descriptor.shadow
        mutate(&next)
        guard next != descriptor.shadow else { return }
        try setProperties(LayerPropertyUpdate(shadow: next))
    }

    public func setProperties(_ properties: LayerPropertyUpdate) throws(LayerError) {
        var transaction = LayerTransaction(context: context)
        try transaction.setProperties(properties, for: self)
        try transaction.commit()
    }

    /// Producer-side convenience: writes `position` + `bounds` in one
    /// transaction so the wire carries only decomposed geometry.
    /// This follows `CALayer`'s frame behavior by expanding into
    /// `position` + `bounds` writes underneath.
    public func setFrame(_ rect: GeometryRect) throws(LayerError) {
        try setProperties(.decomposedFrame(rect))
    }

    @_spi(NucleusCompositor) public func apply(_ properties: LayerPropertyUpdate) {
        // Decomposed position+bounds writes mirror back into the
        // descriptor's `frame` so `Layer.frame` reads still report the
        // producer-authored geometry.
        if let position = properties.position {
            descriptor.frame.x = position.x
            descriptor.frame.y = position.y
        }
        if let bounds = properties.bounds {
            descriptor.frame.width = bounds.width
            descriptor.frame.height = bounds.height
        }
        if let isHidden = properties.isHidden {
            descriptor.isHidden = isHidden
        }
        if let opacity = properties.opacity {
            descriptor.opacity = opacity
        }
        if let backdropMaterial = properties.backdropMaterial {
            descriptor.backdropMaterial = backdropMaterial
        }
        if let backdropGroupID = properties.backdropGroupID {
            descriptor.backdropGroupID = backdropGroupID
        }
        if let shadow = properties.shadow {
            descriptor.shadow = shadow
        }
        if let content = properties.content {
            content.retainHandle()
            descriptor.initialContent.releaseHandle()
            descriptor.initialContent = content
        }
    }

    package func attach(to parent: Layer?, at index: UInt32) {
        detach()
        self.parent = parent
        guard let parent else {
            return
        }
        let clamped = min(Int(index), parent.sublayers.count)
        parent.sublayers.insert(self, at: clamped)
    }

    package func detach() {
        if let parent {
            parent.sublayers.removeAll { $0 === self }
        }
        parent = nil
    }
}
