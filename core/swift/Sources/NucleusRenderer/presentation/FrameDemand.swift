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
