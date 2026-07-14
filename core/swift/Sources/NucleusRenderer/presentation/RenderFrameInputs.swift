// Phase 9.5 — Per-frame immutable presentation inputs (value snapshot).
//
// The pipeline reads every WindowServer-side fact it needs through this struct;
// nothing under the presentation walk reaches back into the server. The live
// `build(server, render_state, output_id)` assembly — which queries the seat,
// shell, and runtime bridge — is integration that binds at the planner flip; the
// long-lived `composition`/`render_device` pointers stay renderer-owned.

/// Resolved appearance after `auto` → `light|dark` translation at lowering time.
/// Mirrors `composition_plan.ResolvedAppearance`.
import NucleusRenderModel

enum ResolvedAppearance: UInt8 {
    case light
    case dark
}

/// Per-frame materialized inputs to the presentation pipeline. Mirrors the
/// value fields of `RenderInputs`.
struct RenderInputsSnapshot {
    var backgroundAnimationActive: Bool
    var layerShellActiveOnOutput: Bool
    var overlayTarget: Bool
    var overlayOutputId: DisplayID
    /// Window holding keyboard focus, or nil. Resolves
    /// `BackdropState.follows_window_active`.
    var keyWindowId: UInt64?
    /// Resolved system appearance; collapses `BackdropAppearance.auto`.
    var systemAppearance: ResolvedAppearance
    /// The ext-session-lock gate is armed: composite only `lock_windows` over an
    /// opaque blank — the lock-screen security boundary.
    var sessionLocked: Bool
    /// This output's mapped lock-surface scene root-layer ids (empty while
    /// unlocked, or before the lock client maps a surface for this output).
    var lockLayerIds: [UInt64]
}
