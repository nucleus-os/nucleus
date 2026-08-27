# Render concurrency and presentation pipeline

Status: active

## Invariant

Scene authority and render authority are separate single-owner domains. The
compositor main actor owns Wayland objects, input, policy, scene transactions,
and animation intent. A dedicated render executor owns Graphite recorders and
contexts, Vulkan queues and synchronization objects, imported images, GPU
caches, scanout targets, submission, and retirement. The boundary carries only
immutable `Sendable` values with explicit scene revisions and presentation
deadlines. It never shares a recorder, Vulkan handle owner, mutable retained
tree, or C++ RAII value across executors.

The renderer keeps CPU preparation ahead of GPU execution without permitting
unbounded latency. At most one unpublished scene revision and the bounded
per-output frames-in-flight contract are retained. A newer scene revision
coalesces or supersedes preparation that has not begun recording. GPU queue
submission remains deliberately sparse and ordered; CPU parallelism does not
multiply render passes or submissions.

## Current constraint

`RetainedTreeStore`, `RenderRuntime`, `RenderCore`, presentation backends, frame
planning, Graphite recording, Vulkan submission, and DRM event handling are
main-actor-isolated today. `FrameDriver.renderFrame` performs plan construction,
resource resolution, producer rasterization, damage calculation, ordered
composition, recording snap, and submission as one synchronous call. The GPU
submission is asynchronous and image decoding already has a worker boundary,
but a CPU-heavy frame delays the same compositor loop that dispatches Wayland,
input, policy, and presentation events.

This plan preserves the existing single-owner lifetime model. It moves the
render owner off the compositor loop, then introduces concurrency only at
immutable and independently recordable boundaries.

## Phase 1: Establish complete frame-stage evidence

Keep the existing frame telemetry for tree snapshot, plan construction,
resource-summary construction, resolution, accumulator preparation, damage,
composition, blit, snap, submission, and presentation correlation. Add the
missing measurements for animation tick, producer cache-hit and cache-miss
costs by producer kind, runtime-effect compilation, image-upload adoption,
render-executor queue depth, prepared-frame age, superseded work, deadline
margin, frames in flight, and time the compositor loop spends dispatching one
render request.

Define a deterministic benchmark scene set covering a large retained tree,
paint-heavy invalidation, text and path rasterization, backdrop dependencies,
client-surface composition, image-decode bursts, animation, and two independent
outputs. Extend the render benchmark contract to record CPU stage distributions,
GPU duration, commit-to-render latency, submit-to-pageflip latency, missed
deadlines, input/Wayland dispatch stalls, and memory high-water marks. Preserve
the existing direct-scanout baseline so an architectural change cannot make a
scanout-only pass perform composition work.

Gate this phase with focused telemetry and benchmark tests plus the applicable
`collider test gpu-headless` and `collider test gpu-drm` selections. Record the
baseline evidence in the render benchmarking contract before changing executor
ownership.

## Phase 2: Publish an immutable render snapshot

Replace the renderer's direct access to the live `RetainedTreeStore` with an
immutable `RenderSnapshot` published by the main-actor scene owner. The snapshot
contains its scene revision, presentation-time animation state, output roots,
lock-composition authority, immutable resource identities, and the state needed
to calculate presentation damage. Its complete stored closure is checked
`Sendable`; do not make the live tree or arbitrary C++-backed values
`@unchecked Sendable`.

Make snapshot publication transactional. The main actor applies all commits for
one scene revision, advances animation presentation state once for the target
time, publishes one snapshot, and retains only the latest unpublished revision.
Move presentation acknowledgement, transaction completion, and damage clearing
behind revision-bearing messages from the render owner so an older completion
cannot clear newer scene damage. Keep session-lock composition in the published
snapshot as a mandatory scanout choke point rather than a callback into main-
actor state.

Gate this phase with retained-tree transaction, animation completion, damage,
multi-output acknowledgement, lock transition, and stale-completion tests. The
existing renderer still consumes the snapshot synchronously on the main actor
until Phase 3, which isolates the semantic change from the executor move.

