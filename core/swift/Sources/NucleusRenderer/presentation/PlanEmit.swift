// Pure per-layer plan-command lowering. A content
// layer's textured-quad emission (fill-vs-native sizing, source-rect basis,
// rounded content mask, opaque coverage) and the accumulated-clip rounded mask.
//
// The live emit walker calls these geometry helpers directly.

/// Where a layer's texture content comes from. Mirrors `TextureContentKind`.
import NucleusRenderModel

enum TextureContentKind {
    case compositorExternal
    case waylandExternal
    case paint
    case snapshot
}

/// A resolved textured content source for a layer. Mirrors `TextureContent`.
struct TextureContent {
    var texture: TextureHandle
    var kind: TextureContentKind
    var role: TextureQuadRole
    var srcOriginX: Double = 0
    var srcOriginY: Double = 0
    var srcWidth: Double
    var srcHeight: Double
    var logicalSize: Bounds
    var opaqueFullSurface: Bool = false
}

/// Lower a content layer into a textured quad. Nil when fully clipped. Mirrors
/// `lowerTextureQuad`.
func lowerTextureQuad(_ target: RenderTarget, _ input: LayerInput, _ content: TextureContent) -> TextureQuad? {
    let frac = target.fractionalScale
    let targetSize = Bounds(w: Float(input.layerRect.width), h: Float(input.layerRect.height))

    // A non-identity world scale makes the layer's world rect differ from its
    // model bounds; the texture must then FILL the scaled rect. The threshold
    // ignores sub-pixel rounding so identity layers keep the native mapping.
    let layerIsScaled = abs(targetSize.w - input.bounds.w) > 0.5 || abs(targetSize.h - input.bounds.h) > 0.5
    let contentOverflows = content.logicalSize.w > targetSize.w || content.logicalSize.h > targetSize.h
    let fillRect = contentOverflows || layerIsScaled
    let renderedW: Double = fillRect ? Double(targetSize.w) : Double(content.logicalSize.w)
    let renderedH: Double = fillRect ? Double(targetSize.h) : Double(content.logicalSize.h)
    let rendered = LogicalRect(x: input.layerRect.x, y: input.layerRect.y, width: renderedW, height: renderedH)
    guard let visible = clipLayerRect(input.clip, rendered) else { return nil }

    // For a scaled layer the buffer stretches across the rendered extent, so the
    // source-per-logical basis is the rendered size; otherwise the buffer's
    // native logical size.
    let srcBasisW: Double = layerIsScaled ? renderedW : Double(content.logicalSize.w)
    let srcBasisH: Double = layerIsScaled ? renderedH : Double(content.logicalSize.h)
    let srcPxPerLogicalX = srcBasisW > 0 ? content.srcWidth / srcBasisW : frac
    let srcPxPerLogicalY = srcBasisH > 0 ? content.srcHeight / srcBasisH : frac
    let srcOffsetX = visible.x - rendered.x
    let srcOffsetY = visible.y - rendered.y

    let contentMask = roundedClipMask(target, input.clip)

    let dst = PlanRect(
        x: Float(logicalToTargetPhysicalX(target, visible.x)),
        y: Float(logicalToTargetPhysicalY(target, visible.y)),
        w: Float(visible.width * frac),
        h: Float(visible.height * frac))

    let opaqueRect: PlanRect? = (contentMask == nil && content.opaqueFullSurface && input.combinedOpacity >= 0.999) ? dst : nil

    return TextureQuad(
        layerId: input.layerId,
        role: content.role,
        texture: content.texture,
        dst: dst,
        src: PlanRect(
            x: Float(content.srcOriginX + srcOffsetX * srcPxPerLogicalX),
            y: Float(content.srcOriginY + srcOffsetY * srcPxPerLogicalY),
            w: Float(visible.width * srcPxPerLogicalX),
            h: Float(visible.height * srcPxPerLogicalY)),
        alpha: input.combinedOpacity,
        maskRRect: contentMask,
        opaqueRect: opaqueRect)
}

/// Build a per-corner rounded mask from the accumulated clip state, in target-
/// physical pixels. Nil for unbounded/empty/square clips. Mirrors
/// `roundedClipMask`.
func roundedClipMask(_ target: RenderTarget, _ clip: ClipState) -> RRectMask? {
    let radii = clipRadii(clip)
    if radii.0 <= 0 && radii.1 <= 0 && radii.2 <= 0 && radii.3 <= 0 { return nil }
    guard let rect = clipRect(clip) else { return nil }
    let frac = target.fractionalScale
    let maskW = Float(rect.width * frac)
    let maskH = Float(rect.height * frac)
    if maskW <= 0 || maskH <= 0 { return nil }
    return RRectMask(
        rect: PlanRect(
            x: Float(logicalToTargetPhysicalX(target, rect.x)),
            y: Float(logicalToTargetPhysicalY(target, rect.y)),
            w: maskW, h: maskH),
        radii: (Float(Double(radii.0) * frac), Float(Double(radii.1) * frac),
                Float(Double(radii.2) * frac), Float(Double(radii.3) * frac)))
}
