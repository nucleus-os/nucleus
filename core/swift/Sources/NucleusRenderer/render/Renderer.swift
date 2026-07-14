// Phase 10b.4 / 10b.4e — NucleusRenderer: consume a Swift FramePlan (Phase 9)
// directly and composite its ordered draw ops onto a Graphite canvas through the
// NucleusSkiaGraphite façade. 10b.4e replaces the footprint-fill skeleton with
// the real composite: texture/fill/shadow/transition quads with blend modes,
// rounded-rect clip masks, source rects, and alpha, walked in z-order. No
// serialization sits between the plan and the renderer, and no Swift callback
// runs during recording/submission (the façade submit path is pure C++).

import NucleusSkiaGraphiteBridge
import NucleusRenderModel

struct RenderResult {
    var imageWidth: Int32
    var imageHeight: Int32
    var opsDrawn: Int
    var submitOk: Bool
}

enum NucleusRenderer {
    static func rectF(_ r: PlanRect) -> nucleus.skia.RectF {
        var out = nucleus.skia.RectF()
        out.x = r.x; out.y = r.y; out.width = r.w; out.height = r.h
        return out
    }

    static func color(_ c: Float4) -> nucleus.skia.Color {
        var out = nucleus.skia.Color()
        out.r = c.0; out.g = c.1; out.b = c.2; out.a = c.3
        return out
    }

    static func blend(_ mode: BlendMode) -> nucleus.skia.BlendMode {
        switch mode {
        case .srcOver: return nucleus.skia.BlendMode.srcOver
        case .src: return nucleus.skia.BlendMode.src
        }
    }

    static func radii(_ mask: RRectMask) -> nucleus.skia.RRectRadii {
        nucleus.skia.RRectRadii(
            topLeft: mask.radii.0, topRight: mask.radii.1,
            bottomRight: mask.radii.2, bottomLeft: mask.radii.3)
    }

    /// Composite `plan`'s ordered ops onto `canvas`. `resolveTexture` maps a plan
    /// texture handle to a façade source image (the renderer-owned texture
    /// registry in the live path). Returns the number of ops drawn. Pure
    /// recording — no submit, no Swift callback beyond `resolveTexture`.
    static func composite(
        plan: FramePlan, onto canvas: nucleus.skia.Canvas,
        resolveTexture: (TextureHandle) -> nucleus.skia.Image?
    ) -> Int {
        var drawn = 0
        for op in plan.ops {
            drawn += composite(op: op, onto: canvas, resolveTexture: resolveTexture)
        }
        return drawn
    }

    /// Composite one non-effect command. The frame driver handles `.backdrop`
    /// inline because it must snapshot the accumulator at that precise z point.
    static func composite(
        op: PlanOp, onto canvas: nucleus.skia.Canvas,
        resolveTexture: (TextureHandle) -> nucleus.skia.Image?,
        resolveShadow: (UInt64) -> nucleus.skia.Image? = { _ in nil }
    ) -> Int {
            switch op {
            case .fillQuad(let quad):
                var paint = nucleus.skia.Paint()
                paint.color = color(quad.color)
                paint.blend = blend(quad.blendMode)
                if let mask = quad.maskRRect {
                    canvas.save()
                    canvas.clipRRect(rectF(mask.rect), radii(mask), true)
                    canvas.drawRect(rectF(quad.dst), paint)
                    canvas.restore()
                } else {
                    canvas.drawRect(rectF(quad.dst), paint)
                }
                return 1

            case .visualStyle(let quad):
                var style = nucleus.skia.StyledRRect()
                style.rect = rectF(quad.dst)
                style.radii = nucleus.skia.RRectRadii(
                    topLeft: quad.cornerRadii.0, topRight: quad.cornerRadii.1,
                    bottomRight: quad.cornerRadii.2, bottomLeft: quad.cornerRadii.3)
                style.background = color(quad.backgroundColor)
                style.borderTopWidth = quad.borderWidths.0
                style.borderRightWidth = quad.borderWidths.1
                style.borderBottomWidth = quad.borderWidths.2
                style.borderLeftWidth = quad.borderWidths.3
                style.borderTopColor = color(quad.borderTopColor)
                style.borderRightColor = color(quad.borderRightColor)
                style.borderBottomColor = color(quad.borderBottomColor)
                style.borderLeftColor = color(quad.borderLeftColor)
                canvas.drawStyledRRect(style, quad.alpha)
                return 1

            case .textureQuad(let quad):
                guard let handle = quad.texture, let image = resolveTexture(handle) else { return 0 }
                var paint = nucleus.skia.Paint()
                paint.alpha = quad.alpha
                paint.blend = blend(quad.blendMode)
                if let mask = quad.maskRRect {
                    canvas.save()
                    canvas.clipRRect(rectF(mask.rect), radii(mask), true)
                    canvas.drawImageRect(image, rectF(quad.src), rectF(quad.dst), paint)
                    canvas.restore()
                } else {
                    canvas.drawImageRect(image, rectF(quad.src), rectF(quad.dst), paint)
                }
                return 1

            case .shadowQuad(let quad):
                let image = quad.texture.flatMap(resolveTexture)
                    ?? quad.material.flatMap { resolveShadow($0.layerId) }
                guard let image else { return 0 }
                var paint = nucleus.skia.Paint()
                paint.alpha = quad.alpha
                canvas.drawImageRect(image, rectF(quad.src), rectF(quad.dst), paint)
                return 1

            case .transitionQuad(let quad):
                return Transition.composite(quad, onto: canvas, resolveTexture: resolveTexture)
            case .backdrop:
                return 0
            }
    }

    /// Render `plan` into a fresh offscreen target (the standalone tail the
    /// renderer fixture drives). `resolveTexture` maps a plan texture handle to a
    /// façade source image. Returns nil if the recorder/surface could not be
    /// created.
    static func renderOffscreen(
        context: nucleus.skia.GraphiteContext,
        plan: FramePlan,
        width: Int32,
        height: Int32,
        resolveTexture: (TextureHandle) -> nucleus.skia.Image?
    ) -> RenderResult? {
        let recorder = context.makeRecorder()
        guard recorder.isValid() else { return nil }
        let surface = recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else { return nil }

        let canvas = surface.getCanvas()
        var background = nucleus.skia.Color()
        background.a = 1  // opaque black
        canvas.clear(background)

        var drawn = 0
        for op in plan.ops {
            if case .backdrop(let spec) = op {
                let source = surface.snapshotImage()
                drawn += Backdrop.execute(
                    spec, liveSnapshot: source, prefix: source, onto: canvas)
            } else {
                drawn += composite(op: op, onto: canvas, resolveTexture: resolveTexture)
            }
        }

        let image = surface.snapshotImage()
        let recording = recorder.snapRecording()
        let status = context.submit(recording)

        return RenderResult(
            imageWidth: image.width(),
            imageHeight: image.height(),
            opsDrawn: drawn,
            submitOk: status == nucleus.skia.Status.ok)
    }
}
