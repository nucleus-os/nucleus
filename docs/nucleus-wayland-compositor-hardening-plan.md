# Nucleus Wayland Compositor Hardening Plan

## State invariant

Nucleus exposes one coherent compositor state at every observable boundary.

- Every advertised output is backed by one live, uniquely assigned KMS connector, CRTC, and primary plane.
- The renderer, desktop layout, Wayland globals, input mapping, shell policy, and presentation scheduler observe the same output topology generation.
- Every accepted Wayland request has complete protocol semantics. A protocol global is not advertised until Nucleus enforces the behavior that global promises.
- A surface commit is an immutable transaction. Subsurface state, role state, buffer state, explicit synchronization, callbacks, and presentation feedback move together or do not move at all.
- A presentation event completes only the exact surface commits included in the corresponding accepted KMS submission.
- Session pause, resume, hotplug, output removal, and output replacement leave no stale KMS object, Wayland resource, callback, file descriptor, or scheduler state behind.
- The compositor main actor sleeps when there is no work. Idle outputs do not trigger scene traversal, render planning, or periodic wakeups.
- Linux resources have explicit single ownership, while C and C++ interop remains confined to narrow scalar/opaque-handle seams.

This plan replaces incomplete behavior directly. It does not preserve partially implemented protocol paths, add compatibility modes, or keep parallel scheduling and topology pipelines.

## Audit basis

The findings came from comparing the Nucleus compositor at `4b4fe13f1aeeb081a012d2dbdc6ec29df2fdaa91` with the local niri and Smithay checkouts, then tracing the relevant Nucleus paths from Wayland request dispatch through scene authoring, renderer submission, DRM completion, and session lifecycle.

The comparison is architectural:

- niri provides the useful policy reference for redraw state, output lifecycle orchestration, session transitions, and connecting rendered work to presentation.
- Smithay provides the useful protocol-mechanism reference for surface roles, synchronized subsurface transactions, XDG configure state, resource lifetime, seat resources, and DMA-BUF validation.
- Nucleus remains Swift-native. It keeps its main-actor ownership model, retained scene architecture, explicit-sync lifetime tracking, C++ interop boundaries, and session-lock presentation gate.

## What Nucleus should preserve

The audit found several foundations that are stronger than replacing them with a Rust-shaped abstraction:

- `@MainActor` is the correct owner for compositor state, protocol state, rendering orchestration, and Linux session state.
- The `~Copyable` DRM owners in `NucleusCompositorRendererLinux/drm` correctly express local C-resource ownership.
- The explicit-sync path correctly treats acquire fences, release points, GPU completion, KMS ownership, and direct-scanout retirement as one lifetime problem.
- The renderer/core boundary and the closure/protocol seams between C++-interop and non-C++ modules match the monorepo architecture.
- The session-lock composition gate is placed at the final presentation choke point and is confirmed by a real page flip.
- Stable surface content identities plus changing content generations fit the retained renderer.
- Pure value-typed policy cores, including KMS format selection and window policy, are the right testing boundary.

The work below strengthens these foundations instead of introducing a second backend model.

## Findings and priority

| Priority | Area | Current risk |
| --- | --- | --- |
| P0 | Output hotplug | The udev path calls `RenderRuntime.enumerateOutputs`, but it does not reconcile `DesktopLayout`, `wl_output`, XDG output, windows, focus, or stale renderer bindings. |
| P0 | KMS allocation | Each connector independently chooses its first usable CRTC and planes. Two outputs can select the same CRTC or plane. |
| P0 | Output placement | Initial renderer and server output geometry places every output at `(0, 0)`. Multi-output hit testing, cursor placement, surface membership, and shell policy overlap. |
| P0 | Subsurface semantics | Role exclusion, ancestry-cycle rejection, sibling validation, parent-latched position/stacking, and synchronized transaction behavior are incomplete. |
| P0 | XDG shell | Configure serial validation, initial-map rules, XDG construction rules, positioner validation, popup parentage, popup grabs, and interaction serial validation are incomplete. |
| P0 | Protocol advertisement | `wp_fifo_v1` and `wp_commit_timing_v1` are advertised and latched but do not affect scheduling or presentation. |
| P1 | Presentation feedback | Feedback and frame callbacks are drained by output membership rather than by the exact commit included in a submitted frame. |
| P1 | Idle performance | The main loop authors every output and calls the renderer before every wait, then uses the next display deadline as a wake ceiling even with no pending redraw. |
| P1 | Refresh precision | `refresh_mHz` is divided to an integer hertz before calculating the interval, losing fractional refresh rates such as 59.94 Hz. |
| P1 | Session resume | Resume reacquires DRM master but does not revalidate resources, rebuild output bindings, force a modeset, reset presentation state, or reconcile hotplug changes. |
| P1 | Seat model | The seat always advertises pointer, keyboard, and touch, and stores only one device resource of each kind per client. |
| P1 | DMA-BUF validation | Plane modifiers can disagree, import validation is deferred despite synchronous creation promises, and several plane/flag/layout constraints are not enforced. |
| P1 | DRM time domain | Page-flip timestamps are treated as monotonic without checking `DRM_CAP_TIMESTAMP_MONOTONIC`; the 32-bit kernel sequence is not extended across wrap. |
| P1 | Resource ownership | The render node opened during discovery is sampled for `dev_t` and then left open. Raw integer FDs also remain copyable in some protocol value types. |
| P2 | Organization | `RendererRuntime.swift`, `WlSurface.swift`, `XdgShell.swift`, and `WlSeat.swift` mix resource mechanics, transactional state, policy, and execution. |

