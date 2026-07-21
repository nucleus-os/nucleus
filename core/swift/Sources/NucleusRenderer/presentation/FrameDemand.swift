// Phase 9.5 — Frame-demand policy snapshot (value types + pure logic).
//
// WindowServer owns output arming and request delivery; this owns the policy
// snapshot that says why another frame is needed.

/// Why continuous (animation-driven) frames are still demanded. Mirrors
/// `ContinuousDemand`.
struct ContinuousDemand: Equatable {
    var overlayOutputId: DisplayID
    var notificationAnimationActive: Bool
    var screenshotQueueActive: Bool
    var overlayRenderAnimationActive: Bool
    var backgroundAnimationActive: Bool
}

/// One frame's demand snapshot. Mirrors `Demand`.
struct Demand: Equatable {
    var overlayFrameRequested: Bool = false
    var sceneFrameRequested: Bool = false
    var continuous: ContinuousDemand
}

/// One-shot present-probe latch: submit a single debug present probe per session
/// before real content is published. Mirrors `PresentProbe`.
struct PresentProbe {
    var submitted: Bool = false

    /// Whether the probe should be submitted: not yet submitted and the output
    /// has presentable content. Mirrors `shouldSubmit` over the resolved fact.
    func shouldSubmit(hasContent: Bool) -> Bool {
        !submitted && hasContent
    }

    mutating func markSubmitted() {
        submitted = true
    }
}
