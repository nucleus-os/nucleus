# Compositor Trackpad Gestures Plan

Status: active.

## Invariant

The compositor normalizes libinput touchpad gestures once, exposes the same
stream to compositor policy and `zwp_pointer_gestures_v1`, and preserves
per-seat focus, cancellation, and teardown. Window-management policy may consume
an authorized gesture without changing the client protocol implementation.

Any libinput-recognized touchpad uses this path. Apple Magic Trackpad is the
reference hardware because Nucleus mirrors macOS desktop gesture semantics, not
because the implementation contains device-specific behavior.

## Current State

`NucleusCompositorInputC` imports the complete libinput gesture surface.
Swipe, pinch, and hold constants and accessors are available to Swift. The
vendored pointer-gestures protocol and its server/client dispatch bindings are
already generated under `swift-wayland`.

`InputEventNormalize` does not yet consume `LIBINPUT_EVENT_GESTURE_*` events,
the compositor does not register `zwp_pointer_gestures_v1`, and compositor
policy has no gesture actions. Implementation therefore begins at normalized
gesture events rather than protocol vendoring or binding generation.

## Phase 1 — Normalize libinput gestures

Status: pending.

Add gesture begin, update, and end records to the compositor's normalized input
model. Carry a subtype of swipe, pinch, or hold; finger count; monotonic event
time; cancellation; swipe and pinch deltas; and pinch scale and angle. Use typed
fields rather than packing unrelated values into undocumented scalar slots.

Extend `InputEventNormalize.translate(...)` for swipe, pinch, and hold begin,
update, and end events. Maintain one active gesture sequence per device and
reject malformed transitions without leaving policy state active.

Gate: focused normalization tests cover every event kind, cancellation,
malformed ordering, multiple devices, device removal, and teardown. A hardware
trace confirms that the reference trackpad reaches the same normalized events.

## Phase 2 — Implement pointer-gestures-v1

Status: pending.

Implement the pointer-gestures global and its swipe, pinch, and hold resources
in `NucleusCompositorWaylandRuntime` using the generated server dispatch. Route
normalized events to the client that owns the focused pointer. Focus changes,
seat removal, device removal, client destruction, and compositor teardown end or
cancel the active sequence exactly once.

Register the global only after its complete state machine and wire tests exist.
Keep resource ownership on the generated typed handler-box path defined by
[Swift Wayland Architecture](../../swift-wayland/ARCHITECTURE.md).

Gate: behavioral wire tests cover binding, begin/update/end, cancellation,
focus transfer, multi-device seats, malformed requests, client destruction, and
resource destruction.

## Phase 3 — Add compositor gesture policy

Status: pending.

Route unconsumed normalized gestures into `NucleusCompositorServer` policy:

- three-finger horizontal swipe switches spaces;
- three-finger vertical swipe drives the overview contract;
- four-finger pinch drives the spaces overview contract;
- two-finger pinch and gestures without a compositor binding reach the focused
  client unchanged; and
- hold has no default compositor binding.

A cancelled policy gesture restores its original state. Policy arbitration
decides at sequence start whether the compositor or client owns the sequence;
ownership does not change midway through a gesture.

Gate: policy tests cover thresholds, direction, cancellation rollback, focus
changes, unbound forwarding, and output/space changes during an active gesture.
Interactive reference-hardware validation is the user-owned final handoff.

## Critical Files

- `compositor/compositor-core/Sources/NucleusCompositorInputC/NucleusCompositorInputC.h`
- `compositor/compositor-core/Sources/NucleusCompositorServerTypes/ServerTypes.swift`
- `compositor/compositor-core/Sources/NucleusCompositorWaylandRuntime/InputEventNormalize.swift`
- `compositor/compositor-core/Sources/NucleusCompositorWaylandRuntime/PointerGestures.swift`
- `compositor/compositor-core/Sources/NucleusCompositorServer/Spaces.swift`
- `collider/Sources/WaylandColliderRecipe/WaylandColliderRecipe.swift`

## Verification

Use `collider build compositor` for compilation and `collider test wayland` for
the generated dispatch, router, and wire behavior. Add focused compositor-policy
tests to the ordinary compositor test graph. Protocol generation is required
only when the vendored XML or generator changes; gesture implementation alone
does not regenerate already-committed bindings.

## Explicit Non-Goals

- `wl_touch` touchscreen semantics are independent of touchpad gestures.
- Per-application gesture customization waits for a concrete configuration
  consumer.
- Gesture animation rendering belongs to the overview and presentation-clock
  implementations; this plan owns gesture state and policy decisions.
- Device-specific multitouch-mode setup remains libinput and kernel policy.