## Phase 1 — Make protocol advertisement truthful

Start by reducing the public protocol surface to behavior Nucleus completely enforces.

### Changes

1. Remove `WpCommitTimingManager` and `WpFifoManager` registration from `WaylandRouterRuntime`.
2. Delete the now-unused pending and committed FIFO/timestamp fields from `SurfaceAuxState`, `WlSurface`, `LatchedState`, and `SurfaceCommit`.
3. Delete `CommitTiming.swift` and `Fifo.swift` after their callers and tests are removed or rewritten around supported behavior.
4. Audit every remaining registered global in `WaylandRouterRuntime` against three requirements:
   - Requests validate all protocol-defined invariants.
   - Accepted state changes observable compositor behavior.
   - Resource destruction and client disconnect cannot leave stale state.
5. Lower a global’s advertised version when Nucleus implements only an earlier version’s contract. Do not keep a higher version with no-op requests.
6. Add one registry fixture asserting the exact supported global names and versions as a runtime behavior contract.

### Completion gate

- No global contains comments that defer its core behavior to a later phase.
- No request handler silently accepts a request whose promised effect is absent.
- FIFO and commit-timing clients do not discover those globals.

FIFO and commit timing return only after Phase 5 provides commit-correlated presentation records and Phase 6 provides an output redraw state machine. Their later implementation becomes a scheduler feature rather than inert surface metadata.

## Phase 2 — Introduce one output topology model and a global KMS allocator

Replace connector-by-connector attachment with a discovery snapshot and a whole-device allocation decision.

### New value model

Add focused output-topology types under `NucleusCompositorRendererLinux/drm`:

```swift
struct DrmConnectorCandidate: Sendable {
    let connectorID: ConnectorID
    let encoderCandidates: [DrmEncoderCandidate]
    let modes: [DrmModeInfo]
    let physicalSizeMM: PhysicalSize
    let vrrCapable: Bool
}

struct DrmPipelineAssignment: Sendable, Equatable {
    let connectorID: ConnectorID
    let crtcID: CrtcID
    let primaryPlaneID: PlaneID
    let cursorPlaneID: PlaneID?
    let mode: DrmModeInfo
}

struct OutputTopologySnapshot: Sendable {
    let generation: UInt64
    let assignments: [DrmPipelineAssignment]
}
```

Use small `RawRepresentable`, `Hashable`, `Sendable` ID types instead of passing unrelated `UInt32` and `UInt64` values through the planner.

### Allocation rules

1. Read connectors, encoders, CRTCs, planes, properties, and modes once per topology scan.
2. Build the complete connector-to-CRTC compatibility graph from every encoder’s `possible_crtcs`.
3. Build primary-plane and cursor-plane compatibility sets for every CRTC.
4. Preserve an existing valid connector/CRTC assignment first to avoid unnecessary modesets.
5. Compute a one-to-one connector/CRTC matching across all enabled connectors.
6. Allocate each primary plane to at most one CRTC.
7. Allocate each cursor plane to at most one CRTC; absence of a cursor plane remains a supported per-output result.
8. Prefer the current mode when still valid, then the driver-preferred resolution at its highest refresh variant.
9. Fail an individual connector closed when no unique pipeline exists. Do not corrupt already valid assignments for other connectors.
10. Produce diagnostics containing the compatibility graph and the reason an output could not be assigned.

The planner is pure. Libdrm discovery projects into values, the planner consumes those values, and attachment consumes only the chosen assignments.

### Files

- Replace `RendererRuntime.selectCrtc` and `RendererRuntime.selectPlanes`.
- Extend `DrmResources.swift` with value projections rather than repeated live property queries.
- Move topology planning into a new `DrmTopology.swift`.
- Keep modeset execution in `DrmOutput.swift`.

### Behavioral tests

- Two connectors competing for one CRTC result in one valid assignment and one explicit rejection.
- Two connectors with two compatible CRTCs receive unique CRTCs regardless of enumeration order.
- Primary and cursor planes never appear in more than one assignment.
- A valid existing assignment remains stable when an unrelated connector appears.
- Removing a connector frees its CRTC and planes for the next generation.
- Mode selection preserves a still-valid current mode and otherwise follows the defined preference.

### Completion gate

Every attached `RenderOutputBinding` is created from a unique `DrmPipelineAssignment`. No live path independently searches for “the first” CRTC or plane.

## Phase 3 — Reconcile renderer, server, and Wayland outputs atomically

Create one composition-root operation that applies an `OutputTopologySnapshot` to every owner.

### Reconciliation model

Add an `OutputTopologyReconciler` to `NucleusCompositorRuntime`. It owns the current applied snapshot and computes:

```swift
struct OutputTopologyChangeSet {
    let removed: [AppliedOutput]
    let changed: [(old: AppliedOutput, new: PlannedOutput)]
    let added: [PlannedOutput]
    let unchanged: [AppliedOutput]
}
```

An `AppliedOutput` contains the stable connector identity, current topology generation, display ID, KMS assignment, logical placement, scale, and advertised metadata.

### Apply order

