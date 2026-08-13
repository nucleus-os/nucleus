# Compositor Trackpad Gestures Plan

Status: complete.

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

`InputGestureNormalize` consumes every libinput swipe, pinch, and hold event
into one typed per-device sequence. The central input dispatch observes that
stream for idle activity, and device removal, session loss, malformed ordering,
and input teardown cancel active sequences.

`PointerGestureManager` registers `zwp_pointer_gestures_v1` and projects that
same normalized stream through generated swipe, pinch, and hold resources. It
snapshots the focused client's eligible pointer resources at sequence start,
keeps delivery on that snapshot through end or cancellation, and retires state
on focus transfer and resource or client destruction.

`CompositorGesturePolicy` arbitrates each sequence before client delivery.
Three-finger swipes own per-output space switching and the windows-overview
contract, four-finger pinches own the spaces-overview contract, and every
unbound sequence remains client-owned. Captured sequences retain their owner
through cancellation, focus transfer, output removal, and physical end.

## Phase 1 — Normalize libinput gestures

Status: complete.

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

Achieved state: `NormalizedGestureEvent` carries typed swipe, pinch, and hold
lifecycles without packing gesture values into `WireEventRecord`. One
`GestureSequenceNormalizer` owns each live device sequence and produces a
monotonic cancellation before malformed input, device removal, session loss, or
shutdown can retire its state. `InputHost` decodes libinput once and submits the
result through the central input dispatch.

Gate evidence: `collider test compositor` passes the focused lifecycle,
payload, malformed-transition, multi-device, removal, and teardown suite along
with the complete compositor graph. The reference-hardware trace is the
user-owned validation handoff and does not keep the implementation phase open.

## Phase 2 — Implement pointer-gestures-v1

Status: complete.

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

Achieved state: the production router advertises pointer-gestures-v1 version 3.
The seat-owned manager validates each typed `wl_pointer`, creates generated
swipe, pinch, and hold resources, and sends protocol fixed-point payloads from
the normalized sequence. A second device cancels the prior seat sequence before
starting its own. Pointer focus loss cancels once, and late physical endings or
destroyed resources cannot revive delivery.

Gate evidence: `collider test compositor` passes the raw-wire lifecycle,
fixed-point payload, overlap, focus-transfer, client teardown, and active
resource-destruction coverage. The generated dispatch and protocol ownership
suites cover malformed typed requests and transactional resource creation.

## Phase 3 — Add compositor gesture policy

Status: complete.

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

Achieved state: `InputDispatch` asks the server policy for ownership before
projecting a normalized event into pointer-gestures-v1. Three-finger swipes use
a dominant-axis lock and commit threshold; horizontal commits resolve from the
output's current active space, while vertical updates publish a bounded
interactive windows-overview state. Four-finger pinch updates publish the
spaces-overview state. Two-finger pinch, hold, and every unbound sequence reach
the focused client unchanged. Focus, session, cancellation, and output removal
roll back interactive state without forwarding the captured tail to a client
that never saw its begin.

Gate evidence: `collider test compositor` passes the complete Linux arm64
compositor graph, including nine focused policy scenarios for thresholds,
direction, overview commit and rollback, client ownership, focus transfer,
output removal, and active-space mutation during a sequence. Interactive
reference-hardware validation remains the user-owned handoff and does not keep
the implementation phase open.

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
