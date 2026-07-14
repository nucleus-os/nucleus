// InputTargeting — pointer-target decision helpers for accepted events.
// Pure logic: it sits between a hit-test
// result and protocol/UI delivery and decides pointer-focus transitions + the
// xwayland/default cursor swap. Keyboard focus is NOT decided here — it is
// click-driven and owned by the dispatch (a pointer moving over a window changes
// nothing; see docs/macos-window-model.md).

/// Which window kind owns the surface under the pointer. Only `.xwayland` drives
/// behavior (the xwayland cursor); lock/none fold into `.xdg`.
enum PointerWindowOrigin {
    case none
    case xdg
    case xwayland
    case layerShell
}

/// The hit-test candidate the targeting decision consumes.
struct PointerCandidate {
    var surfaceID: UInt64?
    var surfaceX: Double = 0
    var surfaceY: Double = 0
    var windowID: UInt64?
    var origin: PointerWindowOrigin = .none
}

/// Prior pointer-focus state the decision compares against.
struct PointerTargetingState {
    var pointerFocusID: UInt64?
    var pointerWasXwayland: Bool = false
    var cursorFromXwayland: Bool = false
}

struct PointerTargetingDecision {
    var target: PointerCandidate
    var pointerFocusChanged: Bool = false
    var shouldClearPointerFocus: Bool = false
    var shouldApplyXwaylandCursor: Bool = false
    var shouldRestoreDefaultCursor: Bool = false
    var rememberPointerXwayland: Bool = false
}

enum InputTargeting {
    /// Resolve the pointer target for a hit-test candidate against prior state.
    /// Mirrors `EventTargeting.resolvePointerTarget` exactly.
    static func resolvePointerTarget(
        _ candidate: PointerCandidate, state: PointerTargetingState
    ) -> PointerTargetingDecision {
        var decision = PointerTargetingDecision(target: candidate)
        let focusedIsXwayland = candidate.origin == .xwayland

        decision.shouldApplyXwaylandCursor = focusedIsXwayland && !state.pointerWasXwayland
        decision.shouldRestoreDefaultCursor =
            !focusedIsXwayland && state.pointerWasXwayland && state.cursorFromXwayland
        decision.rememberPointerXwayland = focusedIsXwayland

        guard let surfaceID = candidate.surfaceID else {
            decision.shouldClearPointerFocus = true
            return decision
        }
        decision.pointerFocusChanged = state.pointerFocusID != surfaceID
        return decision
    }

    /// Map a hit-test window source (wire `WindowSource` rawValue: 1 xdg, 2 xwayland,
    /// 3 layer-shell, 4 lock) to the targeting origin. Only xwayland drives behavior,
    /// so lock/none fold into `.xdg`.
    static func origin(fromSource source: UInt32) -> PointerWindowOrigin {
        switch source {
        case 2: return .xwayland
        case 3: return .layerShell
        default: return .xdg
        }
    }
}
