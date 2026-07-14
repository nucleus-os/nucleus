import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// Converted from FrameInputsFixture (Phase 9.5): the per-frame input/demand value
// types — the present-probe latch, deadline coalescing, and snapshot field
// carriage. Fully hardware-independent.
@Suite struct FrameInputsTests {
    @Test func renderInputsSnapshotCarriage() {
        let inputs = RenderInputsSnapshot(
            backgroundAnimationActive: true, layerShellActiveOnOutput: false,
            overlayTarget: true, overlayOutputId: 3, keyWindowId: 42,
            systemAppearance: .dark, sessionLocked: false, lockLayerIds: [])
        #expect(inputs.overlayTarget && inputs.overlayOutputId == 3, "inputs-overlay")
        #expect(inputs.keyWindowId == 42 && inputs.systemAppearance == .dark, "inputs-key-appearance")
        #expect(inputs.lockLayerIds.isEmpty, "inputs-no-lock")
    }

    @Test func presentProbeLatch() {
        var probe = PresentProbe()
        #expect(!probe.shouldSubmit(hasContent: false), "probe-no-content")
        #expect(probe.shouldSubmit(hasContent: true), "probe-fires")
        probe.markSubmitted()
        #expect(!probe.shouldSubmit(hasContent: true), "probe-latched")
    }

    @Test func deadlineCoalescing() {
        #expect(minOptionalDeadline(nil, nil) == nil, "deadline-both-nil")
        #expect(minOptionalDeadline(1000, nil) == 1000, "deadline-left-only")
        #expect(minOptionalDeadline(nil, 2000) == 2000, "deadline-right-only")
        #expect(minOptionalDeadline(3000, 1000) == 1000, "deadline-min")
    }

    @Test func demandEqualityAndCarriage() {
        let cont = ContinuousDemand(
            overlayOutputId: 1, notificationAnimationActive: true, screenshotQueueActive: false,
            overlayRenderAnimationActive: true, backgroundAnimationActive: false)
        let a = Demand(overlayFrameRequested: true, sceneFrameRequested: false,
                       operationDeadlineNs: 500, continuous: cont)
        let b = Demand(overlayFrameRequested: true, sceneFrameRequested: false,
                       operationDeadlineNs: 500, continuous: cont)
        #expect(a == b, "demand-equatable")
        #expect(a.continuous.notificationAnimationActive && a.operationDeadlineNs == 500, "demand-fields")
    }
}