## Phase 3: Move render authority to a dedicated executor

Introduce one dedicated render executor for each render device. Move
`RenderCore`, `FrameDriver`, the Graphite context, the submission queue,
presentation backends, imported client images, cache registries, scanout
targets, and GPU retirement state onto it. The compositor and Android hosts
submit typed snapshot, output, resource, capture, session, and shutdown
messages; completions return typed `Sendable` results through the existing
thread-safe wake mechanism and are applied on the main actor.

Make owner-thread checks explicit at the Swift/C++ façade in debug and
sanitizer configurations. Every Graphite recorder and every C++ RAII value is
created, used, and destroyed by its declared owner. Vulkan queue access is
serialized by the render executor. Replaced callbacks and captured Swift
values are released outside seam locks. Shutdown stops publication, drains or
cancels outstanding requests, waits for GPU retirement, destroys child GPU
resources, then destroys the Graphite context and Vulkan owners.

DRM readiness remains reactor-driven, but the compositor loop forwards the
readiness event without executing renderer work. The render executor drains DRM
events and reports pageflips without accessing Wayland objects. Android stops
treating the JNI frame-callback thread as `MainActor`; its host uses the same
render-device owner and typed handoff as the compositor.

Gate this phase with renderer lifecycle, resource retirement, output pause and
resume, capture, Android surface attach and detach, and compositor thread-
sanitizer tests. Exercise repeated bring-up and shutdown and device-loss failure
paths. Run the applicable `collider test runtime`, `collider test gpu-headless`,
`collider test gpu-drm`, and `collider test android` selections.

## Phase 4: Split preparation, recording, and submission

Replace the monolithic frame call with three explicit contracts:

1. `PreparedFrame` is an immutable CPU result containing scene and resource
   revisions, output identity, ordered prepared operations, resource summary,
   damage, direct-scanout facts, target presentation time, submission deadline,
   and cancellation identity.
2. Recording consumes one `PreparedFrame` and render-owned resolved resources to
   produce one or more Graphite recordings without consulting scene authority.
3. Submission inserts recordings in declared order, attaches platform acquire
   and release synchronization, submits the minimum command-buffer set, and
   returns a revision-bearing presentation token.

Move tree walking, geometry lowering, occlusion culling, layer signatures,
resource-summary construction, and damage planning into the pure preparation
stage. Preparation never allocates a Graphite surface, resolves a Vulkan
semaphore, or calls back into mutable resource ownership. A prepared frame that
has not entered recording is discarded when its scene, output topology,
resource, lock, or device generation becomes stale.

Preserve backdrop ordering as an explicit dependency in the prepared operation
stream. A backdrop samples the accumulator prefix before it and therefore forms
a recording partition boundary; it is never reordered or independently
composited. Direct scanout bypasses recording while retaining the same revision,
deadline, synchronization, and acknowledgement contracts.

Gate this phase with deterministic equivalence tests between the current plan
semantics and `PreparedFrame`, stale-work cancellation tests, backdrop and
vibrancy ordering tests, direct-scanout tests, multi-output tests, and pixel
comparisons for representative scenes.

## Phase 5: Add deadline-driven scheduling and bounded back pressure

Make every output presentation request carry a target presentation timestamp,
CPU submission deadline, refresh interval, variable-refresh state, and allowed
frames in flight. Derive those values from DRM presentation history and the
platform frame source rather than sampling the clock only when rendering begins.
Schedule preparation early enough to meet the deadline using measured stage
costs, but keep submission latency bounded to one or two frames as declared by
the presentation policy.

Coalesce unpublished snapshots and reject obsolete prepared frames. When work
cannot meet its deadline, prefer the newest semantically complete frame and
preserve the last accepted output contents; do not build a queue of stale
frames. Back pressure is per output so one flip-pending or slow output does not
block preparation and submission for another ready output. Queue ordering,
client acquire synchronization, resource retirement, and presentation
acknowledgement remain device-authoritative.

