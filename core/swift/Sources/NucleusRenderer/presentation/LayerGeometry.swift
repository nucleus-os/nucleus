// Pure functions over retained layer-model state + per-output target metadata:
// the local→world matrix, world-rect mapping, rounded-clip accumulation down
// the tree, and logical→target-physical projection. Shared by the
// emit/damage walkers and hit-testing. No mutation, no allocation.

/// Per-output composition target. The renderer and damage walker are
/// parameterized by this; each output derives its own from its Display.
/// Mirrors `RenderTarget`.
internal import NucleusRenderModel
internal import struct NucleusTypes.Rect

struct RenderTarget {
    var outputId: DisplayID
    var logicalRect: LogicalRect
    var pixelSize: PixelSize
    var scale: Float
    var fractionalScale: Double
    var overlayUsableArea: UsableArea
}

/// Accumulated rounded clip: the intersection rect plus the per-corner radii of
/// the innermost rounded ancestor clip (world-logical, already bounds-scaled).
/// All-zero radii mean a plain rectangular clip. Mirrors `RoundedClip`.
struct RoundedClip: Equatable {
    var rect: LogicalRect
    var radii: Float4 = (0, 0, 0, 0)

    static func == (lhs: RoundedClip, rhs: RoundedClip) -> Bool {
        lhs.rect == rhs.rect && float4Equal(lhs.radii, rhs.radii)
    }
}

/// Accumulated clip state as the walker descends. Mirrors `ClipState`.
enum ClipState {
    case none
    case rect(RoundedClip)
    case empty
}

/// Layer-local → world transform. Reads through `effective*` getters so
/// in-flight animation overrides drive the world matrix. Mirrors
/// `layerLocalMatrix`.
func layerLocalMatrix(_ layer: Layer) -> M44 {
    let bounds = layer.effectiveBounds()
    return ComposeHelpers.localCompositionMatrix(
        position: layer.effectivePosition(),
        anchorPoint: layer.effectiveAnchorPoint(),
        transform: layer.model.properties.transform,
        presentationTransform: layer.presentation.override_?.transform,
        width: bounds.w,
        height: bounds.h)
}

/// The matrix children compose against: the layer's own world matrix, shifted
/// by its scroll offset.
///
/// The offset applies to children and not to the layer's own content, borders,
/// or shadow — a scrolling view's frame and chrome stay put while what it
/// contains moves. This is the one place scrolling exists in the renderer: a
/// scroll is a property update on one layer, and no descendant re-records.
func layerContentMatrix(_ worldMatrix: M44, _ layer: Layer) -> M44 {
    let scroll = layer.effectiveScrollOffset()
    guard scroll.x != 0 || scroll.y != 0 else { return worldMatrix }
    return worldMatrix.concat(M44.translate(-scroll.x, -scroll.y, 0))
}

/// Map a layer's local bounds-rect into world logical space. Mirrors
/// `mappedLogicalRect`.
func mappedLogicalRect(_ worldMatrix: M44, _ bounds: Bounds) -> LogicalRect {
    let mapped = worldMatrix.mapRect(0, 0, bounds.w, bounds.h)
    return LogicalRect(x: Double(mapped.x), y: Double(mapped.y),
                       width: Double(mapped.w), height: Double(mapped.h))
}