1. Drain or cancel in-flight presentations belonging to removed or changed bindings.
2. Stop scheduling those bindings.
3. Emit `wl_surface.leave` for affected surface/output relationships.
4. Remove the output from session-lock, layer-shell, screencopy, gamma, cursor, scanout, and presentation ownership.
5. Migrate windows and focus through the existing `DesktopLayout` and `WindowManager` output-removal policy.
6. Remove the Wayland global so registries receive `global_remove`.
7. Retire the renderer binding and its KMS resources.
8. Apply changed renderer bindings and server display properties.
9. Attach newly assigned renderer outputs.
10. Add or update `Display` instances.
11. Add or update `wl_output` and XDG output state.
12. Recompute surface output membership, preferred scale, input bounds, shell output selection, and overlay geometry.
13. Queue first frames for changed and added outputs.

All steps execute on the main actor. A partially failed new output remains absent; already valid outputs stay live.

### Wayland output changes

1. Make `WlOutput.info` mutable only through an explicit `apply(OutputInfo)` operation.
2. Track the `WaylandGlobal` registration for each output independently so it can be removed while the router remains alive.
3. Retain or weakly reference removed output state safely from already-created `zxdg_output_v1` resources. `XdgOutput` must not hold an `unowned` output that can disappear first.
4. Re-emit `wl_output.geometry`, `mode`, `scale`, name/description, and version-correct `done` events after an update.
5. Track every live `XdgOutput` binding and re-emit logical position and size after layout changes.
6. Preserve stable output identity for a connector that remains present. Mint a new topology generation for stale page-flip rejection without changing the client-visible identity unnecessarily.

### Placement policy

1. Preserve explicit user layout for surviving outputs.
2. Restore remembered connector placement on reconnect.
3. Place a new output immediately to the right of the current desktop bounds, aligned to the primary output’s top edge.
4. Never initialize multiple enabled outputs at `(0, 0)`.
5. Normalize primary-output selection after removal before migrating windows.

### Files

- `compositor/compositor/Sources/NucleusCompositorRuntime/CompositorBringup.swift`
- `compositor/compositor/Sources/NucleusCompositorRuntime/CompositorRuntime.swift`
- new `OutputTopologyReconciler.swift`
- `NucleusCompositorRenderRuntime/RenderRuntime.swift`
- `NucleusCompositorRendererLinux/RendererRuntime.swift`
- `NucleusCompositorServer/Display.swift`
- `NucleusCompositorWaylandRuntime/WaylandRouterRuntime.swift`
- `NucleusCompositorWaylandRuntime/WlOutput.swift`
- `NucleusCompositorWaylandRuntime/XdgOutput.swift`

### Behavioral tests

- Unplugging a secondary output removes its global, migrates its windows, and leaves the primary output rendering.
- Unplugging the primary selects a deterministic fallback and updates shell policy.
- Unplugging the final output leaves a valid headless compositor that continues dispatching clients and input/session events.
- Replugging creates a fresh renderer generation, restores placement, and queues a first frame.
- A page flip from a retired generation cannot complete callbacks or mutate a replacement binding.
- A mode or scale change updates both `wl_output` and XDG output resources.

### Completion gate

The udev handler calls only the reconciler. Direct hotplug calls to `RenderRuntime.enumerateOutputs` no longer exist.

## Phase 4 — Make pause and resume full backend state transitions

Treat session disable/enable as invalidation and recovery boundaries, not only DRM master ioctls.

### Pause

1. Mark the session inactive before accepting new frame submissions.
2. Stop redraw scheduling and cancel deadline wakes.
3. Drain accepted flips while master is held.
4. For work that cannot be presented, discard presentation feedback and preserve frame callbacks for the next eligible redraw only when the surface commit remains current.
5. Clear cursor-plane and direct-scanout in-flight ownership.
6. Invalidate KMS property state that cannot be trusted across master loss.
7. Drop DRM master.
8. Suspend libinput after compositor input state and active grabs are reset.

### Resume

1. Reacquire DRM master and fail closed if that operation fails.
2. Re-enable required atomic and universal-plane client capabilities.
3. Rebuild a complete `OutputTopologySnapshot`.
4. Run the Phase 3 reconciler before rendering.
5. Force a modeset on every restored output.
6. Recreate or revalidate cursor planes, gamma/degamma state, VRR state, scanout rings, and KMS property blobs.
7. Reset display-link phase from the first new page flip rather than carrying a stale prediction across the pause.
8. Resume libinput, recompute capabilities, and clear stale focus/grab serials.
9. Queue one frame for each live output.

### State machine

Represent the backend state explicitly:

```swift
enum DrmBackendState {
    case active(OutputTopologySnapshot)
    case pausing
    case inactive
    case resuming
    case failed(SessionFailure)
}
```

Only `.active` admits KMS submission.

### Behavioral tests

- Pause with an in-flight composite frame.
- Pause with an in-flight direct-scanout frame.
- Resume after a connector was removed while inactive.
- Resume after a connector was added while inactive.
- Resume after mode resources changed.
- Repeated pause/resume does not grow FD, framebuffer, blob, or token counts.

### Completion gate

`RendererRuntime.resumeSession()` no longer consists solely of `drmSetMaster`. Resume produces a reconciled topology and a forced first modeset before normal scheduling resumes.

## Phase 5 — Correlate surface commits with submitted and presented frames

