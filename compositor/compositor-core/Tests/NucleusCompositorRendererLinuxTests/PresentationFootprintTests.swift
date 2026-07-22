import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// footprint port — outward-rounded physical damage, shadow visual-outset
// inflation, clip trimming, the plan-rect projection, and the stable model-rect
// mapping. Mirrors the Zig PresentationFootprint tests. Hardware-independent.
@Suite struct PresentationFootprintTests {
    static func approxD(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

    static func target() -> RenderTarget {
        RenderTarget(
            outputId: 1, logicalRect: LogicalRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: PixelSize(width: 200, height: 200), scale: 1, fractionalScale: 2,
            overlayUsableArea: UsableArea(x: 0, y: 0, w: 100, h: 100))
    }

    @Test func physicalDamageRoundsOutward() {
        let rect = physicalDamageRectFromLogicalRect(
            Self.target(), LogicalRect(x: 10.25, y: 20.25, width: 10.25, height: 5.25))!
        #expect(rect == PhysicalRect(x: 20, y: 40, width: 21, height: 11), "damage-rounds-outward")
        // Degenerate rect → nil.
        #expect(physicalDamageRectFromLogicalRect(Self.target(), LogicalRect(x: 0, y: 0, width: 0, height: 5)) == nil,
                "damage-degenerate-nil")
    }

    @Test func layerFootprintShadowExtent() {
        var layer = Layer(id: 42, kind: .container)
        var style = VisualStyle()
        style.shadow = LayerShadow(offsetX: 0, offsetY: 12, blurRadius: 28, spreadRadius: 0,
                                   cornerRadius: 18, color: (0, 0, 0, 0.28))
        layer.model.visualStyle = style

        let footprint = computeLayerFootprint(LayerFootprintInput(
            layer: layer, bounds: Bounds(w: 200, h: 80),
            layerRect: LogicalRect(x: 100, y: 50, width: 200, height: 80), clip: .none))

        #expect(Self.approxD(footprint.visualOutset.x, 42) && Self.approxD(footprint.visualOutset.y, 54), "shadow-outset")
        #expect(footprint.visualRect == LogicalRect(x: 58, y: -4, width: 284, height: 188), "shadow-visual-rect")
        // No clip → visible rects equal their unclipped forms.
        #expect(footprint.visibleContentRect == footprint.layerRect, "no-clip-content")
        #expect(footprint.visibleVisualRect == footprint.visualRect, "no-clip-visual")
    }

    @Test func decorationSlotShadowMargin() {
        let layer = Layer(id: 7, kind: .container)
        let slot = DecorationFootprintSlot(hasShadow: true, shadowMarginX: 30, shadowMarginY: 40)
        let footprint = computeLayerFootprint(LayerFootprintInput(
            layer: layer, bounds: Bounds(w: 100, h: 100),
            layerRect: LogicalRect(x: 0, y: 0, width: 100, height: 100), clip: .none,
            decorationSlot: slot))
        #expect(Self.approxD(footprint.visualOutset.x, 30) && Self.approxD(footprint.visualOutset.y, 40), "deco-slot-outset")
    }

    @Test func clipTrimsContentAndVisual() {
        let layer = Layer(id: 8, kind: .container)
        let clip = ClipState.rect(RoundedClip(rect: LogicalRect(x: 0, y: 0, width: 150, height: 150)))
        let footprint = computeLayerFootprint(LayerFootprintInput(
            layer: layer, bounds: Bounds(w: 200, h: 200),
            layerRect: LogicalRect(x: 100, y: 100, width: 200, height: 200), clip: clip))
        #expect(footprint.visibleContentRect == LogicalRect(x: 100, y: 100, width: 50, height: 50), "clip-content")
        #expect(footprint.physicalDamageRect(Self.target()) != nil, "clip-has-damage")
    }

    @Test func planRectProjection() {
        let pr = planRectFromLogicalRect(Self.target(), LogicalRect(x: 10, y: 20, width: 30, height: 40))
        #expect(pr == PlanRect(x: 20, y: 40, w: 60, h: 80), "plan-rect")
    }

    @Test func stableModelRectMapping() {
        var layer = Layer(id: 9, kind: .container)
        layer.model.properties.position = Point2D(x: 10, y: 20)
        layer.model.properties.bounds = Bounds(w: 100, h: 50)
        let r = stableLayerModelLogicalRect(M44.identity, layer)
        #expect(Self.approxD(r.x, 10) && Self.approxD(r.y, 20) && Self.approxD(r.width, 100) && Self.approxD(r.height, 50),
                "stable-model-rect")
    }
}
