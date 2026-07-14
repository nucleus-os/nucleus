@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderPresentationTransitionTests {
    @Test func renderPresentationTransition() {
        // Field-index mapping is dense + stable.
        #expect(fieldIndex(.geometry) == 0 && fieldIndex(.contentReveal) == 1 &&
              fieldIndex(.opacity) == 2 && fieldIndex(.visualStyle) == 3, "field-index")
        #expect(transitionFieldCount == 4, "field-count")

        // Fresh transition: no holds, zero progress, tables sized to field count.
        var t = PresentationTransition(operationId: OperationID(raw: 1))
        #expect(t.materials.count == 4 && t.progress.count == 4 && t.holds.count == 4, "table-sizes")
        #expect(!t.contentRevealHeld() && !t.contentRevealBlocksProgress(), "fresh-no-hold")
        #expect(t.contentRevealProgress() == 0 && t.geometryProgress() == 0, "fresh-zero-progress")

        // Content-reveal hold lands in the content_reveal slot only.
        t.holdContentReveal(FieldHold(fence: FenceHandle(raw: 7), deadlineNs: 42, sweep: .clampAtZero))
        #expect(t.contentRevealHeld() && t.contentRevealBlocksProgress(), "hold-set")
        #expect(t.holds[fieldIndex(.geometry)] == nil, "hold-isolated-to-field")

        // Progress is independent per field.
        t.setContentRevealProgress(0.5)
        t.setGeometryProgress(0.25)
        #expect(t.contentRevealProgress() == 0.5 && t.geometryProgress() == 0.25, "progress-per-field")

        // Releasing the hold clears the slot.
        t.releaseContentRevealHold()
        #expect(!t.contentRevealHeld() && !t.contentRevealBlocksProgress(), "hold-released")

        // contentNeedsMaterial: needs a from texture and not retired.
        #expect(!t.contentNeedsMaterial(), "needs-material-none")
        t.fromTexture = SnapshotHandle(raw: 9)
        #expect(t.contentNeedsMaterial(), "needs-material-with-texture")
        t.contentRetired = true
        #expect(!t.contentNeedsMaterial(), "needs-material-retired")

        // Materials/targets carry typed values.
        var fm = FieldMaterial()
        fm.from = .value(.rect(Rect(x: 0, y: 0, w: 10, h: 10)))
        fm.to = .pending(ExpectedCommit(configureSerial: 5, slotGeneration: 2))
        t.materials[fieldIndex(.geometry)] = fm
        #expect(t.materials[fieldIndex(.geometry)].from == .value(.rect(Rect(x: 0, y: 0, w: 10, h: 10))),
              "material-from-value")

        // Expected-commit gate: nil expectation matches anything.
        let open = PresentationTransition(operationId: OperationID(raw: 2))
        #expect(open.matchesExpectedCommit(nil) &&
              open.matchesExpectedCommit(ExpectedCommit(configureSerial: 1, slotGeneration: 1)),
              "gate-open-matches-all")

        // Set expectation requires an exact serial + generation match.
        let expected = ExpectedCommit(configureSerial: 41, slotGeneration: 9)
        let gated = PresentationTransition(operationId: OperationID(raw: 3), expectedCommit: expected)
        #expect(gated.matchesExpectedCommit(expected), "gate-exact-match")
        #expect(!gated.matchesExpectedCommit(ExpectedCommit(configureSerial: 40, slotGeneration: 9)),
              "gate-serial-mismatch")
        #expect(!gated.matchesExpectedCommit(ExpectedCommit(configureSerial: 41, slotGeneration: 8)),
              "gate-generation-mismatch")
        #expect(!gated.matchesExpectedCommit(nil), "gate-nil-rejected")
    }
}