/// Intersection of two logical rects; nil if degenerate. Mirrors
/// `intersectLogicalRects`.
func intersectLogicalRects(_ a: LogicalRect, _ b: LogicalRect) -> LogicalRect? {
    let x0 = max(a.x, b.x)
    let y0 = max(a.y, b.y)
    let x1 = min(a.maxX, b.maxX)
    let y1 = min(a.maxY, b.maxY)
    if x1 <= x0 || y1 <= y0 { return nil }
    return LogicalRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// Signed area of the intersection of two logical rects (0 if disjoint).
/// Mirrors `rectIntersectionArea`.
func rectIntersectionArea(_ a: LogicalRect, _ b: LogicalRect) -> Double {
    let left = max(a.x, b.x)
    let top = max(a.y, b.y)
    let right = min(a.maxX, b.maxX)
    let bottom = min(a.maxY, b.maxY)
    if right <= left || bottom <= top { return 0 }
    return (right - left) * (bottom - top)
}

/// World-space rounded clip of a layer's own clip, if set. Mirrors
/// `layerClipRect`.
func layerClipRect(_ layer: Layer, _ worldMatrix: M44) -> RoundedClip? {
    guard let clip = ComposeHelpers.scaledClipForBounds(
        clip: layer.model.properties.clip,
        modelBounds: layer.model.properties.bounds,
        effectiveBounds: layer.effectiveBounds()) else { return nil }
    let clipMatrix = worldMatrix.concat(M44.from3x3(clip.transform))
    let mapped = clipMatrix.mapRect(clip.rect.0, clip.rect.1, clip.rect.2, clip.rect.3)
    return RoundedClip(
        rect: LogicalRect(x: Double(mapped.x), y: Double(mapped.y),
                          width: Double(mapped.w), height: Double(mapped.h)),
        radii: clip.radii)
}

/// Fold `layer`'s local clip into the inherited parent clip. An empty result
/// propagates. The tighter (innermost) rounded clip's radii win. Mirrors
/// `accumulateClip`.
func accumulateClip(_ parentClip: ClipState, _ layer: Layer, _ worldMatrix: M44) -> ClipState {
    let localClip = layerClipRect(layer, worldMatrix)
    switch parentClip {
    case .empty:
        return .empty
    case .none:
        if let clip = localClip { return .rect(clip) }
        return .none
    case .rect(let parent):
        guard let clip = localClip else { return .rect(parent) }
        if let merged = intersectLogicalRects(parent.rect, clip.rect) {
            return .rect(RoundedClip(rect: merged, radii: mergeClipRadii(parent, clip, merged)))
        }
        return .empty
    }
}

/// Pick the radii for a merged clip. The innermost rounded clip whose rect
/// equals the merged intersection owns the corners; otherwise square. Mirrors
/// `mergeClipRadii`.
private func mergeClipRadii(_ parent: RoundedClip, _ child: RoundedClip, _ merged: LogicalRect) -> Float4 {
    let childRounded = child.radii.0 > 0 || child.radii.1 > 0 || child.radii.2 > 0 || child.radii.3 > 0
    let parentRounded = parent.radii.0 > 0 || parent.radii.1 > 0 || parent.radii.2 > 0 || parent.radii.3 > 0
    if childRounded && rectsApproxEqual(child.rect, merged) { return child.radii }
    if parentRounded && rectsApproxEqual(parent.rect, merged) { return parent.radii }
    return (0, 0, 0, 0)
}

private func rectsApproxEqual(_ a: LogicalRect, _ b: LogicalRect) -> Bool {
    let eps = 0.5
    return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps &&
        abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
}

/// Clip a layer's rect against the accumulated clip; nil if fully clipped.
/// Mirrors `clipLayerRect`.
func clipLayerRect(_ clip: ClipState, _ rect: LogicalRect) -> LogicalRect? {
    switch clip {
    case .none: return rect
    case .empty: return nil
    case .rect(let clipRect): return intersectLogicalRects(rect, clipRect.rect)
    }
}

/// The accumulated clip's per-corner radii (`[TL, TR, BR, BL]`), or all-zero.
/// Mirrors `clipRadii`.
func clipRadii(_ clip: ClipState) -> Float4 {
    switch clip {
    case .none, .empty: return (0, 0, 0, 0)
    case .rect(let clipRect): return clipRect.radii
    }
}

/// The accumulated clip's bounding rect, or nil if unbounded/empty. Mirrors
/// `clipRect`.
func clipRect(_ clip: ClipState) -> LogicalRect? {
    switch clip {
    case .none, .empty: return nil
    case .rect(let clipRect): return clipRect.rect
    }
}

/// Logical-x → target-physical-x (target-local, origin at target rect).
func logicalToTargetPhysicalX(_ target: RenderTarget, _ logicalX: Double) -> Double {
    (logicalX - target.logicalRect.x) * target.fractionalScale
}

/// Logical-y → target-physical-y.
func logicalToTargetPhysicalY(_ target: RenderTarget, _ logicalY: Double) -> Double {
    (logicalY - target.logicalRect.y) * target.fractionalScale
}

/// Whether a logical-space rect overlaps this target's output area. Mirrors
/// `logicalRectIntersectsTarget`.
func logicalRectIntersectsTarget(_ target: RenderTarget, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
    rectIntersectionArea(
        LogicalRect(x: x, y: y, width: width, height: height),
        target.logicalRect) > 0
}
