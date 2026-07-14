// Phase 9.4 — Pure composition-matrix + clip-scaling helpers.
//
// The leaf math the geometry walk needs: the
// local-composition matrix (position/anchor/transform/presentation around a
// pivot) and the model→effective bounds clip/backdrop rescale. The Skia canvas
// draw routines (`applyAncestorClips`/`drawVisualStyle`/`opacityPaint`) and the
// presentation-override merge helpers stay with the renderer / Phase-8 surface.

import NucleusRenderModel

enum ComposeHelpers {
    /// Local composition matrix with presentation transform applied around a
    /// pivot origin (anchor in 0..1 normalized coords, scaled by bounds).
    /// Mirrors `localCompositionMatrix`.
    static func localCompositionMatrix(
        position: Point2D,
        anchorPoint: Point2D,
        transform: M44,
        presentationTransform: M44?,
        width: Float,
        height: Float
    ) -> M44 {
        let ox = anchorPoint.x * width
        let oy = anchorPoint.y * height
        let pivot = M44.translate(ox, oy, 0)
        let unpivot = M44.translate(-ox, -oy, 0)
        let presentation = presentationTransform ?? M44.identity

        return M44.translate(position.x, position.y, 0)
            .concat(pivot)
            .concat(presentation)
            .concat(transform)
            .concat(unpivot)
    }

    /// Scale a clip operation from model bounds to effective bounds. Mirrors
    /// `scaledClipForBounds`.
    static func scaledClipForBounds(
        clip: ClipOp?,
        modelBounds: Bounds,
        effectiveBounds: Bounds
    ) -> ClipOp? {
        guard let c = clip else { return nil }
        let sx: Float = abs(modelBounds.w) > 1e-7 ? effectiveBounds.w / modelBounds.w : 1.0
        let sy: Float = abs(modelBounds.h) > 1e-7 ? effectiveBounds.h / modelBounds.h : 1.0
        let radiusScale = min(sx, sy)
        return ClipOp(
            rect: (c.rect.0 * sx, c.rect.1 * sy, c.rect.2 * sx, c.rect.3 * sy),
            radii: (c.radii.0 * radiusScale, c.radii.1 * radiusScale,
                    c.radii.2 * radiusScale, c.radii.3 * radiusScale),
            antiAlias: c.antiAlias,
            transform: c.transform
        )
    }

    /// Scale a backdrop effect shape from model bounds to effective bounds.
    /// Mirrors `backdropShapeWithBounds`.
    static func backdropShapeWithBounds(
        shape: EffectShape,
        modelBounds: Bounds,
        effectiveBounds: Bounds
    ) -> EffectShape {
        let sx: Float = abs(modelBounds.w) > 1e-7 ? effectiveBounds.w / modelBounds.w : 1.0
        let sy: Float = abs(modelBounds.h) > 1e-7 ? effectiveBounds.h / modelBounds.h : 1.0
        switch shape {
        case .rect(let r):
            return .rect((r.0 * sx, r.1 * sy, r.2 * sx, r.3 * sy))
        case .rrect(let rect, let radii):
            let rs = min(sx, sy)
            return .rrect(
                rect: (rect.0 * sx, rect.1 * sy, rect.2 * sx, rect.3 * sy),
                radii: (radii.0 * rs, radii.1 * rs, radii.2 * rs, radii.3 * rs))
        }
    }
}