Replace output-wide callback draining with immutable frame records.

### Commit identity

1. Add a monotonically increasing `SurfaceCommitID` to each applied `WlSurface` latch.
2. Include the ID in `SurfaceCommit` and in the retained scene node content.
3. Store frame callbacks and presentation feedback on the commit record that accepted them.
4. When a newer commit supersedes an older commit before the older one is sampled:
   - Move frame callbacks according to core Wayland callback semantics so they complete after the next redraw of that surface.
   - Send `wp_presentation_feedback.discarded` for feedback whose exact content will never be presented.
5. Keep buffer-release and explicit-sync retirement separate from presentation notification; they share a commit identity but have different completion conditions.

### Frame identity

Add an immutable per-output record produced by scene authoring and retained through KMS completion:

```swift
struct SubmittedOutputFrame: Sendable {
    let outputID: DisplayID
    let outputGeneration: UInt64
    let submissionID: UInt64
    let sampledCommits: [PresentedSurfaceCommit]
    let targetPresentationNs: UInt64
}

struct PresentedSurfaceCommit: Sendable {
    let surfaceID: SurfaceID
    let commitID: SurfaceCommitID
}
```

Both composition and direct scanout produce the same record shape.

### Completion rules

1. KMS submission acceptance moves the record to `awaitingPresentation`.
2. A page flip completes only the record matching its output generation and submission identity.
3. Frame callbacks complete only for surfaces sampled into that frame.
4. Presentation feedback completes only when its exact commit ID appears in the completed frame.
5. Emit `wp_presentation_feedback.sync_output` for every client-bound `wl_output` resource corresponding to the presentation output before `presented`.
6. Output removal, failed atomic commit, failed render submission, or supersession discards the affected feedback exactly once.
7. Session-lock frames use the same correlation path; hidden non-lock content does not receive a false presented event.
8. Multi-output surfaces maintain per-output visibility. The first qualifying presentation can complete a frame callback, while presentation feedback reports the output or outputs that actually presented the commit.

### Replace

- Replace `WlSurface.presentationFeedbacksAwaitingPresent` with commit-owned feedback.
- Replace output-wide `WlCompositor.presentFeedback(forOutput:)` traversal.
- Replace the assumption in `CompositorBringup` that every surface targeting an output participated in every page flip.
- Carry the frame record through `RenderCore`, `RendererRuntime`, `DrmOutput`, and `DrmPageFlipToken`.

### Behavioral tests

- Two commits before one flip discard feedback for the unsampled commit and present the sampled one.
- Damage on one surface does not complete feedback for a different unchanged surface unless that commit was actually sampled.
- A hidden, occluded, minimized, or session-lock-blocked surface does not receive a false presentation.
- Direct scanout reports the promoted surface’s exact commit.
- A stale flip from an old output generation completes nothing.
- Each callback and feedback object is destroyed exactly once on present, discard, surface destruction, or client disconnect.

### Completion gate

No presentation API accepts only an output ID and then scans all live surfaces. It accepts a completed `SubmittedOutputFrame`.

## Phase 6 — Replace periodic output traversal with a redraw state machine

Adopt niri’s central lesson: an output’s redraw lifecycle is explicit state, and an idle output does not have a frame deadline.

### Per-output state

Add an `OutputRedrawState` owned next to `DisplayLink`:

```swift
enum OutputRedrawState {
    case idle
    case queued(RedrawReasons)
    case rendering(FrameBuildID)
    case awaitingPresentation(SubmittedOutputFrame)
    case deferredUntil(UInt64, RedrawReasons)
    case suspended(RedrawReasons)
}
```

`RedrawReasons` is an `OptionSet` containing at least surface damage, animation, cursor, shell overlay, output change, screencopy, lock transition, and recovery.

### Scheduler rules

1. Every source of visible change requests a redraw with a reason and output set.
2. `CompositorRuntime.run()` authors and renders only outputs in `.queued` whose deadline is due.
3. `.idle` outputs contribute no timeout.
4. `.awaitingPresentation` outputs cannot acquire another KMS target unless the mailbox policy explicitly supports it.
5. Page-flip completion transitions to `.idle` or `.queued` when work accumulated during flight.
6. An active animation queues the next frame only for outputs containing that animation.
7. Cursor movement queues only outputs containing the old or new cursor bounds.
8. A screencopy request queues its target output and completes against the produced frame.
9. Output topology and session transitions own cancellation and state migration.
10. `io_uring` waits indefinitely when every output is idle and there is no non-frame timer.

### Deadline precision

Calculate fixed-refresh intervals directly from millihertz:

```swift
refreshIntervalNs = roundedDivide(1_000_000_000_000, by: refreshMilliHz)
```

Do not convert through integer hertz. Keep the full-width interval internally and narrow to the presentation protocol’s `UInt32` only after bounds validation.

### Instrumentation

Record:

- Time in each redraw state.
- Redraw requests coalesced by reason.
- Scene-author passes per presented frame.
- Spurious render turns that produce no submission.
- Deadline error and missed-vblank count per output.
- Wakeups per second while all outputs are idle.

### Behavioral and performance tests

- An idle compositor has no periodic scene-author or render calls.
- Damage queues exactly the intersecting outputs.
- Damage arriving during an in-flight flip is retained for the next frame.
- Continuous animation advances at each target output’s refresh rate.
- A 59.94 Hz mode calculates its interval without truncating to 59 Hz.
- Mixed-refresh outputs schedule independently.
- Cursor-only and overlay-only updates do not traverse unrelated outputs.

