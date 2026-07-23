# Compositor Trackpad Gestures

Native multi-finger gesture support in the Nucleus compositor, driven by libinput and exposed both internally (as `WireEventRecord` events on the compositor's normalized input stream, for window-management policy) and to Wayland clients (via `zwp_pointer_gestures_v1`).

## Why

Apple-style trackpad gestures — three-finger workspace swipes, four-finger Mission Control swipes, pinch-to-zoom on the desktop — are a defining ergonomic of the macOS WM that Nucleus mirrors. The hardware path is already solved on Linux (`hid-magicmouse` + libinput); the gap is entirely in Nucleus's input layer, which currently drops gesture events at the input-normalization boundary.

Today, the input normalizer `InputEventNormalize.translate(...)` in `NucleusCompositorWaylandRuntime` handles keyboard / pointer / scroll libinput events only. libinput's `LIBINPUT_EVENT_GESTURE_*` constants and `libinput_event_gesture_*` accessors are already clang-importable from Swift through the `NucleusCompositorInputC` façade (it `#include`s `<libinput.h>` whole), but the normalizer's `switch` never matches the gesture event types, so swipe/pinch/hold events are dropped and never reach the window-management policy in `NucleusCompositorServer`. There is also no `zwp_pointer_gestures_v1` implementation, so Wayland clients can't receive gestures from Nucleus even when they would on KWin / Mutter / Sway.

## Hardware target

Apple Magic Trackpad (1, 2, or 3) over USB-C tether or Bluetooth. The mainline `hid-magicmouse` driver exposes the full ABS_MT axis set with up to ~10 simultaneous contacts, pressure, and contact area. libinput recognizes the device as a touchpad and produces gesture events without configuration.

**Magic Trackpad 2 over Bluetooth quirk:** the device defaults to single-touch mouse mode and requires a HID feature report to switch into multitouch. Recent libinput versions handle this transparently; if gestures don't appear immediately on a fresh pairing, suspect the multitouch-mode switch before suspecting the compositor.

This effort is not Magic-Trackpad-specific — any libinput-recognized touchpad (built-in laptop trackpads, Logitech MX, etc.) flows through the same path. Magic Trackpad is the reference device because it's the closest hardware analog to the macOS source-of-truth ergonomics being mirrored.

## Phases (strict sequential order)

### Phase 1 — Confirm the libinput gesture API surface

Unlike the retired hand-written binding, the Swift compositor imports `<libinput.h>` whole through the `NucleusCompositorInputC` clang façade, so the gesture constants and accessors are already reachable from Swift with no binding work to add. This phase is a checkpoint: confirm the following symbols import and reference cleanly before Phase 2 wires them into the normalizer.

- Gesture event-type constants (from `libinput.h`, already imported):
  - `LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN`
  - `LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE`
  - `LIBINPUT_EVENT_GESTURE_SWIPE_END`
  - `LIBINPUT_EVENT_GESTURE_PINCH_BEGIN`
  - `LIBINPUT_EVENT_GESTURE_PINCH_UPDATE`
  - `LIBINPUT_EVENT_GESTURE_PINCH_END`
  - `LIBINPUT_EVENT_GESTURE_HOLD_BEGIN`
  - `LIBINPUT_EVENT_GESTURE_HOLD_END`
- The `libinput_event_gesture` opaque type and accessors:
  - `libinput_event_get_gesture_event(event)`
  - `libinput_event_gesture_get_finger_count(event)`
  - `libinput_event_gesture_get_cancelled(event)`
  - `libinput_event_gesture_get_time_usec(event)`
  - `libinput_event_gesture_get_dx(event)` / `_get_dy(event)` / `_get_dx_unaccelerated(event)` / `_get_dy_unaccelerated(event)` (swipe + pinch)
  - `libinput_event_gesture_get_scale(event)` / `_get_angle_delta(event)` (pinch only)

Outcome: the gesture accessors are confirmed importable; `InputEventNormalize` doesn't yet read them.

### Phase 2 — gesture events and normalization

Mirror Apple's CGEvent gesture shape — `kCGEventGestureBegin / Changed / Ended` (Apple's symbols, kept as the parity reference) — with a per-event subtype tag (`swipe`, `pinch`, `hold`) and the subtype-specific payload (delta for swipe, scale + angle for pinch, finger count for all). This maps onto the compositor's Quartz-shaped `WireEventRecord`, whose scalar payload fields (`data0`–`data3`, `flags`, `timestampNs`) carry the gesture data.

- In `ServerTypes.swift` (the `NucleusCompositorServerTypes` module that defines `WireEventKind` / `WireEventRecord`), add gesture event kinds — `gestureBegin`, `gestureUpdate`, `gestureEnd` — and pack into the record's scalar payload:
  - subtype (`swipe` / `pinch` / `hold`)
  - finger count
  - `dx`, `dy` (swipe + pinch update only)
  - `scale`, `angle_delta` (pinch update only)
  - the event's `time_usec` (in `timestampNs`)
- In `InputEventNormalize.translate(...)` (`NucleusCompositorWaylandRuntime`), extend the `switch` to handle the eight gesture event types, emitting the corresponding `WireEventRecord`s into the batch.
- Log every gesture during bring-up — confirm the Magic Trackpad pipeline end-to-end before any policy is wired.

Outcome: gestures are now visible inside the compositor as `WireEventRecord`s. No client-visible behavior change.

