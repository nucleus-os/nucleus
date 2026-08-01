// Retained-layer geometry and per-node model/presentation state.

// MARK: - Geometry

/// 4×4 transform in Skia's `SkM44` column-major layout (`m[col*4 + row]`).
/// Carried value only here; mapping/concatenation is renderer-side. Mirrors
/// `m44.M44`.
package struct M44: Equatable, Sendable {
    /// 16 floats, column-major. Kept as an array (not a tuple) because Swift
    /// only synthesizes tuple `==` up to arity 6.
    package var m: [Float]

    package init(m: [Float]) { self.m = m }

    package static let identity = M44(m: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])
}

/// Layer logical size. Mirrors `Bounds`.
package struct Bounds: Equatable, Sendable {
    package var w: Float = 0
    package var h: Float = 0

    package init(w: Float = 0, h: Float = 0) {
        self.w = w
        self.h = h
    }
}

/// 2D point. Mirrors `Point2D`. Default anchor is (0.5, 0.5).
package struct Point2D: Equatable, Sendable {
    package var x: Float = 0
    package var y: Float = 0

    package init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }
}

/// Axis-aligned rectangle in the renderer's `Float` coordinate domain.
package struct RenderRect: Equatable, Sendable {
    package var x: Float = 0
    package var y: Float = 0
    package var w: Float = 0
    package var h: Float = 0

    package init(x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Composition-time clip in the renderer's tuple-based Float domain.
package struct RenderClip: Equatable, Sendable {
    package var rect: Float4
    package var radii: Float4
    package var antiAlias: Bool
    /// Row-major 3×3 (`[9]f32`). Array, not a tuple, for `Equatable`.
    package var transform: [Float]

    package init(rect: Float4, radii: Float4, antiAlias: Bool, transform: [Float]) {
        self.rect = rect
        self.radii = radii
        self.antiAlias = antiAlias
        self.transform = transform
    }

    package static func == (lhs: RenderClip, rhs: RenderClip) -> Bool {
        float4Equal(lhs.rect, rhs.rect) && float4Equal(lhs.radii, rhs.radii)
            && lhs.antiAlias == rhs.antiAlias && lhs.transform == rhs.transform
    }
}

// MARK: - Model state (producer side)

/// Producer-authored layer geometry/opacity/clip. Mirrors `ModelProperties`.
package struct ModelProperties: Equatable, Sendable {
    package var position = Point2D()
    package var anchorPoint = Point2D(x: 0.5, y: 0.5)
    package var transform = M44.identity
    package var opacity: Float = 1.0
    package var clip: RenderClip?
    package var bounds = Bounds()
    package var scrollOffset = Point2D()

    package init(
        position: Point2D = Point2D(),
        anchorPoint: Point2D = Point2D(x: 0.5, y: 0.5),
        transform: M44 = M44.identity,
        opacity: Float = 1.0,
        clip: RenderClip? = nil,
        bounds: Bounds = Bounds(),
        scrollOffset: Point2D = Point2D()
    ) {
        self.position = position
        self.anchorPoint = anchorPoint
        self.transform = transform
        self.opacity = opacity
        self.clip = clip
        self.bounds = bounds
        self.scrollOffset = scrollOffset
    }
}

/// Producer-authored retained model state for a node. Mirrors `ModelState`.
package struct ModelState: Equatable, Sendable {
    package var properties = ModelProperties()
    package var visualStyle: VisualStyle?
    /// `none` for pure structural layers; otherwise paint/external/snapshot.
    package var content: LayerContent = .none
    package var visualRevision: UInt64 = 0
    /// Revision of visual state excluding the sampled content identity. This
    /// lets output damage distinguish a localized paint replacement from a
    /// simultaneous geometry/style change that requires old-and-new footprints.
    package var compositeRevision: UInt64 = 0

    package init(
        properties: ModelProperties = ModelProperties(),
        visualStyle: VisualStyle? = nil,
        content: LayerContent = .none,
        visualRevision: UInt64 = 0,
        compositeRevision: UInt64 = 0
    ) {
        self.properties = properties
        self.visualStyle = visualStyle
        self.content = content
        self.visualRevision = visualRevision
        self.compositeRevision = compositeRevision
    }

    /// Releases content back to `none`. Mirrors `ModelState.deinit` (value-type
    /// here, so this is an explicit reset rather than a destructor).
    package mutating func reset() {
        content = .none
    }
}

// MARK: - Presentation state (renderer side)

/// Animation-driven overrides applied over `ModelProperties` at composition
/// time. Each `nil` field falls through to the model. Mirrors
/// `PresentationOverride`.
package struct PresentationOverride: Equatable, Sendable {
    package var transform: M44?
    package var opacity: Float?
    package var position: Point2D?
    package var bounds: Bounds?
    package var anchorPoint: Point2D?
    package var scrollOffset: Point2D?
    /// Uniform corner-radius override applied to all four corners while the
    /// rasterized fill stays based on the model's per-corner radii.
    package var cornerRadiusUniform: Float?

    package init(
        transform: M44? = nil,
        opacity: Float? = nil,
        position: Point2D? = nil,
        bounds: Bounds? = nil,
        anchorPoint: Point2D? = nil,
        scrollOffset: Point2D? = nil,
        cornerRadiusUniform: Float? = nil
    ) {
        self.transform = transform
        self.opacity = opacity
        self.position = position
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.scrollOffset = scrollOffset
        self.cornerRadiusUniform = cornerRadiusUniform
    }
}

/// Whether this layer has a renderable backing yet. Mirrors
/// `PresentationReadiness`.
package enum PresentationReadiness: Sendable {
    case noBacking
    case backingReady
}

/// Pixel source rect + logical size used to sample one side of a presentation
/// transition. Mirrors `ContentSample`.
package struct ContentSample: Equatable, Sendable {
    package var sourceSurfaceId: UInt64 = 0
    package var srcOrigin: (Float, Float) = (0, 0)
    package var srcSize: (Float, Float) = (0, 0)
    package var logicalSize = Bounds()
    package var opaqueFullSurface: Bool = false

    package init(
        sourceSurfaceId: UInt64 = 0,
        srcOrigin: (Float, Float) = (0, 0),
        srcSize: (Float, Float) = (0, 0),
        logicalSize: Bounds = Bounds(),
        opaqueFullSurface: Bool = false
    ) {
        self.sourceSurfaceId = sourceSurfaceId
        self.srcOrigin = srcOrigin
        self.srcSize = srcSize
        self.logicalSize = logicalSize
        self.opaqueFullSurface = opaqueFullSurface
    }

    package static func == (lhs: ContentSample, rhs: ContentSample) -> Bool {
        lhs.sourceSurfaceId == rhs.sourceSurfaceId && lhs.srcOrigin == rhs.srcOrigin
            && lhs.srcSize == rhs.srcSize && lhs.logicalSize == rhs.logicalSize
            && lhs.opaqueFullSurface == rhs.opaqueFullSurface
    }
}

/// One background-effect region rect. Mirrors `BackgroundEffectRect`.
package struct BackgroundEffectRect: Equatable, Sendable {
    package var x: Float = 0
    package var y: Float = 0
    package var w: Float = 0
    package var h: Float = 0

    package init(x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Up to `maxRects` background-effect regions published by the router scene
/// feeder. Mirrors `BackgroundEffectRegions`.
package struct BackgroundEffectRegions: Equatable, Sendable {
    package static let maxRects = 8

    package var rects: [BackgroundEffectRect] = Array(
        repeating: BackgroundEffectRect(), count: maxRects)
    package var count: UInt32 = 0
    package var wholeSurface: Bool = false

    package init(
        rects: [BackgroundEffectRect] = Array(repeating: BackgroundEffectRect(), count: maxRects),
        count: UInt32 = 0,
        wholeSurface: Bool = false
    ) {
        self.rects = rects
        self.count = count
        self.wholeSurface = wholeSurface
    }
}

/// Renderer-authoritative per-node presentation state. Mirrors
/// `PresentationState`.
package struct PresentationState: Equatable, Sendable {
    package var override_: PresentationOverride?
    package var readiness: PresentationReadiness = .noBacking
    /// Renderer-authoritative content mirrored from `model.content`.
    package var content: LayerContent = .none
    package var contentSample = ContentSample()
    package var backgroundEffect: Bool = false
    package var backgroundEffectRegions = BackgroundEffectRegions()

    package init(
        override_: PresentationOverride? = nil,
        readiness: PresentationReadiness = .noBacking,
        content: LayerContent = .none,
        contentSample: ContentSample = ContentSample(),
        backgroundEffect: Bool = false,
        backgroundEffectRegions: BackgroundEffectRegions = BackgroundEffectRegions()
    ) {
        self.override_ = override_
        self.readiness = readiness
        self.content = content
        self.contentSample = contentSample
        self.backgroundEffect = backgroundEffect
        self.backgroundEffectRegions = backgroundEffectRegions
    }
}

// MARK: - Effective accessors (presentation override → model fallback)

/// The `effective*` precedence: each reads
/// the presentation override (set by an in-flight animation) before falling
/// back to the model.
package enum EffectiveLayer: Sendable {
    package static func transform(model: ModelProperties, presentation: PresentationState) -> M44 {
        if let ov = presentation.override_, let t = ov.transform { return t }
        return model.transform
    }

    package static func bounds(model: ModelProperties, presentation: PresentationState) -> Bounds {
        if let ov = presentation.override_, let b = ov.bounds { return b }
        return model.bounds
    }

    package static func position(model: ModelProperties, presentation: PresentationState) -> Point2D
    {
        if let ov = presentation.override_, let p = ov.position { return p }
        return model.position
    }

    package static func anchorPoint(model: ModelProperties, presentation: PresentationState)
        -> Point2D
    {
        if let ov = presentation.override_, let a = ov.anchorPoint { return a }
        return model.anchorPoint
    }

    package static func opacity(model: ModelProperties, presentation: PresentationState) -> Float {
        if let ov = presentation.override_, let o = ov.opacity { return o }
        return model.opacity
    }

    /// Per-corner radii at composition time. The override is uniform-only (one
    /// scalar applied to all four corners); per-corner asymmetry comes from the
    /// model's visual style.
    package static func cornerRadii(model: ModelState, presentation: PresentationState) -> Float4 {
        if let ov = presentation.override_, let r = ov.cornerRadiusUniform {
            return (r, r, r, r)
        }
        if let vs = model.visualStyle { return vs.cornerRadii }
        return (0, 0, 0, 0)
    }
}

// MARK: - Content-sample resolution

/// Resolved sampling geometry for a content texture. Mirrors
/// `ResolvedContentSample`.
package struct ResolvedContentSample: Equatable, Sendable {
    package var srcOrigin: (Float, Float)
    package var srcSize: (Float, Float)
    package var logicalW: Double
    package var logicalH: Double

    package init(
        srcOrigin: (Float, Float), srcSize: (Float, Float), logicalW: Double, logicalH: Double
    ) {
        self.srcOrigin = srcOrigin
        self.srcSize = srcSize
        self.logicalW = logicalW
        self.logicalH = logicalH
    }

    package static func == (lhs: ResolvedContentSample, rhs: ResolvedContentSample) -> Bool {
        lhs.srcOrigin == rhs.srcOrigin && lhs.srcSize == rhs.srcSize && lhs.logicalW == rhs.logicalW
            && lhs.logicalH == rhs.logicalH
    }
}

/// Resolve a `ContentSample` against a texture's pixel dimensions and logical
/// fallbacks: a non-positive source size falls back to the whole texture, and a
/// non-positive logical size falls back to the supplied logical size, then to
/// the source size (min 1). Pure. Mirrors `resolveContentSample`.
package func resolveContentSample(
    _ sample: ContentSample,
    textureWidth: UInt32,
    textureHeight: UInt32,
    fallbackLogicalW: Double,
    fallbackLogicalH: Double
) -> ResolvedContentSample {
    var srcOrigin = sample.srcOrigin
    var srcSize = sample.srcSize
    if srcSize.0 <= 0 || srcSize.1 <= 0 {
        srcOrigin = (0, 0)
        srcSize = (Float(textureWidth), Float(textureHeight))
    }
    var logicalW = Double(sample.logicalSize.w)
    var logicalH = Double(sample.logicalSize.h)
    if logicalW <= 0 { logicalW = fallbackLogicalW }
    if logicalH <= 0 { logicalH = fallbackLogicalH }
    if logicalW <= 0 { logicalW = max(1.0, Double(srcSize.0)) }
    if logicalH <= 0 { logicalH = max(1.0, Double(srcSize.1)) }
    return ResolvedContentSample(
        srcOrigin: srcOrigin, srcSize: srcSize, logicalW: logicalW, logicalH: logicalH)
}
