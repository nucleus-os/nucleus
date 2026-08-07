import NucleusRenderModel
import Testing

@testable import NucleusRenderer

// Snapshot field carriage and frame-demand equality.
@Suite struct FrameInputsTests {
    @Test func renderInputsSnapshotCarriage() {
        let inputs = RenderInputsSnapshot(
            backgroundAnimationActive: true, layerShellActiveOnOutput: false,
            overlayTarget: true, overlayOutputId: 3, keyWindowId: 42,
            systemAppearance: .dark, sessionLocked: false, lockLayerIds: [])
        #expect(inputs.overlayTarget && inputs.overlayOutputId == 3, "inputs-overlay")
        #expect(
            inputs.keyWindowId == 42 && inputs.systemAppearance == .dark, "inputs-key-appearance")
        #expect(inputs.lockLayerIds.isEmpty, "inputs-no-lock")
    }

    @Test func demandEqualityAndCarriage() {
        let cont = ContinuousDemand(
            overlayOutputId: 1, notificationAnimationActive: true, screenshotQueueActive: false,
            overlayRenderAnimationActive: true, backgroundAnimationActive: false)
        let a = Demand(
            overlayFrameRequested: true, sceneFrameRequested: false,
            continuous: cont)
        let b = Demand(
            overlayFrameRequested: true, sceneFrameRequested: false,
            continuous: cont)
        #expect(a == b, "demand-equatable")
        #expect(a.continuous.notificationAnimationActive, "demand-fields")
    }
}