Gate this phase with deterministic scheduler tests for fixed refresh, variable
refresh, flip-pending outputs, deadline misses, bursty commits, continuous
animation, and two outputs with different refresh rates. Benchmark evidence
must show bounded prepared-frame age and queue depth and no regression in
commit-to-present or input/Wayland dispatch latency.

## Phase 6: Record independent producer work concurrently

Add a bounded Graphite recording pool only after the stage evidence identifies
producer recording as material. Create one Graphite recorder per worker and
confine it to that worker. Independent paint-layer cache misses, shadow masks,
and other offscreen producer jobs record against immutable inputs; completed
recordings return to the render executor for ordered insertion. The Graphite
context and Vulkan queue remain owned by the render executor.

Configure Graphite's supported worker executor for pipeline compilation and
other internal work. Move runtime-effect and pipeline precompilation off the
deadline-critical recording path where Graphite's API permits it. Establish
explicit cache and memory budgets for every recorder so additional concurrency
cannot multiply transient GPU memory without a bound.

Do not share one recorder across threads. Do not split ordered accumulator
composition at arbitrary operation counts. Parallel work joins before any
operation that samples a preceding render result, before final scanout
composition, and before ordered submission. Retain a serial fast path for a
small amount of producer work so scheduling overhead does not dominate simple
frames.

Gate this phase with recorder ownership assertions, deterministic recording
order tests, cache replacement and retirement tests, backdrop dependency tests,
device-loss and cancellation tests, thread-sanitizer coverage, GPU pixel tests,
and memory-pressure benchmarks. Keep concurrency only where benchmark evidence
improves the CPU-bound scenes without regressing simple or GPU-bound scenes.

## Phase 7: Pipeline independent outputs

Snapshot and tick the scene once per presentation epoch, then prepare damaged
outputs independently. Give each output distinct prepared-frame state,
recording ownership, deadline, frames-in-flight ledger, accepted layer
snapshots, and presentation acknowledgement. Serialize only the device-global
operations that require it: shared-resource mutation, context insertion, Vulkan
queue submission, and retirement.

One output's target acquisition failure, flip-pending state, capture request,
or retirement cannot block unrelated ready outputs. Shared client surfaces and
producer textures carry explicit read dependencies and device submission
serials so their lifetime is not inferred from the order in which output loops
happen to execute.

Gate this phase with mixed-refresh multi-output rendering, output hotplug,
session pause and resume, lock transitions, shared-surface replacement,
simultaneous capture, direct scanout on one output with composition on another,
and device retirement. The two-output benchmark must demonstrate overlapping
CPU preparation while preserving deterministic queue and pageflip accounting.

## Phase 8: Consolidate the public rendering API and durable contract

Delete the synchronous main-actor renderer entry points, `MainActor.assumeIsolated`
render calls, direct retained-store dependencies, and compatibility wrappers
replaced by the snapshot, preparation, recording, submission, and presentation
contracts. Keep first-party cross-module declarations `package` unless an
external supported product consumes them. Keep C++ and Vulkan types behind the
render-owner boundary; host-facing values are opaque handles, scalars, and
immutable Swift value types.

Move the durable executor, snapshot, scheduling, frames-in-flight, Graphite
recorder, synchronization, and shutdown invariants into the renderer and
runtime architecture documents. Update render benchmarking with the final
accepted baselines and qualification procedure. Re-audit the Android render
stack, screen recording, direct scanout, shell, and compositor plans against the
new API and rewrite or remove stale phases before continuing their work.

Gate the final state with focused component tests and the protected-main full
verification graph. Confirm through telemetry and sanitizer evidence that the
compositor loop performs no Graphite recording, Vulkan submission, GPU wait, or
renderer teardown; recorder workers never share a recorder; prepared work and
frames in flight remain bounded; and every presented completion names the exact
scene and resource revisions it acknowledges.
