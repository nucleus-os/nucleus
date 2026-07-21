@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderLayerModelTests {
    @Test func renderLayerModel() {
        // Geometry defaults match the field defaults.
        let mp = ModelProperties()
        #expect(mp.position == Point2D(x: 0, y: 0), "model-position-default")
        #expect(mp.anchorPoint == Point2D(x: 0.5, y: 0.5), "model-anchor-default")
        #expect(mp.transform == M44.identity && mp.opacity == 1.0, "model-transform-opacity-default")
        #expect(mp.clip == nil && mp.bounds == Bounds(w: 0, h: 0), "model-clip-bounds-default")

        // M44 identity equality + a non-identity differs.
        var notId = M44.identity
        notId.m[0] = 2
        #expect(M44.identity == M44.identity && M44.identity != notId, "m44-identity-eq")

        // ModelState defaults + reset clears content.
        var ms = ModelState()
        #expect(ms.content == .none && ms.visualStyle == nil && ms.visualRevision == 0,
              "model-state-default")
        ms.content = .paint(PaintContentHandle(raw: 4))
        ms.reset()
        #expect(ms.content == .none, "model-state-reset")

        // Presentation defaults.
        let ps0 = PresentationState()
        #expect(ps0.override_ == nil && ps0.readiness == .noBacking && ps0.content == .none &&
              !ps0.backgroundEffect, "pres-state-default")
        #expect(BackgroundEffectRegions().rects.count == BackgroundEffectRegions.maxRects,
              "bg-regions-fixed-size")

        // effective*: with no override, fall through to the model.
        var model = ModelProperties()
        model.opacity = 0.4
        model.position = Point2D(x: 10, y: 20)
        model.bounds = Bounds(w: 100, h: 50)
        model.anchorPoint = Point2D(x: 0.25, y: 0.75)
        var pres = PresentationState()
        #expect(EffectiveLayer.opacity(model: model, presentation: pres) == 0.4, "eff-opacity-model")
        #expect(EffectiveLayer.position(model: model, presentation: pres) == Point2D(x: 10, y: 20),
              "eff-position-model")
        #expect(EffectiveLayer.bounds(model: model, presentation: pres) == Bounds(w: 100, h: 50),
              "eff-bounds-model")

        // effective*: a present override field takes precedence.
        var ov = PresentationOverride()
        ov.opacity = 0.9
        ov.position = Point2D(x: 1, y: 2)
        ov.cornerRadiusUniform = 8
        pres.override_ = ov
        #expect(EffectiveLayer.opacity(model: model, presentation: pres) == 0.9, "eff-opacity-override")
        #expect(EffectiveLayer.position(model: model, presentation: pres) == Point2D(x: 1, y: 2),
              "eff-position-override")
        // bounds override is nil → still falls back to model.
        #expect(EffectiveLayer.bounds(model: model, presentation: pres) == Bounds(w: 100, h: 50),
              "eff-bounds-fallthrough")

        // effectiveCornerRadii: uniform override beats the model's per-corner radii.
        var styled = ModelState()
        var vs = VisualStyle()
        vs.cornerRadii = (1, 2, 3, 4)
        styled.visualStyle = vs
        #expect(float4Equal(EffectiveLayer.cornerRadii(model: styled, presentation: pres), (8, 8, 8, 8)),
              "eff-corner-override-uniform")
        // No override → model's per-corner radii.
        #expect(float4Equal(EffectiveLayer.cornerRadii(model: styled, presentation: PresentationState()),
                          (1, 2, 3, 4)), "eff-corner-model-per-corner")
        // No override + no style → zero.
        #expect(float4Equal(EffectiveLayer.cornerRadii(model: ModelState(), presentation: PresentationState()),
                          (0, 0, 0, 0)), "eff-corner-zero")

        // resolveContentSample: explicit source + logical size pass through.
        var sample = ContentSample()
        sample.srcOrigin = (5, 6)
        sample.srcSize = (40, 30)
        sample.logicalSize = Bounds(w: 400, h: 300)
        let r1 = resolveContentSample(sample, textureWidth: 64, textureHeight: 64,
                                      fallbackLogicalW: 1, fallbackLogicalH: 1)
        #expect(r1.srcOrigin == (5, 6) && r1.srcSize == (40, 30) && r1.logicalW == 400 && r1.logicalH == 300,
              "resolve-explicit")

        // Non-positive source size → whole texture, origin reset to 0.
        var empty = ContentSample()
        empty.srcSize = (0, 0)
        let r2 = resolveContentSample(empty, textureWidth: 128, textureHeight: 96,
                                      fallbackLogicalW: 0, fallbackLogicalH: 0)
        #expect(r2.srcOrigin == (0, 0) && r2.srcSize == (128, 96), "resolve-empty-src-whole-texture")
        // Logical fallback chain: 0 → fallback(0) → max(1, srcSize).
        #expect(r2.logicalW == 128 && r2.logicalH == 96, "resolve-logical-fallback-to-src")

        // Logical falls back to the supplied fallback when sample is unset.
        let r3 = resolveContentSample(empty, textureWidth: 10, textureHeight: 10,
                                      fallbackLogicalW: 200, fallbackLogicalH: 150)
        #expect(r3.logicalW == 200 && r3.logicalH == 150, "resolve-logical-fallback-arg")
    }
}