### Completion gate

The unconditional per-turn loop over `layout.displays` is gone. `earliestDeadlineTimeout()` considers only queued or explicitly deferred work.

## Phase 7 — Rebuild `WlSurface` around an explicit transaction type

Make one transaction owner responsible for pending state, cached synchronized state, committed state, and commit identity.

### Structure

Split `WlSurface.swift` into:

- `WlSurfaceResource.swift`: request dispatch and wire-resource lifetime.
- `SurfaceRole.swift`: permanent role identity and role-specific hooks.
- `SurfacePendingState.swift`: request accumulation and validation.
- `SurfaceTransaction.swift`: immutable latched commit, merge rules, and commit ID.
- `SurfaceCurrentState.swift`: applied content and regions.
- `SurfacePresentationState.swift`: commit-correlated callbacks and feedback.

Keep `WlSurface` as the main-actor aggregate that coordinates these values.

### Role rules

1. Represent a role with a permanent typed identity, not a weak object plus an independent `hasRole` Boolean.
2. `wl_subsurface`, XDG toplevel, XDG popup, layer shell, session lock, cursor, and Xwayland roles all use the same exclusion mechanism.
3. Destroying a role object performs the protocol-defined mapping transition but does not accidentally permit an incompatible role while a role is still defined.
4. Creating multiple XDG surface wrappers for one `wl_surface` is rejected.
5. A role object disappearing before or after its `wl_surface` follows that protocol’s defined error and teardown order.

### Core request validation

1. Reject `set_buffer_scale` values less than one.
2. Reject invalid buffer-transform enum values.
3. Enforce version-specific attach-offset behavior.
4. Ignore `wl_surface.offset` for subsurfaces as required by the core protocol.
5. Validate viewport source/destination against buffer bounds and transform at commit.
6. Validate damage and geometry arithmetic without signed overflow.
7. Reject role-specific buffer commits before required initial configuration.
8. Validate release callbacks against the exact attached buffer transaction.
9. Ensure commit observers cannot mutate a partially applied transaction.

### Transaction rules

1. Capture pending state into one immutable transaction.
2. Reset only per-commit pending fields; retain sticky pending defaults explicitly.
3. Merge a new synchronized commit into an existing cached transaction according to field semantics.
4. Release or discard resources belonging to a superseded transaction exactly once.
5. Apply the transaction atomically to current state.
6. Notify the role, scene importer, explicit-sync owner, and presentation scheduler from the same applied transaction.
7. Make `commit()` return the applied or cached `SurfaceCommitID`, allowing downstream code to retain identity without consulting mutable surface state.

### Behavioral tests

- Invalid scale, transform, offset, viewport, and role-specific commits produce the correct protocol errors.
- A superseded cached commit releases its unused buffer and discards its feedback.
- Sticky and per-commit auxiliary fields reset correctly.
- Surface destruction retires current, pending, and cached resources once.
- A client destroying a `wl_buffer` does not invalidate already imported current content.

### Completion gate

No protocol object writes directly into scattered pending fields on `WlSurface`. It submits validated mutations to `SurfacePendingState`.

## Phase 8 — Complete synchronized subsurface topology

Implement core Wayland subsurface behavior as parent-applied topology transactions.

### Creation validation

1. Reject a surface that already has any role.
2. Reject self-parenting.
3. Reject any parent choice that creates an ancestry cycle.
4. Claim the permanent subsurface role before creating the `wl_subsurface` resource; roll it back only if resource creation fails before the role becomes observable.
5. Add a new subsurface at the top of the parent’s pending stack, with initial position `(0, 0)` and synchronized mode.

### Double-buffered topology

1. Keep separate current and pending child position.
2. Keep separate current and pending parent stack.
3. `set_position`, `place_above`, and `place_below` update pending topology only.
4. Apply pending topology when the parent surface state is applied, regardless of the child’s sync/desync mode.
5. Validate that a stacking reference is the parent or a sibling with the same parent.
6. Reject using the child itself or an unrelated surface with `WL_SUBSURFACE_ERROR_BAD_SURFACE`.
7. Preserve request order when multiple stacking operations precede one parent commit.

### Commit propagation

1. Cache commits while a child is effectively synchronized.
2. Apply the parent transaction first, then cached child transactions in current bottom-to-top topology order.
3. Propagate effective synchronization recursively through ancestors.
4. `set_sync` and `set_desync` take effect immediately.
5. On `set_desync`, apply cached state immediately only when no synchronized ancestor still forces caching.
6. A parent commit applies each cached descendant once.
7. Child frame callbacks and presentation feedback remain tied to the child transaction that becomes visible.

### Mapping and destruction

1. A child maps only when it has a non-null current buffer and its parent chain is mapped.
2. Parent unmap hides descendants without destroying their current state.
3. Destroying `wl_subsurface` immediately removes the association and unmaps the child.
4. Destroying a parent unmaps and detaches its child topology safely.
5. Scene authoring consumes the current topology snapshot, never pending state.

### Behavioral tests

