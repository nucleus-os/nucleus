// Phase 10b.4g — presentation transitions: lower a FramePlan `TransitionQuad`
// (the crossfade material the operation service emits) into render-time draws.
// The per-field progress + holds are resolved upstream in
// RenderPresentationOperationService (8.11); this lowers the resulting single
// crossfade: place the prev/next materials at their anchored rects, sample each
// by its source origin/size, crossfade by `progress`, clipped to the
// destination rounded rect.

import NucleusSkiaGraphiteBridge
import NucleusRenderModel

enum Transition {
    static func rectF(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> nucleus.skia.RectF {
        var out = nucleus.skia.RectF()
        out.x = x; out.y = y; out.width = w; out.height = h
        return out
    }

    static func rectF(_ r: PlanRect) -> nucleus.skia.RectF {
        rectF(r.x, r.y, r.w, r.h)
    }

    /// The anchored destination rect of the prev material (its position + size).
    static func prevRect(_ q: TransitionQuad) -> nucleus.skia.RectF {
        rectF(q.anchorPrev.0, q.anchorPrev.1, q.sideSizePrev.0, q.sideSizePrev.1)
    }

    /// The anchored destination rect of the next material.
    static func nextRect(_ q: TransitionQuad) -> nucleus.skia.RectF {
        rectF(q.anchorNext.0, q.anchorNext.1, q.sideSizeNext.0, q.sideSizeNext.1)
    }

    /// The source sample rect within the prev texture.
    static func prevSrc(_ q: TransitionQuad) -> nucleus.skia.RectF {
        rectF(q.srcOriginPrev.0, q.srcOriginPrev.1, q.sampleSizePrev.0, q.sampleSizePrev.1)
    }

    static func nextSrc(_ q: TransitionQuad) -> nucleus.skia.RectF {
        rectF(q.srcOriginNext.0, q.srcOriginNext.1, q.sampleSizeNext.0, q.sampleSizeNext.1)
    }

    static func hasCorners(_ q: TransitionQuad) -> Bool {
        q.cornerRadii.0 != 0 || q.cornerRadii.1 != 0 || q.cornerRadii.2 != 0 || q.cornerRadii.3 != 0
    }

    /// Composite a crossfade transition: clip to the destination rounded rect,
    /// then draw the prev material at `alpha·(1−progress)` and the next at
    /// `alpha·progress`, each placed at its anchored rect and sampled by its
    /// source rect. Returns the number of materials drawn (0–2).
    static func composite(
        _ q: TransitionQuad, onto canvas: nucleus.skia.Canvas,
        resolveTexture: (TextureHandle) -> nucleus.skia.Image?
    ) -> Int {
        canvas.save()
        let dst = rectF(q.dst)
        if hasCorners(q) {
            let radii = nucleus.skia.RRectRadii(
                topLeft: q.cornerRadii.0, topRight: q.cornerRadii.1,
                bottomRight: q.cornerRadii.2, bottomLeft: q.cornerRadii.3)
            canvas.clipRRect(dst, radii, true)
        } else {
            canvas.clipRect(dst, true)
        }

        var drew = 0
        if let prev = q.texturePrev, let image = resolveTexture(prev) {
            var paint = nucleus.skia.Paint()
            paint.alpha = q.alpha * (1 - q.progress)
            canvas.drawImageRect(image, prevSrc(q), prevRect(q), paint)
            drew += 1
        }
        if let next = q.textureNext, let image = resolveTexture(next) {
            var paint = nucleus.skia.Paint()
            paint.alpha = q.alpha * q.progress
            canvas.drawImageRect(image, nextSrc(q), nextRect(q), paint)
            drew += 1
        }
        canvas.restore()
        return drew
    }
}