### Phase 3 — `zwp_pointer_gestures_v1` Wayland protocol

New file `PointerGestures.swift` in `NucleusCompositorWaylandRuntime`, following the router protocol pattern used by `CursorShape.swift` and `RelativePointer.swift` (a manager object holding a C request vtable, registered on the router). The already-vendored `Protocols/wayland-protocols/unstable/pointer-gestures/pointer-gestures-unstable-v1.xml` is included by the component recipe; run `tools/collider generate wayland` so its `-server-protocol.h` / `-protocol.c` are emitted for the runtime to bind against.

- Implement the global, the per-pointer `wp_pointer_gesture_swipe_v1` / `_pinch_v1` / `_hold_v1` resources, and the matching request handlers.
- Emit `swipe_begin / update / end`, `pinch_begin / update / end`, `hold_begin / end` events to the focused-pointer client in response to the gesture `WireEventRecord`s from Phase 2.
- Register the global on the router via `router.addGlobal(...)` alongside the existing `WlSeat` setup.
- Single owner for resource cleanup per the project's Wayland resource-destroy rule.

Outcome: Wayland clients (browsers, image viewers, the shell surfaces, and any future standalone-app surfaces) receive gesture events the same way they would on KWin / Mutter / Sway.

### Phase 4 — Window-management policy bindings

The genuinely Nucleus-flavored phase. The window-management policy in `NucleusCompositorServer` (which owns the space/window model in `Spaces.swift`) consumes the gesture `WireEventRecord`s and drives WM actions. No protocol surface; pure policy.

- Three-finger horizontal swipe → switch space (left/right).
- Three-finger vertical swipe → reserved for Mission Control overview when that lands; emit a `NucleusCompositorServer`-internal signal so the overview machinery can be added later without re-touching the gesture pipeline.
- Four-finger pinch (in / out) → desktop spaces zoom-out / zoom-in (when spaces UI lands; same signal-only pattern as Mission Control).
- Two-finger pinch on a focused window → forward to the client (already handled via Phase 3 protocol path; this phase ensures no policy intercepts it).
- Hold gesture: no default policy binding. Forward to clients via Phase 3.

Cancellation: every libinput gesture can be cancelled mid-stream (`libinput_event_gesture_get_cancelled`). Policy code must treat a cancelled `gestureEnd` as a rollback signal — e.g. a space swipe that reaches its end with `cancelled = true` returns to the original space, not the destination.

Outcome: Magic Trackpad on a Nucleus session drives the same WM ergonomics as a Mac.

## Critical files

- `compositor-core/Sources/NucleusCompositorInputC/NucleusCompositorInputC.h` — Phase 1 (already imports the gesture API; no change required)
- `compositor-core/Sources/NucleusCompositorServerTypes/ServerTypes.swift` — Phase 2 (`WireEventKind` / `WireEventRecord`)
- `compositor-core/Sources/NucleusCompositorWaylandRuntime/InputEventNormalize.swift` — Phase 2 (gesture normalization)
- `compositor-core/Sources/NucleusCompositorWaylandRuntime/PointerGestures.swift` (new) — Phase 3
- `swift-wayland/Sources/WaylandColliderRecipe/WaylandColliderRecipe.swift` — Phase 3 generation recipe
- `NucleusCompositorServer` (space/window policy, `Spaces.swift`) — Phase 4 (gesture-to-WM-action dispatch)

## Verification

Run via `...` per project policy.

- **Phase 1**: `swift build` (from `compositor-core`). Checkpoint only; the build must succeed and the referenced gesture symbols must resolve, with no normalizer changes yet.
- **Phase 2**: `swift build`. Manual: plug in Magic Trackpad, three-finger swipe on the compositor session, confirm log lines for `gestureBegin / update / end` with correct finger count, `dx`, `dy`. Pinch test: confirm `scale` ramps through 1.0 and `angle_delta` accumulates. Hold test: confirm begin / end pair with no update events between.
- **Phase 3**: `swift build`, plus `swift test` in `compositor-core` (which holds the compositor tests). Test client: a small Wayland client that binds `zwp_pointer_gestures_v1` and logs received events. `weston-touch-calibrator` and `wev` are useful references but neither exercises gestures specifically — a tiny custom client is the cleanest test. Validate that gesture events arrive at the focused-pointer client and stop arriving on focus change.
- **Phase 4**: Manual: three-finger horizontal swipe switches spaces. Cancelled-gesture rollback: start a space swipe, lift fingers without crossing the threshold, confirm the original space is restored. Two-finger pinch on a focused browser window pinches the page (i.e. policy correctly does not intercept). Forward Magic Trackpad gestures while a non-gesture-aware client is focused; confirm no errors and the policy bindings still fire.

## Out of scope

- **Touch protocol (`wl_touch`)** — separate effort; touchscreen support has different semantics from touchpad gestures. Not blocked on or by this work.
- **Per-application gesture customization** — gesture-to-WM-action mappings in Phase 4 are hard-coded to start. A user-config layer is a follow-on once the bindings are stable.
- **Gesture-driven window animations** — Mission Control / spaces overviews ride on the `DisplayLink` animation system landing separately. Phase 4 emits the trigger signal; the overview UI consumes it when it exists.
- **Three-finger drag emulation** — macOS's tap-to-drag-via-three-fingers is a libinput configuration matter, not a gesture-protocol matter. Configurable via libinput's per-device settings; out of scope for this plan.
