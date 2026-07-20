// Input/session-lock queries used by the input feed, shortcut handling, and
// session-lock gate to reach the authoritative
// Swift window model by surface wire id, replacing the deleted `findWindowForSurface`
// + `roleX-for-Window` dispatch bridge.
//
// All entries resolve through `RouterHost.shared.runtime`. The compositor runs
// single-threaded on the main actor.

import WaylandServerC

/// The window-source kind that owns a surface (wire `WindowSource` rawValue:
/// 1=xdg 2=xwayland 3=layerShell 4=lock), or 0 if no window owns the surface.
/// The session-lock gate reads this in place of `findWindowForSurface(s).source`:
/// while the lock is active every surface whose source is not `lock` (4) — including
/// an unowned surface (0) — is blocked (fail-closed).

/// The Swift Window id owning a surface, or 0 if none.

/// The current output of the Swift Window owning a surface, or 0 if unresolved.

/// The current animated outer frame for the Swift Window owning `surfaceId`.

/// True when the router has a mapped layer-shell surface assigned to `outputId`.

/// Number of xdg popups parented to `surfaceId`. The scanout planner reads this to
/// keep a fullscreen surface with popups off the overlay-plane-promotion path,
/// replacing the `WLSurface.popups` count. 0 when the surface owns no popups.

/// Focus + raise the window owning `surfaceId` (click-to-focus / pointer activation).

/// Raise/focus the model window for a pointer press without sending router
/// wl_keyboard enter/leave. Returns whether the caller should move keyboard focus.

/// Re-drive xdg activation state after the focus resolver changes keyboard focus.
/// This updates model focus and emits configure events, but does not send keyboard
/// enter/leave; the input path already delivered those through WlSeat.

/// Toggle the maximized state of the toplevel owning `surfaceId` (a window-management
/// shortcut). Mutates the model and re-drives the live configure cycle.

/// Toggle the fullscreen state of the toplevel owning `surfaceId`.

/// Ask the toplevel owning `surfaceId` to close (xdg_toplevel.close).

/// Tile/maximize the toplevel owning `surfaceId`. Returns true when a configure was
/// emitted and the compositor should request another frame.

/// The root (xdg) surface wire id of model window `windowId`, or 0. The chrome
/// path resolves this for the surface-keyed verb crossings (close/maximize) and the
/// traffic-light visual; the router window scene is keyed by the root surface id.

/// Whether model window `windowId` can begin a compositor-driven interactive
/// move/resize grab (mapped, not maximized/fullscreen).

/// Begin direct manipulation of `windowId`: snap the presented frame to the live
/// animated rect, adopt it as the layout rect, and report that start rect. Returns
/// false (out-params untouched) if no such window.

/// Apply the live interactive-grab preview rect to `windowId` (the dragged frame).

/// Drive an interactive-grab configure for `windowId`'s toplevel at its current
/// model rect: move-reason (untile) when `resizing` is false, resize-reason (the
/// dragged size) when true.

// MARK: - surface/output membership (presentation walk -> router surface)
//
// The presentation walk computes output membership. The router
// owns wl_surface.enter/leave and preferred-scale refresh for those outputs.

@MainActor
private enum SeatInput {
    static func surface(_ id: UInt64) -> WlSurface? {
        RouterHost.shared.runtime?.compositor.surface(id: UInt32(truncatingIfNeeded: id))
    }
}

/// Apply the compositor-computed set of outputs a router surface overlaps, so the
/// router emits wl_surface.enter/leave and refreshes preferred scale. `outputIds`
/// points to `count` DisplayIDs; an empty set means the surface overlaps no output.
/// Driven each frame by the reactor's presentation walk.
