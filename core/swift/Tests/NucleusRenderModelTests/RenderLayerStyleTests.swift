@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderLayerStyleTests {
    @Test func renderLayerStyle() {
        // Shadow outer extent: transparent shadow contributes no halo.
        var shadow = LayerShadow(blurRadius: 10, color: (0, 0, 0, 0))
        #expect(shadow.outerExtent() == (0, 0), "shadow-transparent-no-extent")

        // 3σ + |offset|, ceiled. blur=10 → σ=5 → 3σ=15; offset 4/2 → (19, 17).
        shadow = LayerShadow(offsetX: 4, offsetY: 2, blurRadius: 10, color: (0, 0, 0, 1))
        #expect(shadow.outerExtent() == (19, 17), "shadow-extent-3sigma-plus-offset")

        // Negative offset uses |offset|; non-integer σ ceils.
        shadow = LayerShadow(offsetX: -3, offsetY: 0, blurRadius: 7, color: (0, 0, 0, 0.5))
        // σ=3.5 → 3σ=10.5; x: 10.5+3=13.5→14; y: 10.5→11.
        #expect(shadow.outerExtent() == (14, 11), "shadow-extent-abs-and-ceil")

        // VisualStyle equality is structural.
        var a = VisualStyle()
        a.backgroundColor = (1, 0, 0, 1)
        a.cornerRadii = (4, 4, 4, 4)
        a.shadow = LayerShadow(blurRadius: 2, color: (0, 0, 0, 1))
        var b = a
        #expect(a == b, "style-equal")
        b.cornerRadii = (4, 4, 4, 5)
        #expect(a != b, "style-corner-differs")
        b = a
        b.shadow = nil
        #expect(a != b, "style-shadow-presence-differs")

        // BorderEdge defaults + equality.
        #expect(BorderEdge() == BorderEdge(width: 0, color: (0, 0, 0, 0)), "border-default")
        #expect(BorderEdge(width: 1) != BorderEdge(width: 2), "border-width-differs")

        // Delta cases.
        #expect(VisualStyleDelta.set(a) == VisualStyleDelta.set(a), "delta-set-equal")
        #expect(VisualStyleDelta.clear != VisualStyleDelta.unchanged, "delta-distinct")
        #expect(ShadowDelta.set(shadow) == ShadowDelta.set(shadow), "shadow-delta-equal")

        // Backdrop enum wire values pinned to the wire encoding.
        #expect(BackdropMaterialRole.default.rawValue == 0, "role-default-0")
        #expect(BackdropMaterialRole.shellOverlay.rawValue == 15, "role-shell-overlay-15")
        #expect(BackdropMaterialRole.allCases.count == 16, "role-count-16")
        #expect(BackdropBlendingMode.behindWindow.rawValue == 0 &&
              BackdropBlendingMode.withinWindow.rawValue == 1, "blending-wire-values")
        #expect(AppearanceMode.dark.rawValue == 2, "appearance-dark-2")
        #expect(BackdropState.followsWindowActive.rawValue == 2, "state-follows-2")
        #expect(ForegroundVibrancyMode.inherit.rawValue == 0, "vibrancy-inherit-0")
    }
}