- Direct and indirect cycle attempts fail.
- Related and unrelated stacking references are distinguished.
- Position and z-order remain unchanged until the parent commits.
- Multiple pending restacks produce the specified final order.
- Nested synchronized children apply atomically with the root.
- Desynchronizing under a synchronized ancestor does not apply early.
- Destroying a subsurface or parent updates mapping and scene topology immediately.

### Completion gate

`setSubsurfacePosition` and `placeChild` no longer mutate presentation-visible state immediately.

## Phase 9 — Complete XDG configure, map, positioner, popup, and grab semantics

Treat XDG shell as a validated state machine rather than a collection of decoded requests.

### XDG surface construction

1. Track one XDG construction claim per `wl_surface`.
2. Reject `get_xdg_surface` when the surface already has an XDG surface, another role, or attached/committed buffer content prohibited by XDG shell.
3. Require `get_toplevel` or `get_popup` before other role-dependent requests.
4. Enforce the role-object and `xdg_surface` destruction order, including `defunct_role_object`.

### Configure ledger

Replace the single `ackedSerial` with a ledger:

```swift
struct XdgConfigureRecord {
    let serial: UInt32
    let roleState: XdgRoleConfigure
    let windowPlan: ConfigurePlan
}
```

1. Append every sent configure.
2. Reject a serial that was never sent by this XDG surface.
3. Reject a duplicate ack.
4. Reject an ack older than the last consumed ack.
5. Acking a configure consumes it and every older outstanding configure.
6. The next commit consumes the most recently acked record without conflating it with later unacked configures.
7. A buffer cannot map before an initial configure has been acknowledged.
8. Null-buffer unmap resets the XDG surface to the state that requires a fresh initial configure before remapping.
9. Record the exact configure plan accepted by the committing buffer.

### Geometry and size validation

1. Double-buffer `set_window_geometry` and apply it with `wl_surface.commit`.
2. Reject zero or negative window geometry.
3. Clamp effective geometry to the surface-plus-subsurface bounds when applied.
4. Reject invalid min/max sizes and inconsistent constraint combinations.
5. Resolve the requested fullscreen output instead of dropping the request’s output argument.

### Positioners

1. Validate positive size.
2. Validate non-negative anchor-rectangle dimensions.
3. Validate anchor, gravity, and constraint-adjustment enum/bitmask values.
4. Require a complete positioner before `get_popup` or `reposition`.
5. Snapshot the positioner at use time.
6. Validate parent geometry intersection/adjacency requirements.
7. Store and validate `set_parent_configure` against the parent’s configure ledger.
8. Feed the snapshot into `PopupPolicy` for flip, slide, then resize in protocol order.

### Popups

1. Require a valid parent from XDG shell, layer shell, or another supported parent protocol before map.
2. Track popup trees and enforce topmost destruction ordering.
3. Add a seat-owned popup-grab stack.
4. Validate `grab` serial provenance and seat ownership.
5. Route pointer and keyboard input to the active popup grab.
6. Dismiss the correct popup subtree on outside interaction, Escape, parent unmap, or seat cancellation.
7. Send `popup_done` exactly once.
8. Reposition reactively when the parent geometry, parent configure, output work area, or scale changes.

### Interactive requests

1. Maintain a seat serial ledger for pointer button, touch down, and keyboard events.
2. Validate the seat resource belongs to the requesting client.
3. Accept move, resize, and window-menu requests only with a current qualifying serial for the requesting surface/client.
4. Reject invalid resize-edge values.
5. Wire accepted requests into `InteractionState` and `WindowMechanismHost`; remove the current ignored-serial behavior.

### Behavioral tests

- Invalid, duplicate, stale, and cross-surface configure acks fail.
- A pre-configure buffer commit fails.
- Unmap/remap requires a new initial configure.
- Invalid positioners fail at the request that defines or consumes them.
- Popup constraints match flip/slide/resize precedence.
- Popup grabs reject wrong-client, wrong-seat, stale, and unrelated serials.
- Move/resize requests cannot reuse an old serial or another client’s serial.

### Completion gate

`XdgSurface.ackedSerial` and the no-op `XdgPopup.grab` are gone. Every map references a consumed `XdgConfigureRecord`.

## Phase 10 — Make seat capabilities and resources reflect real devices

Move from one hard-coded seat snapshot to a live multi-resource seat model.

### Capabilities

1. Track libinput device additions and removals by capability.
2. Derive pointer, keyboard, and touch bits from the live device inventory.
3. Retain every bound `wl_seat` resource and send capability changes to all of them.
4. Advertise no touch capability when no touch device exists.
5. Cancel active touches and clear grabs before removing touch capability.
6. Clear keyboard state and focus safely when the final keyboard disappears.
7. Keep a synthetic capability injection path only inside behavior fixtures.

### Device resources

1. Store all `wl_pointer`, `wl_keyboard`, and `wl_touch` resources per client.
2. Deliver focus and input events to every live resource for that client as required.
3. Releasing one device resource must not unregister or starve another resource.
4. Send keymap and repeat information to every new keyboard resource.
5. Push keymap updates to all existing keyboard resources if configuration changes.
6. Store weak/resource-owner references so client teardown removes entries automatically.

### Serial authority

1. Centralize serial issuance and provenance in `SeatSerialLedger`.
2. Record event kind, client, surface, seat, and validity lifetime.
3. Use the ledger for cursor requests, interactive move/resize, popup grabs, selection operations, activation, and any other serial-authorized request.
4. Invalidate relevant serials on focus changes, release/cancel, session pause, and client teardown.

