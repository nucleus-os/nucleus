@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderEffectsTests {
    @Test func renderEffects() {
        // VisualEffect.apply populates the backdrop catalog fields; shape and
        // (here) state default are preserved per the helper contract.
        var backdrop = BackdropKindParams(shape: .rect((0, 0, 100, 100)))
        VisualEffect.apply(to: &backdrop, VisualEffect.Params(
            material: .hudWindow, appearance: .dark, emphasized: true, mask: .roundedRect(12)))
        #expect(backdrop.materialRole == .hudWindow, "apply-material")
        #expect(backdrop.appearance == .dark, "apply-appearance")
        #expect(backdrop.state == .active, "apply-state-default")
        #expect(backdrop.emphasized, "apply-emphasized")
        #expect(backdrop.mask == .roundedRect(12), "apply-mask")
        // Shape untouched by apply.
        #expect(backdrop.shape == .rect((0, 0, 100, 100)), "apply-preserves-shape")

        // setEmphasizedForKeyWindow toggles only emphasized.
        VisualEffect.setEmphasizedForKeyWindow(&backdrop, isKey: false)
        #expect(!backdrop.emphasized && backdrop.materialRole == .hudWindow, "emphasized-toggle-only")
        VisualEffect.setEmphasizedForKeyWindow(&backdrop, isKey: true)
        #expect(backdrop.emphasized, "emphasized-toggle-on")
    }
}
