@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderEffectsTests {
    @Test func renderEffects() {
        // Transition enum wire values.
        #expect(TransitionType.fade.rawValue == 0 && TransitionType.reveal.rawValue == 3,
              "transition-type-wire")
        #expect(TransitionSubtype.fromLeft.rawValue == 0 && TransitionSubtype.fromBottom.rawValue == 3,
              "transition-subtype-wire")
        #expect(TimingTemplateId.default.rawValue == 0 && TimingTemplateId.easeInEaseOut.rawValue == 4,
              "timing-wire")
        #expect(defaultTransitionDurationNs == 250_000_000, "default-duration")

        // TransitionMetadata defaults + equivalence.
        let m = TransitionMetadata(type: .push, subtype: .fromRight,
                                   durationNs: 240_000_000, timing: .easeInEaseOut)
        #expect(equivalentTransitionMetadata(m, m), "metadata-equivalent-self")
        var m2 = m
        m2.timing = .linear
        #expect(!equivalentTransitionMetadata(m, m2), "metadata-timing-differs")
        let mDefault = TransitionMetadata(type: .fade)
        #expect(mDefault.subtype == nil && mDefault.durationNs == defaultTransitionDurationNs &&
              mDefault.timing == .default, "metadata-defaults")

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