### Behavioral tests

- Capability events follow device add/remove transitions.
- Two pointer resources for one client both receive enter, motion, button, and leave.
- Releasing one of two resources preserves delivery to the other.
- Touch cancellation precedes touch-capability removal.
- Serial authorization cannot cross client, surface, seat, event kind, or session generation.

### Completion gate

`WlSeat.capabilities` is not a constant, and device registries do not map a client to only one resource.

## Phase 11 — Harden DMA-BUF validation and file-descriptor ownership

Make advertised format support identical to creation-time and commit-time import support.

### Discovery FD

1. Stop opening a render node merely to obtain `st_rdev`.
2. Return the selected render-node path/device identity from DRM discovery.
3. Use `stat` on the path to compute DMA-BUF feedback’s main device.
4. Delete `RenderRuntime.captureMainDevice(renderNodeFd:)` and the leaked `renderFd` bring-up path.

### Params validation

1. Wrap every received plane FD in one reference owner that closes exactly once.
2. Reject differing modifiers across planes.
3. Reject unsupported flags.
4. Validate plane count for the DRM format.
5. Validate nonzero stride where required.
6. Validate `offset + requiredPlaneBytes` without overflow.
7. Validate subsampled plane dimensions for multi-plane formats.
8. Validate whether the renderer supports distinct FDs per plane; reject unsupported layouts before creating a buffer.
9. Keep the supported `(format, modifier)` set immutable for one feedback generation.

### Import behavior

1. Make `DmabufDelegate.dmabufImport` perform a real importability probe or create a reusable imported backing.
2. `create_immed` must fail synchronously with `invalid_wl_buffer` when import fails.
3. Async `create` sends `failed` without leaking transferred FDs.
4. Commit-time import reuses validated metadata and still handles allocation/device-loss failure.
5. Advertise only modifiers the Vulkan importer accepts, not the union of unrelated KMS capabilities.
6. Generate per-surface feedback tranches when scanout-device or direct-scanout preferences differ from the default tranche.

### Feedback table

1. Create the format-table FD with close-on-exec.
2. Size and write it with checked, complete write loops.
3. Seal it after population.
4. Encode `dev_t` using the protocol’s native array representation.
5. Reject tables exceeding the `UInt16` tranche-index space.

### Behavioral tests

- Params destruction, failed creation, successful buffer transfer, and buffer destruction each close every FD once.
- Mixed modifiers fail.
- Gapped, duplicate, excessive, undersized, and overflowing planes fail.
- `create_immed` rejects a renderer-incompatible buffer synchronously.
- Feedback contains only importable pairs and valid tranche indices.
- Repeated client connect/create/destroy cycles do not grow the process FD count.

### Completion gate

No raw owned FD is stored in a freely copyable value whose copies can independently close it.

## Phase 12 — Normalize DRM timing and sequence semantics

Make the clock advertised through `wp_presentation` match the clock carried by every page-flip event.

### Changes

1. Query `DRM_CAP_TIMESTAMP_MONOTONIC` during DRM capability discovery.
2. Store the selected presentation clock in the backend state.
3. When the kernel supplies monotonic timestamps, advertise `CLOCK_MONOTONIC`.
4. When it does not, convert events into one explicitly selected clock domain before they reach `DisplayLink` or Wayland clients.
5. Remove the hard-coded monotonic clock assumption from `RouterRenderDriver`.
6. Extend each CRTC’s 32-bit kernel sequence into a monotonic 64-bit sequence with wrap detection.
7. Reset sequence-extension state on topology generation replacement.
8. Use the full millihertz-derived interval from Phase 6 for `wp_presentation_feedback.presented`.
9. Validate narrowing into protocol fields.
10. Reject page-flip timestamps that move backward within one active generation and log enough state to diagnose the driver.

### Behavioral tests

- Monotonic and non-monotonic capability modes produce consistent advertised clocks.
- Sequence values extend correctly across `UInt32.max`.
- A new output generation resets wrap history without accepting a stale event.
- Fractional refresh values reach feedback without integer-hertz truncation.

### Completion gate

The C shim only transports kernel event values. Clock-domain policy and sequence extension are explicit Swift backend state.

## Phase 13 — Refactor ownership and module organization around the completed mechanisms

Perform this refactor after semantics are covered, so file movement does not hide behavior changes.

### Renderer

Split `RendererRuntime.swift` into:

- `RendererDevice.swift`: Vulkan/GBM bring-up and device-wide capabilities.
- `RendererOutputBinding.swift`: one output’s scanout/cursor resources.
- `RendererTopology.swift`: snapshot attachment and retirement.
- `RendererSubmission.swift`: composite and direct-scanout submission.
- `RendererPresentation.swift`: page-flip correlation and timing.
- `RendererClientBuffers.swift`: DMA-BUF/SHM import and explicit-sync retirement.

`RendererRuntime` remains the small main-actor coordinator conforming to `PresentationBackend`.

### Wayland runtime

1. Keep resource request decoding next to each protocol interface.
2. Move reusable mechanisms into narrowly named state types:
   - `SurfaceTransactionState`
   - `XdgConfigureLedger`
   - `SubsurfaceTopology`
   - `SeatSerialLedger`
   - `PopupGrabState`
   - `OutputGlobalState`
