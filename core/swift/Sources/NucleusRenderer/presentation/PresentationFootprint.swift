// A layer's model bounds are not the whole set of pixels it can affect:
// shadows extend outside the content rect, clips trim both, and damage rounds
// outward in target pixels during fractional-position animation. Centralizes
// those answers so lowering, damage, and window bookkeeping share one footprint
// rule.
//
// The renderer-owned `DecorationSlot` (fill/shadow textures, nine-slice) is not
// ported; the footprint reads only the shadow-margin facts through the value
// `DecorationFootprintSlot`.

/// Composition-plan rect (`composition_plan.Rect`): f32 target-physical space.
import NucleusRenderModel

struct PlanRect: Equatable {
    var x: Float = 0
    var y: Float = 0
    var w: Float = 0
    var h: Float = 0
}

/// Per-side logical outset added by decoration (shadow halo). Mirrors
/// `LogicalOutset`.
struct LogicalOutset: Equatable {
    var x: Double = 0
    var y: Double = 0
}

/// The shadow-margin facts the footprint needs from a renderer decoration slot.
/// Mirrors the `DecorationSlot.hasShadow()`/`shadow_margin_{x,y}` reads.
struct DecorationFootprintSlot {
    var hasShadow: Bool = false
    var shadowMarginX: Float = 0
    var shadowMarginY: Float = 0
}

/// Inputs to `compute`. Mirrors `LayerFootprintInput`.
struct LayerFootprintInput {
    var layer: Layer
    var bounds: Bounds
    var layerRect: LogicalRect
    var clip: ClipState
    var decorationSlot: DecorationFootprintSlot?

    init(layer: Layer, bounds: Bounds, layerRect: LogicalRect, clip: ClipState,
         decorationSlot: DecorationFootprintSlot? = nil) {
        self.layer = layer
        self.bounds = bounds
        self.layerRect = layerRect
        self.clip = clip
        self.decorationSlot = decorationSlot
    }
}

/// Resolved footprint. Mirrors `LayerFootprint`.
struct LayerFootprint {
    var layerRect: LogicalRect
    var visibleContentRect: LogicalRect?
    var visualRect: LogicalRect
    var visibleVisualRect: LogicalRect?
    var visualOutset: LogicalOutset

    func physicalDamageRect(_ target: RenderTarget) -> PhysicalRect? {
        guard let visible = visibleVisualRect else { return nil }
        return physicalDamageRectFromLogicalRect(target, visible)
    }

    func materialPlanRect(_ target: RenderTarget) -> PlanRect {
        planRectFromLogicalRect(target, layerRect)
    }

    func visibleContentPlanRect(_ target: RenderTarget) -> PlanRect? {
        guard let visible = visibleContentRect else { return nil }
        return planRectFromLogicalRect(target, visible)
    }
}

/// Compute a layer's footprint. Mirrors `compute`.
func computeLayerFootprint(_ input: LayerFootprintInput) -> LayerFootprint {
    let visibleContent = clipLayerRect(input.clip, input.layerRect)
    let localOutset = layerVisualOutset(input.layer, input.decorationSlot)
    let visualOutset = scaleOutset(localOutset, input.bounds, input.layerRect)
    let visualRect = inflateLogicalRect(input.layerRect, visualOutset)
    return LayerFootprint(
        layerRect: input.layerRect,
        visibleContentRect: visibleContent,
        visualRect: visualRect,
        visibleVisualRect: clipLayerRect(input.clip, visualRect),
        visualOutset: visualOutset)
}

/// The per-side logical outset a layer's decoration adds. Mirrors
/// `layerVisualOutset`.
func layerVisualOutset(_ layer: Layer?, _ decorationSlot: DecorationFootprintSlot?) -> LogicalOutset {
    var outset = LogicalOutset()
    if let slot = decorationSlot, slot.hasShadow {
        outset.x = max(outset.x, Double(slot.shadowMarginX))
        outset.y = max(outset.y, Double(slot.shadowMarginY))
    }
    if let node = layer, let style = node.model.visualStyle, let shadow = style.shadow {
        let extent = shadow.outerExtent()
        outset.x = max(outset.x, Double(extent.x))
        outset.y = max(outset.y, Double(extent.y))
    }
    return outset
}

/// The world-logical rect of a layer's *model* (not effective) geometry under a
/// parent matrix. Mirrors `stableLayerModelLogicalRect`.
func stableLayerModelLogicalRect(_ parentMatrix: M44, _ layer: Layer) -> LogicalRect {
    let bounds = layer.model.properties.bounds
    let modelMatrix = parentMatrix.concat(ComposeHelpers.localCompositionMatrix(
        position: layer.model.properties.position,
        anchorPoint: layer.model.properties.anchorPoint,
        transform: layer.model.properties.transform,
        presentationTransform: nil,
        width: bounds.w, height: bounds.h))
    let mapped = modelMatrix.mapRect(0, 0, bounds.w, bounds.h)
    return LogicalRect(x: Double(mapped.x), y: Double(mapped.y),
                       width: Double(mapped.w), height: Double(mapped.h))
}

/// Project a logical rect into a composition-plan rect. Mirrors
/// `planRectFromLogicalRect`.
func planRectFromLogicalRect(_ target: RenderTarget, _ rect: LogicalRect) -> PlanRect {
    PlanRect(
        x: Float(logicalToTargetPhysicalX(target, rect.x)),
        y: Float(logicalToTargetPhysicalY(target, rect.y)),
        w: Float(rect.width * target.fractionalScale),
        h: Float(rect.height * target.fractionalScale))
}

/// Project a logical rect to a target-physical integer damage rect, rounding
/// outward (floor/ceil). Nil when degenerate. Mirrors
/// `physicalDamageRectFromLogicalRect`.
func physicalDamageRectFromLogicalRect(_ target: RenderTarget, _ rect: LogicalRect) -> PhysicalRect? {
    if rect.width <= 0 || rect.height <= 0 { return nil }
    let left = logicalToTargetPhysicalX(target, rect.x).rounded(.down)
    let top = logicalToTargetPhysicalY(target, rect.y).rounded(.down)
    let right = logicalToTargetPhysicalX(target, rect.x + rect.width).rounded(.up)
    let bottom = logicalToTargetPhysicalY(target, rect.y + rect.height).rounded(.up)
    if right <= left || bottom <= top { return nil }
    return PhysicalRect(
        x: Int32(left), y: Int32(top),
        width: UInt32(right - left), height: UInt32(bottom - top))
}

private func scaleOutset(_ outset: LogicalOutset, _ bounds: Bounds, _ layerRect: LogicalRect) -> LogicalOutset {
    let scaleX: Double = bounds.w > 0 ? abs(layerRect.width / Double(bounds.w)) : 1.0
    let scaleY: Double = bounds.h > 0 ? abs(layerRect.height / Double(bounds.h)) : 1.0
    return LogicalOutset(x: outset.x * scaleX, y: outset.y * scaleY)
}

private func inflateLogicalRect(_ rect: LogicalRect, _ outset: LogicalOutset) -> LogicalRect {
    LogicalRect(
        x: rect.x - outset.x,
        y: rect.y - outset.y,
        width: rect.width + 2.0 * outset.x,
        height: rect.height + 2.0 * outset.y)
}