3. Move window placement and interaction policy out of wire-resource owners and into `NucleusCompositorWindowManager`.
4. Use one protocol-error helper that carries the target resource, typed error code, and diagnostic message.
5. Delete default delegate implementations that silently accept unsupported behavior.

### Swift 6.3/6.4 posture

1. Keep shared mutable compositor state main-actor isolated.
2. Use `MainActor.assumeIsolated` only at proven synchronous C callback boundaries executing on the compositor thread.
3. Pass typed IDs, immutable `Sendable` snapshots, scalars, and opaque handles across isolation/module seams.
4. Use `borrowing` for libdrm wrapper inspection and `consuming` when ownership crosses into a longer-lived owner.
5. Use `~Copyable` values for lexically scoped C resources and single reference owners when resources must live in collections.
6. Prefer typed throws for internal recoverable mechanisms. Translate to Wayland protocol errors or renderer diagnostics once at the boundary.
7. Mark closure isolation explicitly, including `@MainActor @Sendable` for callbacks retained by backend owners.
8. Avoid `nonisolated` protocol implementations that capture non-Sendable resource objects into actor closures. Extract scalar identity before the crossing.
9. Replace parallel Boolean flags with enums whose cases encode valid states.
10. Keep C++ imports out of non-C++ targets through the existing closure/protocol seams.

### Completion gate

Each large file has one primary responsibility, state transitions are enum-driven, and resource ownership is visible in types rather than comments alone.

## Phase 14 — Verification and completion gates

Verification is behavior-first. Do not add tests that inspect declaration names or source shape.

### Pure policy tests

- Global KMS matching and stable assignment.
- Output change-set calculation and placement.
- Redraw state transitions and request coalescing.
- Millihertz refresh conversion.
- Sequence extension.
- Configure-ledger consumption.
- Subsurface pending/current topology.
- Serial provenance.
- DMA-BUF layout validation.

### Wayland wire/runtime tests

Extend `NucleusCompositorWaylandRuntimeTests` with real request/event fixtures for:

- Output add, update, and removal.
- Core surface validation.
- Role conflicts.
- Nested synchronized subsurfaces.
- XDG initial configure, ack consumption, map/unmap/remap.
- Positioner validation and popup constraints.
- Popup and interactive serial validation.
- Multiple seat and device resources.
- Commit-correlated frame callbacks and presentation feedback.
- DMA-BUF error paths and resource destruction.

Assert protocol error codes, emitted event order, mapping state, callback/feedback disposition, and resource lifetime.

### Renderer/runtime tests

Extend `NucleusCompositorRendererLinuxTests` and `NucleusCompositorRenderRuntimeTests` for:

- Topology replacement and stale-generation rejection.
- Binding retirement with in-flight frames.
- Pause/resume state transitions.
- Composite/direct-scanout frame correlation.
- Exact presentation telemetry correlation.
- Output removal cleanup.
- Idle scheduler behavior with a fake event source.

### Host verification

Run verification after sourcing the repository host environment:

```sh
source core/tools/host-env.sh
swift test \
  --package-path compositor/compositor-core \
  -Xswiftc -cxx-interoperability-mode=default \
  $(pkg-config --cflags-only-I xcb-ewmh | sed 's/-I/-Xcc -I/g')
tools/nucleus doctor
tools/nucleus build
tools/nucleus test
```

Use targeted filters during each phase, then run the complete compositor package suite and top-level non-interactive gates after Phase 14. Do not launch the compositor as an agent-run verification step.

### User-owned hardware validation

After all agent-runnable gates pass, hand off these interactive checks:

1. Log into a single-output session.
2. Connect and disconnect a second output repeatedly.
3. Change mode, scale, and primary output.
4. Switch VT away and back with static windows, animation, video, and direct scanout.
5. Suspend/resume with outputs changed while suspended.
6. Exercise mixed-refresh outputs and a 59.94 Hz mode.
7. Exercise popup-heavy GTK and Qt applications.
8. Exercise touch-capability add/remove where hardware permits.
9. Run presentation-timing and DMA-BUF clients while monitoring compositor logs and FD counts.

## Final acceptance criteria

The compositor hardening work is complete when all of the following are true:

- One global allocator produces unique KMS connector/CRTC/plane assignments.
- One reconciler applies every output generation across renderer, server, Wayland, input, shell, and presentation state.
- Hot-unplug, final-output removal, replug, pause, and resume do not leave stale bindings or crash.
- Multi-output geometry never defaults every enabled output to the same origin.
- Idle outputs produce no periodic scene or render traversal.
- Refresh calculations preserve millihertz precision.
- Every frame callback and presentation feedback is tied to an exact sampled commit and completed or discarded once.
- Subsurface role, cycle, stacking, position, synchronization, mapping, and destruction rules pass behavioral wire tests.
- XDG configure serials, initial-map rules, positioners, popups, grabs, and interactive serials pass behavioral wire tests.
- Seat capabilities match the live device inventory and all client device resources receive correct events.
- DMA-BUF advertisement, creation validation, import, and FD ownership describe the same supported set.
- The advertised presentation clock matches every delivered presentation timestamp.
- FIFO and commit timing remain absent until their semantics are implemented in the completed commit/presentation scheduler.
- The existing explicit-sync, session-lock, main-actor, noncopyable-resource, and C++ boundary invariants remain intact.
