# Nucleus Foundation Follow-up Plan

## State invariant

Nucleus presents one coherent retained UI system through every host.

- Every `View`, `Window`, scene, platform service, visual publication, input
  sequence, accessibility object, async command, and animation belongs to one
  explicit semantic context and has one teardown path.
- `UIContext` owns semantic identity, environment, dirty generations, and the
  services used by its retained graph. No scene changes another scene through
  mutable process-global UI state.
- Native application, direct embedder, compositor overlay, out-of-process
  shell, and React Native hosts obey the same contracts where they expose the
  same capability. Each host projection proves its own translation instead of
  pretending every host constructs an identical tree.
- A clean UI produces no visual transaction, content registration, output
  acquisition, GPU work, or presentation. A localized change produces work
  proportional to its dirty ancestry and affected visual footprint.
- Presentation completion, compositor animation, snapshot retirement, and
  user-visible terminal state refer to the exact accepted frame that contains
  the relevant work.
- Application data flow remains retained and main-actor-owned. Observation
  updates existing retained objects; it does not introduce a second view tree,
  virtual DOM, or body-reconciliation pipeline.
- Text editing, menus, collections, input methods, pasteboard, accessibility,
  and drag-and-drop implement complete lifecycle and accessibility behavior
  before becoming public foundation claims.
- Swift, Wayland, DBus, io_uring, Vulkan, and C/C++ ownership is visible in
  types. Resource lifetime never depends on a swallowed error, a copyable raw
  handle that implicitly owns something, or an undocumented teardown order.

Complete the phases below in strict order. A phase is complete only when its
behavioral gate passes. Later phases extend the conformance harness established
earlier; they do not retroactively become prerequisites for an earlier gate.

## Host taxonomy

Use these names consistently in code, tests, diagnostics, and documentation:

1. **In-memory application host** — constructs a real `UIContext`,
   `WindowScene`, and retained UI graph without a platform window system.
2. **Direct publication embedder** — publishes a retained NucleusUI scene
   through `WindowScenePublicationContext` into a supplied render context.
3. **Compositor-embedded overlay host** — native NucleusUI running inside the
   compositor process for shell overlay content.
4. **Out-of-process shell host** — the separate Linux shell process using
   Wayland, React Native, and native shell services.
5. **React Native Fabric host** — translates supported Fabric mount mutations
   into retained NucleusUI component views and publishes them through the
   embedder.

The compositor-embedded overlay and the out-of-process shell are the two Linux
UI hosts. They are two host paths, not two machines. Environment and service
work must state explicitly whether it applies to one or both.

## Conformance boundaries

Do not build one universal test scene that conceals real host differences.
Use four explicit conformance boundaries:

1. **Retained-scene contract** — semantic identity, lifecycle, input, focus,
   accessibility, publication, and teardown for hosts that directly own a
   NucleusUI scene.
2. **Host-projection contract** — the supported subset translated by Fabric,
   Wayland, compositor overlay, or another adapter, including unsupported
   capability behavior.
3. **Renderer contract** — transaction application, retained render topology,
   damage, resources, output pixels, presentation, and retirement through one
   deterministic production-renderer path.
4. **Transport contract** — real Wayland and DBus message encoding, ordering,
   cancellation, descriptor ownership, reconnect, and disconnect cleanup.

Equivalent capability semantics are shared. Construction details and
platform-only behavior remain host-specific and are tested at the boundary
that owns them.

## Scope

This plan completes and proves the Nucleus application and UI foundations:

- Explicit context ownership of text, pasteboard, diagnostics, and environment
  updates.
- Layered semantic, renderer, host-projection, and transport conformance.
- Wayland clipboard and drag-and-drop in the out-of-process shell.
- Live AT-SPI transport and complete text-input protocol coverage.
- Environment propagation through both Linux UI hosts.
- Compositor tile crossfade and closing-fade lifecycle.
- Minimal retained observation with explicit ownership.
- Production multiline editing, desktop menus, virtualized collections, and
  async image/icon requests.
- Refactoring of stabilized publication, renderer, accessibility, and Wayland
  mechanisms without adding new owner layers.
- Swift 6.4 isolation, error, ownership, documentation, and optimized resource
  gates.

This plan does not:

- Port or rewrite Noctalia.
- Add a SwiftUI clone or a second reconciliation pipeline.
- Preserve deprecated service globals or compatibility wrappers.
- Reproduce the complete AppKit control catalog.
- Add generic controllers, service slots, protocols, or type erasure without
  a current consumer.
- Patch vendored React Native sources.
- Treat generated or third-party code as a refactor target unless a
  first-party boundary makes its ownership or behavior unsafe.

## Current baseline and remaining risks

The current foundation already establishes:

- Explicit semantic construction through `UIContext`.
- Retained `WindowScene` lifecycle and sparse visual publication.
- Accepted-cache-safe transaction publication and damage-aware repaint.
- Animation completion correlated with accepted or presented work.
- A Swift text-backend boundary with backend-owned layout handles.
- A neutral incremental accessibility tree and an AT-SPI projection model.
- Stable list and grid identity with bounded materialization.
- One compositor output-topology reconciliation path, retained render state,
  output redraw state, and commit-correlated presentation records.
- A snapshot-overlay layer API for compositor tile crossfades.
- Focused `ViewLayerPublisher` support files for traversal, diffing, cache
  deltas, paint caching, and metrics.

The remaining high-impact risks are:

1. `TextSystem.shared` and `Pasteboard.general` are process-global UI services
   despite scene-local semantic ownership.
2. Backend-dependent `Font`, `TextLayout`, and paint-registration APIs can be
   called without identifying the owning `UIContext`.
3. `Pasteboard.string` can return cached local content after an installed
   adapter reports an empty native clipboard.
4. The pasteboard adapter is synchronous and weakly held, so native transfer
   latency, cancellation, and ownership cannot be represented correctly.
5. The out-of-process shell does not project NucleusUI pasteboard operations
   through the compositor's privileged data-control protocol.
6. The AT-SPI export model has strong value-level coverage, but the complete
   live bus transport lacks an automated conformance fixture.
7. Shell text input has value-level coverage but lacks complete
   `zwp_text_input_v3` wire coverage.
8. Environment propagation is partial and does not yet define one explicit
   lifecycle for both Linux UI hosts.
9. NucleusUI lacks a platform-neutral drag-and-drop lifecycle and shell
   Wayland projection.
10. `TextView` is a size-growing `TextField` specialization rather than a
    scrolling multiline editor.
11. `Menu` is a flat stack of buttons, while compositor overlay code separately
    owns richer cascade behavior.
12. The compositor authors tile-crossfade opacity, but snapshot begin/end and
    closing-fade lifecycle are not connected to the live scene feeder.
13. Several stabilized mechanisms still combine unrelated responsibilities,
    including `View`, `RenderCore`, `InputDispatch`, and `XdgShell`.
14. `tools/collider test` executes every first-party debug package, including
    `platform-linux`, but does not yet execute the named release structural
    suites.

## Phase 1: Make UI platform services context-owned

### Service bundle

Add one main-actor `UIHostServices` value required by `UIContext`.

It contains:

- One `TextSystem`.
- One `Pasteboard`.
- One typed diagnostic sink for recoverable host-service failures.

Represent the diagnostic sink as an immutable main-actor `@Sendable` closure,
not a new protocol hierarchy. A diagnostic value carries service, operation,
resource identity when applicable, generation, and a typed failure reason.
`TextSystem`, `Pasteboard`, and later platform adapters route recoverable
failures through this one context sink.

The service value exposes immutable references. Replace a backend or adapter
through its owning service's explicit lifecycle API rather than swapping the
complete bundle after retained content exists.

Keep `UIEnvironment` as state owned directly by `UIContext`. Platform
environment adapters call `UIContext.updateEnvironment`; they are not stored
inside a generic service registry.

Do not add optional future slots. Add a service only with its first concrete
portable contract and host implementation.

Construct every `UIContext` with complete services before constructing its
first `View`, `Window`, controller, or scene. Provide an explicit deterministic
test-service constructor in test support. Do not provide a production default
that silently creates fallback services.

### Text API migration

Delete `TextSystem.shared` and all default arguments that resolve to it. Fix
every caller in the same phase.

Make every backend-dependent operation identify a text system:

- Font resolution and font metrics accept a `TextSystem`.
- `TextLayout` creation accepts a `TextSystem` or occurs through a
  context-bound view helper.
- Glyph lookup, caret geometry, selection geometry, and fallback layout use
  the system that owns the operation.
- Paint registration receives the publishing scene's `TextSystem`.
- Text controls derive the system from `view.uiContext.services`.
- React Native component views derive the system from their embedder
  `UIContext`.

Delete context-free convenience properties such as backend-resolved font
metrics when they cannot select the correct context.

Preserve backend ownership:

- A retained layout records the backend identity, backend generation, and
  installation generation that created it.
- A layout lease retains and releases through its creating backend even after
  that backend is replaced in its context.
- Replacing one context's backend invalidates new queries only in that
  context.
- Production hosts fail scene materialization with a typed diagnostic when a
  required production text backend is absent.
- Headless tests install an explicit deterministic backend.

Remove default `.shared` arguments from text-backend installation helpers.
Installation always names the target `TextSystem`.

### Pasteboard contract

Replace the optional adapter plus local cache with one required adapter:

- `InMemoryPasteboardAdapter` provides deterministic headless and test
  behavior.
- Platform hosts install a native adapter.
- A host that deliberately lacks pasteboard support installs an explicit
  unavailable adapter that reports a typed diagnostic.

`Pasteboard` strongly owns its installed adapter. Replacing or destroying the
pasteboard invokes one idempotent adapter shutdown path before releasing it.
The adapter owns its transfer tasks, protocol objects, buffers, and file
descriptors until shutdown completes.

Use command-shaped asynchronous operations:

- `readString() async throws -> String?`
- `writeString(_:) async throws`
- `clear() async throws`

An adapter returning `nil` means the native clipboard is empty. There is no
secondary cache to consult.

### Editing-command integration

Move copy, cut, and paste onto a scene-owned asynchronous command lifetime:

- Copy captures immutable selected text and reports success only after the
  adapter accepts the write.
- Cut removes text only after the write succeeds and only if the control,
  selection, and text generation still match the captured command.
- Paste captures control identity, focus identity, selection generation, and
  text generation before awaiting data.
- A late paste result is discarded after focus change, text mutation, scene
  disconnect, control removal, or command replacement.
- Secure fields expose neither copy nor cut and recheck secure-entry policy
  when an async result returns.
- Cancellation is idempotent and cannot run a completion after teardown.
- Keyboard, menu, and accessibility command dispatch observe the same command
  result.

Do not hide a blocking descriptor read inside a synchronous property or main
actor callback.

### Host construction

Update service construction in this order:

1. In-memory application host and test composition roots.
2. Direct publication embedder.
3. Compositor-embedded overlay host.
4. Out-of-process shell host.
5. React Native Fabric host.

`PlatformAppHost` and embedder materialization receive the visual context and
complete `UIHostServices` before invoking retained-content construction.

### Behavioral gate

Verify:

- No `TextSystem.shared`, `Pasteboard.general`, or equivalent fallback global
  remains.
- Two live contexts can use different text backends and pasteboards without
  cross-invalidation.
- Replacing or destroying one context releases only its service objects and
  layouts.
- A native-empty clipboard cannot reveal previous local content.
- Copy, cut, and paste handle success, failure, cancellation, replacement, and
  late completion without corrupting editing state.
- Every production and test host supplies services before retained UI
  materialization.

## Phase 2: Establish layered foundation conformance

### Test-support structure

Add first-party test-support targets for:

- Retained-scene scenarios and semantic assertions.
- Host capability declarations and host-specific drivers.
- Render transaction application and retained-tree inspection.
- Deterministic pixel fixtures.
- Resource and work counters.

The support targets may use public API and the existing compositor SPI. They
must not inspect source shape, duplicate production lifecycle logic, or infer
identity from allocation order.

### Baseline retained-scene scenario

Create a small baseline scene using capabilities already complete after Phase
1:

- Two ordered windows with distinct activation behavior.
- Stack, flex, and grid layout.
- A clipped and transformed scroll hierarchy.
- Static text, image, path, gradient, shadow, backdrop, and material content.
- Buttons, toggles, sliders, segmented controls, selects, popovers, tooltips,
  text fields, and secure fields.
- Stable accessibility roots, relationships, values, actions, and focus.
- Retained and main-actor animations with accepted and presented completion.

Assign stable semantic identifiers to every assertion target.

Do not place multiline editing, desktop menus, drag-and-drop, live AT-SPI, or
another later capability in the baseline gate. Each later phase adds its own
scenario to this harness.

### Retained-scene drivers

Run the retained-scene contract through:

1. The in-memory application host.
2. The direct publication embedder.
3. The compositor-embedded overlay publication host.

Assert:

- Construction assigns every retained object to the expected `UIContext`.
- First publication creates one coherent visual topology.
- Repeated clean publication emits no transaction.
- Local geometry, visibility, style, content, transform, scroll,
  accessibility, and animation changes update only expected state.
- Reparent, reorder, hide/show, activation, removal, and scene disconnect
  preserve identity and teardown contracts.
- Pointer capture, responder routing, focus traversal, and key-window changes
  have one semantic result.
- Secure text remains redacted from accessibility and clipboard behavior.
- Animation replacement, cancellation, reduced motion, accepted completion,
  and presented completion produce exactly one terminal result.

### Host-projection drivers

Use capability-specific fixtures instead of forcing the complete baseline
scene through every projection:

- Fabric drives root, view, text, and image mount mutations through the real
  mounting consumer and embedder publication path.
- The out-of-process shell fixture drives real Wayland surface, input, output,
  and lifecycle messages.
- Compositor-overlay projection tests exercise only overlay-specific
  materialization, surface association, environment, and input glue; the
  retained-scene suite already owns its common UI semantics.

For every supported capability, assert equivalent semantic topology,
environment, resource ownership, publication, and teardown. For an unsupported
capability, assert a documented rejection or omission rather than silent
partial behavior.

### Real transaction application

Apply authored work through `RenderTransactionApply` and the retained render
tree.

Assert:

- Created, reparented, hidden, and removed render nodes match semantic
  topology.
- Geometry narrows once and remains finite.
- Content registrations resolve to live resources in the accepted generation.
- Rejected commits leave publisher caches retryable.
- Old and new presentation footprints produce correct damage.
- Presentation completion resolves only handles associated with the accepted
  frame.
- Teardown retires render nodes, paint registrations, text handles, image
  handles, runtime effects, snapshots, and animations.

### Renderer fixtures

Use one deterministic production paint-lowering and renderer path for pixel
contracts:

- Reflection, skew, rotation, and collapsed affine axes.
- Path fill rules, strokes, arcs, clips, and save/restore.
- Text glyph placement, baselines, wrapping, truncation, selection, and caret
  geometry.
- Images, masks, tinting, saturation, and content modes.
- Blend modes, opacity, shadows, backdrop materials, and nested clips.
- Backing scale and fractional-scale conversion.
- Localized repaint preserving pixels outside damage.
- Full repaint promotion for nonlocal effects and composite-property changes.

Record the renderer backend, color format, color space, and tolerance with each
fixture family. Use exact pixels where deterministic. Use a channel tolerance
only for a documented native-backend variance.

### Structural performance contracts

Create release-configuration tests that assert counters rather than machine
timing:

- Deep trees use a flat linear traversal.
- Wide trees perform no per-parent subtree copying.
- Clean publication keeps visits, commits, registrations, acquisitions, and
  presentations at zero.
- One leaf change bounds visits, snapshots, property updates, paint bytes, and
  damage.
- Repeated window, popover, tooltip, and scene lifecycle returns resource
  counters to baseline.
- Rejected commits, output loss, and presentation cancellation release every
  completion handle.

Tracy explains failures; test assertions decide pass or fail.

### Behavioral gate

- The baseline retained-scene contract passes through all native scene
  drivers.
- Fabric and shell projection fixtures pass their declared capability
  contracts.
- Renderer fixtures exercise actual transaction application and output pixels.
- Structural stress tests enforce bounded work and resource lifetime.
- Failures identify the semantic, publication, projection, renderer, or
  presentation boundary responsible.

## Phase 3: Implement the shell Wayland pasteboard

### Data-control client

Implement the out-of-process shell's pasteboard adapter using the compositor's
privileged `ext-data-control-v1` path.

The adapter:

- Binds one manager and creates one device for the active seat.
- Tracks selection offers and immutable advertised MIME metadata.
- Prefers UTF-8 plain-text MIME types in a documented deterministic order.
- Reads offers without blocking the main actor or shell loop.
- Writes immutable `Sendable` payloads through owned pipe descriptors.
- Keeps an offered source alive until cancellation, replacement, or shutdown.
- Handles source cancellation, seat replacement, compositor reconnect, and
  shell shutdown idempotently.
- Enforces configured byte and time bounds.
- Reports transport failures through the owning context diagnostic sink.

Use move-only lexical descriptor owners and single-reference stored owners.
Long-lived transfer state never owns a copyable raw descriptor integer.

### Transfer execution

Drive descriptor readiness through the existing shell loop mechanisms:

- Read and write only after readiness notification.
- Handle partial reads, partial writes, `EINTR`, `EAGAIN`, peer closure, and
  cancellation.
- Close each descriptor exactly once.
- Bound accumulated read storage before appending.
- Do not retain UI controls or scenes from transfer tasks.
- Return immutable results to the main actor and apply them through the Phase
  1 command-generation checks.

### Client/server fixture

Add a deterministic Wayland client/server fixture covering:

- Cross-client copy and paste.
- Empty selection and explicit clearing.
- Source replacement and cancellation.
- MIME negotiation and unsupported MIME sets.
- Payloads spanning multiple reads and writes.
- Transfer-size rejection.
- Seat replacement and compositor reconnect.
- Source, offer, device, task, buffer, and descriptor cleanup on disconnect.

Exercise the production compositor data-control implementation and the
production shell adapter.

### Behavioral gate

- Shell copy, cut, paste, and clear use the native Wayland selection.
- Reads never block the main actor or shell loop.
- Empty native selection returns `nil` with no cached fallback.
- Cancellation and disconnect close every descriptor exactly once.
- Repeated transfer and reconnect fixtures return all protocol and native
  resources to baseline.

## Phase 4: Prove live AT-SPI transport

### Private test bus

Start an isolated test accessibility bus owned by the test process. Connect
the production `AtSPIService` through its normal connection and registration
path.

The fixture owns bus startup, address publication, connection, name
acquisition, teardown, and process cleanup. A failed test cannot leave a bus,
socket, watch, timeout, or child process alive.

### Interface conformance

Use actual DBus messages to verify:

- Application registration and deregistration.
- Root and child enumeration.
- Stable object paths across property-only updates.
- Accessible and Application properties and methods.
- Action and Component operations.
- Text and EditableText ranges and mutations.
- Selection and Value operations.
- Role, state, relation, coordinate, and enum encoding.
- Focus, state, property, text, selection, live-region, insertion, and removal
  events.
- Virtualized offscreen accessible elements.
- Secure-text redaction through every interface and event.

Retain pure `AtSPIExportModel` tests for projection policy. Bus tests prove
transport and lifecycle.

### Action and failure lifecycle

- Decode and validate DBus arguments before entering the main actor.
- Dispatch actions onto the owning `UIContext`.
- Reject actions after object removal or scene disconnect.
- Encode one typed DBus error at the request boundary.
- Handle bus loss, name loss, reconnect, and shutdown without duplicate
  registration.
- Bound queued events during disconnect.
- Deduplicate persistent transport diagnostics by operation and generation.

### Behavioral gate

- Every claimed AT-SPI interface passes live message-level tests.
- Object paths and event identities remain stable through incremental updates.
- Secure data never appears in replies, errors, signals, or diagnostics.
- Bus loss and reconnect restore one coherent exported tree.
- Repeated registration and teardown return DBus objects, slots, watches,
  messages, and native allocations to baseline.

## Phase 5: Complete Wayland text-input transport

### Wire fixture

Drive the shell's production `zwp_text_input_v3` listener and request path
through a deterministic client/server fixture.

Cover:

- Enable, disable, focus replacement, and window teardown.
- Surrounding-text UTF-8 byte offsets and UTF-16 editor-model conversion.
- Preedit text, cursor range, style spans, replacement, and cancellation.
- Commit strings and delete-surrounding-text in both directions.
- Cursor rectangle updates through view, window, surface, and output
  coordinates.
- Content hints and purposes.
- Protocol serial and commit-count ordering.
- Multilingual grapheme clusters, combining marks, emoji, and bidirectional
  text.
- Secure fields exporting neither surrounding nor selected text.

### State ownership

- One seat text-input object owns protocol state.
- One focused editor session owns semantic composition state.
- Focus replacement terminates the old session before enabling the new one.
- Protocol callbacks carry value snapshots across isolation boundaries.
- Stale serials and callbacks cannot mutate a replacement session.
- Surface, window, seat, and connection teardown converge on one idempotent
  cancellation path.

### Candidate geometry

Compute candidate geometry from the retained editor caret:

1. Resolve the current UTF-16 caret through the creating text backend.
2. Convert through content scrolling and view transforms.
3. Convert through window and surface placement.
4. Narrow and round once at the Wayland request boundary.

Reject nonfinite geometry before sending a protocol request. Recompute after
layout, scroll, scale, transform, composition, and focus changes.

### Behavioral gate

- Text-input behavior passes real request and event transport tests.
- Offset conversion is correct for multilingual and malformed-boundary cases.
- Secure entry exports no private text.
- Candidate geometry matches the retained caret after every coordinate-space
  change.
- Replacement, stale callbacks, disconnect, and teardown cannot mutate a dead
  editor session.

## Phase 6: Make Linux environment propagation explicit

### Portable environment snapshot

Normalize platform settings into one immutable `UIEnvironment` update:

- Light or dark appearance.
- Increased contrast.
- Reduced motion.
- Reduced transparency.
- Text scale.

Normalize invalid, missing, and unknown values once in the platform adapter.
`UIContext` receives only portable values.

### Compositor-embedded overlay

Replace process-global appearance mutation with the shared Linux portal adapter:

- The compositor service owner creates and retains one adapter instance.
- Overlay scene materialization receives the adapter's normalized default
  snapshot before constructing views.
- The adapter queues one cancellable asynchronous portal snapshot; it never
  blocks compositor bring-up on D-Bus round trips.
- Portal updates apply only to the overlay's `UIContext`.
- Overlay teardown stops the adapter before releasing the context.

Delete `AppearancePortal.shared` after fixing all callers. Do not replace it
with another mutable singleton.

### Out-of-process shell

Install a separate environment adapter owned by `ShellHost`:

- Construct the shell UI context with the normalized default snapshot, then
  apply the cancellable asynchronous portal snapshot through that context.
- Apply updates to the React Native surface's owning `UIContext`.
- Reconnect after bus loss without duplicating subscriptions.
- Stop subscriptions before RN surface, Wayland, or render teardown.

The shell process does not reach into compositor process state. Each process
owns its adapter and receives the same normalized semantics from its platform
source.

### Dependency invalidation

- Environment reads register dependencies on the owning `UIContext`.
- A changed field invalidates only views that consumed that field.
- An unchanged normalized snapshot performs no semantic or visual work.
- Reduced motion updates active and future animations through one documented
  policy.
- Text-scale changes invalidate affected font metrics and layouts in the same
  context only.

### Behavioral gate

- Both Linux UI hosts receive a normalized environment before view construction
  and apply portal state asynchronously without blocking their reactors.
- Runtime updates affect only the intended context and dependent views.
- No mutable global appearance source remains.
- Unchanged updates produce no publication.
- Bus loss, reconnect, context destruction, and host shutdown leave no active
  subscriptions or callbacks.

## Phase 7: Add portable drag-and-drop and its Wayland projection

### Portable retained contract

Add one NucleusUI drag-and-drop lifecycle:

- Stable drag-session identity.
- Immutable offered type metadata.
- Async bounded payload loading.
- Enter, update, exit, drop, cancellation, and source-completion events.
- Explicit accepted-operation negotiation.
- Drag preview ownership and teardown.
- Accessibility actions providing equivalent non-pointer operations.
- Coordinate conversion through transformed and scrolled views.

The session owner belongs to the input sequence and owning `UIContext`.
Targets retain neither platform offers nor raw descriptors.

### Source and target state

- A source captures immutable offer metadata and payload providers.
- A target declares accepted types and operation for the current update.
- A drop applies only while session, target, scene, and offer generations
  remain current.
- Leaving a target cancels its pending payload request.
- Source completion occurs exactly once with performed, cancelled, rejected,
  or failed outcome.
- Preview content is removed on every terminal path.

### Wayland projection

Project the portable lifecycle through the out-of-process shell and the
compositor's existing data-device mechanisms:

- Map Wayland offers, actions, serials, and surface coordinates once at the
  adapter boundary.
- Use owned descriptor transfers from Phase 3.
- Keep drag state separate from clipboard selection state even though both
  use Wayland data offers.
- Validate serial and focus authority before starting or accepting a drag.
- Cancel sessions on source, offer, surface, seat, connection, or scene
  teardown.

### Behavioral gate

- Pointer and accessibility drag operations produce the same semantic result.
- Enter/update/exit/drop ordering passes portable and Wayland wire fixtures.
- Async payload results cannot apply to a stale target or session.
- Clipboard and drag replacement do not corrupt one another.
- Repeated drag, cancellation, disconnect, and teardown return previews,
  offers, sources, buffers, tasks, and descriptors to baseline.

## Phase 8: Complete compositor snapshot and closing transitions

### Architecture boundary

Use the existing retained snapshot-overlay layer mechanism. Do not reintroduce
a generic renderer transition queue, transition record hierarchy,
presentation-operation service, or second animation system.

The compositor window model owns transition policy and generation. The scene
feeder translates current presentation state into ordinary retained layer
topology, geometry, content, and opacity. The renderer owns snapshot texture
production and retirement.

### Tile content crossfade

At tile-transition start:

1. Identify the last accepted live content at the transition boundary.
2. Capture it through the production snapshot path.
3. Register one retained snapshot resource.
4. Call `WindowSceneAuthor.beginContentCrossfade`.
5. Store snapshot identity and transition generation on the window
   presentation state.
6. Request frames through the output redraw state machine.

For each authored frame:

- Sample geometry and overlay opacity from the same predicted presentation
  time.
- Keep overlay geometry identical to live backing geometry.
- Continue requesting frames while geometry or opacity changes.
- Keep current live client content below the dissolving snapshot.

At settle, supersession, cancellation, output loss, session lock, or teardown:

1. Mark one terminal transition result.
2. Remove the overlay through `endContentCrossfade`.
3. Release the snapshot after the accepted removal guarantees the renderer can
   no longer reference it.
4. Clear generation state.

A second tile operation replaces the transition generation atomically. A late
capture or completion from the replaced generation is discarded and retired.

### Closing fade

On unmap or close:

- Stop accepting input immediately.
- Freeze geometry at the close boundary.
- Capture the last accepted visual content when client-buffer lifetime cannot
  outlive the fade.
- Keep the window in scene topology while presentation-time opacity is
  nonzero.
- Drive opacity from the output presentation clock.
- Remove topology and release retained content only after terminal accepted
  removal or cancellation.
- Cancel immediately for session-lock security transitions, host shutdown, or
  another policy that forbids retained content.

Client buffer lifetime never depends on the visual fade.

### Correctness fixtures

Add deterministic coverage for:

- Tile begin, midpoint, settle, cancellation, and supersession.
- A second tile while capture or crossfade is active.
- Closing a static, animating, direct-scanout, and crossfading window.
- Client content replacement during capture and transition.
- Output removal, refresh change, and scale change.
- Session-lock activation while a transition is visible.
- Snapshot registration, accepted use, removal, and retirement.
- Exactly-once terminal completion.

Remove stale comments as part of the behavior change.

### Render and presentation gate

Verify:

- Composite-to-scanout and scanout-to-composite changes.
- Localized damage under animated geometry.
- Fractional-scale and transformed damage rounding.
- Mixed-refresh scheduling and fractional millihertz modes.
- Frame callback and presentation-feedback correlation.
- Explicit synchronization and DMA-BUF retirement.
- Clean idle after transition completion.

Add Tracy zones and counters for snapshot capture, live snapshot count,
transition generation, scanout eligibility change, output acquisition,
submitted damage, accepted removal, and retirement. Structural tests assert
the counters return to baseline.

The phase is complete when every agent-runnable transition, renderer, and
presentation gate passes. Physical display validation remains the explicit
handoff in Phase 15.

## Phase 9: Add minimal retained observation

### Observation contract

Keep the retained model:

- Views are constructed once and retain identity.
- Application models own domain state.
- Observation writes values into existing views and controllers.
- Structural replacement remains explicit.
- Publication continues to observe NucleusUI dirty generations, not
  application observation internals.

Do not re-run arbitrary view bodies.

### Lifecycle-bound token

Add one main-actor observation token owned by a retained lifecycle owner.

It:

- Uses Swift Observation to record dependencies read by one update closure.
- Re-registers dependency tracking immediately after each executed update.
- Coalesces model notifications until the next semantic update boundary.
- Executes in the owning `UIContext`.
- Applies an explicit `TransactionConfiguration`.
- Cancels when its view, controller, window, or scene disconnects.
- Uses an explicit strong or weak model-capture policy.
- Never invokes its update or completion after cancellation.

Expose a focused API on `View` and `ViewController`. Keep bookkeeping private.
Keep the API package-scoped until a production consumer demonstrates the
public shape.

### Scope control

Do not add generic snapshot, selection, form, search, or async-resource
controllers in this phase. Add such a controller only in the later phase that
has a concrete repeated consumer and can delete more manual state than it
introduces.

### Behavioral gate

Verify:

- A model property update changes an existing retained view.
- Multiple writes coalesce into one semantic update and one publication.
- Dependency changes stop observing values no longer read.
- Removing a view or disconnecting a scene cancels its observations.
- Animated updates preserve immediate semantic state and presentation-time
  completion.
- Two contexts observing the same immutable value remain isolated in mutation
  and teardown.
- Repeated observation creation and cancellation returns tokens, closures,
  tasks, and completion handles to baseline.

## Phase 10: Replace `TextView` with a scrolling multiline editor

### Ownership and composition

Replace the `TextField` subclass with a composite editor:

- `TextView` owns a clipping `ScrollView`.
- A dedicated text-content view records glyphs, selection, composition, and
  caret.
- `TextEditorModel` remains the editing-state owner shared with `TextField`.
- Shared editing commands live in focused helpers rather than inheritance.

Delete the old specialization and fix callers in the same phase.

### Layout model

Implement:

- Width-constrained shaping and reflow.
- Independent document, content, and viewport sizes.
- Vertical and horizontal scrolling policies.
- Paragraph-indexed layout records with stable paragraph identity and content
  revision.
- Reuse of unchanged paragraph layouts across local edits.
- Bounded layout and geometry caches around the visible range.
- Deterministic invalidation after width, text scale, font, paragraph style,
  backend generation, or appearance changes.

Do not make incremental behavior an optional backend promise. Split the
document into paragraph layout requests above the existing text backend so an
edit does not reshape unrelated paragraphs.

### Editing behavior

Implement:

- Multiline hit testing, caret movement, and selection.
- Up, down, page up, page down, home, end, document start, and document end.
- Preferred horizontal caret position across vertical movement.
- Word, line, paragraph, and document selection.
- Selection autoscroll during pointer drag and input-method updates.
- Caret visibility after edit, undo, redo, composition, resize, and focus.
- Async paste generation handling from Phase 1.
- Candidate geometry through the Phase 5 coordinate contract.

Secure multiline entry remains unsupported. Reject it at construction rather
than expose incomplete redaction.

### Accessibility

- Expose Text and EditableText ranges in the editor model's UTF-16 space.
- Convert visible and offscreen range geometry through scrolling.
- Preserve accessible identity while paragraph views are recycled.
- Emit bounded text and selection events for one semantic edit.
- Never materialize the full document solely for accessibility enumeration.

### Behavioral gate

- `TextView` scrolls instead of growing indefinitely.
- Editing, selection, composition, undo, paste, and navigation pass
  multilingual behavior tests.
- Local paragraph edits do not recreate layouts for unaffected paragraphs.
- Visible materialization and layout caches remain bounded during long
  document scrolling.
- Focus, accessibility, input-method, and teardown contracts pass through the
  retained-scene and shell projection harnesses.

## Phase 11: Implement one retained desktop menu system

### Menu model

Replace the flat button stack with a retained model containing stable item
identity:

- Commands.
- Separators.
- Nested submenus.
- Checked items and radio groups.
- Alternate items.
- Title, glyph, key equivalent, enabled state, hidden state, and
  accessibility label.

Command validation runs immediately before presentation and activation.
Updating one item preserves unaffected item and submenu identity.

### Presentation controller

One menu presentation controller owns:

- Root and submenu panel lifecycle.
- Current keyboard and pointer selection.
- Delayed submenu opening.
- Pointer-aim tolerance.
- Placement within the current output work area.
- Dismissal cascades.
- Focus capture and restoration.
- Command activation and terminal result.

Menus remain portable retained content presented through `Popover`. Wayland
popup serial, configure, and surface lifetime remain in the shell adapter.

### Interaction and accessibility

Support:

- Up/down, home/end, left/right, escape, enter, mnemonics, and type-ahead.
- Pointer hover, press-drag-release, sticky click-open, submenu traversal, and
  outside dismissal.
- Screen-edge flipping and output-aware placement.
- Accessible Menu and MenuItem topology, state, actions, checked state, and
  focus events.
- Reduced-motion behavior without changing semantic ordering.

### Remove duplicate cascade ownership

Migrate compositor-overlay menus to the foundation menu model and controller.
Delete its separate panel-stack, selection, dismissal, and submenu-delay
implementation once foundation behavior covers the overlay requirements.
Keep only overlay-specific command data and host presentation wiring.

### Behavioral gate

- Keyboard, pointer, submenu, placement, validation, focus, and accessibility
  behavior passes retained-scene tests.
- Compositor overlay menus use the same portable menu implementation.
- Wayland popup tests prove serial/configure/teardown projection separately.
- Repeated open, cascade, activation, cancellation, output change, and scene
  teardown returns panels, focus state, timers, observations, and layers to
  baseline.

## Phase 12: Complete virtualized collection behavior

### Snapshot application

Extend list and grid snapshots with:

- Stable insertion, removal, and movement.
- Deterministic content-revision invalidation.
- Scroll-position preservation.
- Focus and accessibility preservation.
- Exactly one retained view for each materialized item identity.

Apply snapshot changes directly through existing list and grid owners. Do not
add a generic snapshot controller unless at least two production consumers
need identical coordination beyond the collection API.

### Selection and navigation

Implement:

- Single and range selection with keyboard and pointer anchors.
- Type-ahead focus when textual item metadata exists.
- Directional navigation for variable-size grid geometry.
- Selection behavior across insertion, removal, filtering, and movement.
- Accessible selection actions and offscreen virtual elements.

Model selection identity separately from focused and materialized view
identity.

### Reordering

Use the Phase 7 drag session:

- Start with stable item and collection identity.
- Negotiate move or copy explicitly.
- Show one owned insertion preview.
- Autoscroll near viewport edges.
- Apply only against the snapshot generation that accepted the drop.
- Reject or rebase a stale drop through one documented collection policy.
- Preserve focus, selection, and scroll anchor after application.

### Variable measurement

- Cache measurement by item identity, content revision, width constraint,
  environment generation, and backing scale.
- Bound the cache and reuse pool.
- Invalidate only affected layout ranges.
- Avoid array front-removal in scroll and reuse hot paths.

### Behavioral gate

- Snapshot changes preserve stable identity and bounded materialization.
- Selection, focus, accessibility, and scroll anchors survive movement and
  recycling.
- Reordering passes portable and Wayland drag fixtures.
- Variable-size scrolling bounds measurement, view, layer, paint, text,
  image, and reuse-pool counts.
- Repeated snapshot mutation and teardown returns every retained resource to
  baseline.

## Phase 13: Add retained async image and icon requests

### One resource pipeline

Build the UI request layer over the existing `ImageResource`, decode queue,
renderer registration, and host resource seams. Do not introduce a second
decode queue, renderer registry, or unbounded process cache.

A request contains:

- Stable semantic request identity.
- Source identity.
- Decode target size and backing scale.
- Appearance and icon-theme generation.
- Cancellation generation.

### Request lifecycle

- Background work consumes immutable `Sendable` request values.
- Results return through one main-actor application point.
- A stale generation cannot replace a newer result.
- Removing the consumer or disconnecting the scene cancels outstanding work.
- Placeholder and failure presentation belong to consumer policy.
- Missing results use bounded negative caching.
- Theme and appearance changes invalidate only affected icon requests.

### Cache ownership

One cache owner defines:

- Byte and entry bounds.
- Cost accounting for decoded resources.
- Eviction behavior.
- In-flight request coalescing.
- Negative-result lifetime.
- Host and resource-generation separation.
- Shutdown and memory-pressure behavior.

Renderer registrations retire through their existing host lifecycle after the
last accepted consumer releases them.

### Behavioral gate

- Duplicate requests coalesce without duplicating decode or registration.
- Cancellation and stale generation prevent late UI mutation.
- Decode, cache, renderer, and UI ownership remain distinct and explicit.
- Theme, appearance, scale, failure, and retry behavior pass retained-scene
  and Fabric projection tests.
- Continuous image-list scrolling remains within cache, decode, registration,
  and memory bounds.

## Phase 14: Refactor stabilized mechanisms and finish Swift 6.4 hygiene

Behavioral and transport tests from prior phases pin semantics before these
structural changes.

### Finish `ViewLayerPublisher` decomposition

Keep one publisher authority. Retain the current focused files for traversal,
diffing, cache deltas, paint caching, and metrics.

Move only residual mechanisms that still obscure the publication state
machine:

- Animation and transaction-completion binding.
- Root attachment and accepted-cache application.
- Content registration dispatch not already owned by `ViewPaintCache`.

Keep orchestration, the sole accepted-cache authority, and the commit boundary
in `ViewLayerPublisher`. Do not add protocol dispatch to the traversal or diff
hot path.

### Split `View` by implementation responsibility

Keep one public `View` type and one stored-state owner. Move implementation
into responsibility-based files:

- Hierarchy and context ownership.
- Geometry and coordinate conversion.
- Layout invalidation and measurement.
- Display invalidation and recording.
- Input, tracking, cursor, and hit testing.
- Focus and responder behavior.
- Environment and appearance.
- Accessibility.
- Animation state.

Extensions organize mechanisms. They do not create manager objects mirroring
`View` state.

### Split live AT-SPI transport

Keep `AtSPIExportModel` as the pure policy boundary. Separate:

- Bus discovery, registration, reconnect, and teardown.
- Object-path and interface dispatch.
- Argument decoding and validation.
- Reply and error encoding.
- Accessible/Application, Action/Component, Text/EditableText, and
  Selection/Value interfaces.
- Event encoding and emission.
- Role, state, relation, coordinate, and enum mapping.

One connection owner retains every DBus object and slot.

### Split render orchestration

Keep one `RenderCore` owner and one scheduling/resource path. Move focused
implementation into:

- Transaction acceptance and retained-tree application.
- Frame demand and output scheduling.
- Resource registration and retirement.
- Paint and image production.
- Snapshot capture.
- Presentation submission and completion.
- Shutdown.

The split must not add a second queue, registry, completion service, or
transition abstraction.

### Split Wayland mechanics

Refactor `InputDispatch` and `XdgShell` around:

- Request decoding.
- Protocol state and ledgers.
- Serial validation.
- Policy decisions.
- Window-manager execution.
- Event projection.
- Resource destruction and client disconnect.

Translate protocol errors exactly once at request boundaries. Each Wayland
resource has one Swift owner and one idempotent destruction path.

### Error and diagnostic audit

Remove swallowed errors from:

- Interactive move and resize.
- Scene author operations.
- Platform service installation.
- DBus transport.
- Render transaction application.
- Snapshot capture and retirement.
- Clipboard, drag, and async resource transfers.

Use typed throws internally. At the owning boundary, convert each error into
one of:

- Host diagnostic.
- Wayland or DBus protocol error.
- Command or transition cancellation outcome.
- Programmer precondition for an impossible invariant.

Deduplicate persistent diagnostics by operation, resource identity, and
generation.

### Isolation and native ownership audit

Inventory every:

- `@unchecked Sendable`.
- `nonisolated(unsafe)`.
- `unowned` reference.
- Retained closure crossing an actor or C callback boundary.
- Raw file descriptor.
- Wayland resource pointer.
- DBus message, slot, watch, and timeout.
- Vulkan handle.
- C++ resource handle and opaque pointer.

Apply these rules:

- Mutable UI, compositor, and protocol state stays executor-isolated.
- Executor crossings carry immutable `Sendable` values.
- `Mutex` protects only genuine synchronous sharing that cannot use an actor.
- Lexical native resources use move-only owners.
- Collection-stored native resources use single-reference owners.
- Actor hops capture scalar identity instead of non-Sendable handles.
- Retained closures declare `@Sendable` and their intended global actor.
- `unowned` is replaced where external teardown can reverse owner order.
- Unchecked conformance remains only where the native access contract is
  documented and mechanically enforced.

### Cross-language boundary audit

- Non-C++ modules do not import C++ modules.
- C++ bring-up installs typed closure tables or conforms to portable Swift
  seams.
- Closure-table payloads contain opaque handles and scalars only.
- Genuine C entry points use `@c` declarations.
- Buffer pointer validity, element count, byte count, alignment, and callback
  lifetime are documented at each C/C++ boundary.
- Every retained unmanaged pointer has one named release owner.
- Integer narrowing, multiplication, offset calculation, and length
  conversion are checked before crossing languages.

### Public API hygiene

- Generate symbol graphs for public foundation modules.
- Document actor isolation, ownership, coordinate space, units, lifetime, and
  errors for public API where applicable.
- Remove Apple-shaped names whose behavior does not match the documented
  subset.
- Change package-connection implementation details from `public` to `package`
  or the existing compositor SPI.
- Use typed IDs instead of unrelated integer handles at Swift boundaries.
- Delete replaced APIs and fix all callers in this phase.

### Behavioral gate

- Large mechanisms have focused implementation boundaries and one visible
  owner.
- Refactors preserve all prior semantic, wire, pixel, and resource results.
- Hot-path allocations and structural counters do not regress.
- Every recoverable failure reaches a typed outcome or diagnostic.
- Native lifetime assumptions are enforced by an owner type and teardown
  operation.
- Public API documentation matches actual behavior and host obligations.

## Phase 15: Final automated verification and hardware handoff

### Make the repository test command authoritative

Correct the workspace orchestrator before relying on its final result:

- The shell test action runs `swift test`, not `swift build`.
- The compositor test action runs both `compositor-core` and `compositor`
  package tests.
- A component with test targets cannot silently substitute a build.
- The command reports the component and package that failed.

### Complete host commands

Source the actual host environment and run:

```sh
source tools/host-env.sh
tools/collider doctor
tools/collider build
tools/collider test
```

While correcting the orchestrator, verify its coverage against these package
entry points:

```sh
swift test --package-path core -Xswiftc -cxx-interoperability-mode=default
swift test --package-path platform-linux
swift test --package-path react-native -Xswiftc -cxx-interoperability-mode=default
swift test --package-path compositor/compositor-core -Xswiftc -cxx-interoperability-mode=default
swift test --package-path compositor/compositor
swift test --package-path shell
```

Do not launch the compositor or shell as an agent-run verification step.

### Behavioral verification

Run:

- Retained-scene conformance.
- Fabric and shell host-projection conformance.
- Graphics pixel fixtures.
- Text, editing, pasteboard, and input-method suites.
- Live AT-SPI bus conformance.
- Clipboard and drag Wayland client/server fixtures.
- Compositor Wayland wire conformance.
- Renderer, snapshot, transition, and presentation suites.
- Observation lifecycle.
- Multiline editor.
- Menu and overlay-menu migration.
- Collection snapshot, selection, and reordering.
- Async image and icon lifecycle.
- Deterministic randomized semantic, geometry, editing, collection,
  accessibility, transport, and teardown cases.

Every randomized test records its seed on failure.

### Release-configuration structural stress

Create named release-configuration suites and run them directly:

- `NucleusFoundationPublicationStressTests`
- `NucleusFoundationLifecycleStressTests`
- `NucleusTextEditorStressTests`
- `NucleusCollectionStressTests`
- `NucleusPlatformTransportStressTests`
- `NucleusCompositorTransitionStressTests`

Run them through their owning packages:

```sh
swift test -c release --package-path core -Xswiftc -cxx-interoperability-mode=default --filter NucleusFoundationPublicationStressTests
swift test -c release --package-path core -Xswiftc -cxx-interoperability-mode=default --filter NucleusFoundationLifecycleStressTests
swift test -c release --package-path core -Xswiftc -cxx-interoperability-mode=default --filter NucleusTextEditorStressTests
swift test -c release --package-path core -Xswiftc -cxx-interoperability-mode=default --filter NucleusCollectionStressTests
swift test -c release --package-path shell --filter NucleusPlatformTransportStressTests
swift test -c release --package-path compositor/compositor-core -Xswiftc -cxx-interoperability-mode=default --filter NucleusCompositorTransitionStressTests
```

Each suite stores its structural limits next to the fixture and explains why
the bound is independent of machine speed.

Verify bounded:

- Semantic nodes visited.
- Visual layers and topology mutations.
- Paint bytes and registrations.
- Text handles, paragraph layouts, and layout creation.
- Images, runtime effects, and snapshots.
- Damage regions and output acquisitions.
- Animation, observation, async-command, and completion records.
- Accessibility objects and emitted events.
- Wayland resources, DBus objects, native allocations, and file descriptors.

Use Tracy captures after a structural assertion fails or for user-requested
profiling. Tracy is not the sole pass/fail oracle.

### Physical hardware handoff

After all agent-runnable gates pass, hand off this user-owned matrix:

1. Start a single-output session.
2. Connect, remove, and reconnect a second output repeatedly.
3. Change mode, scale, placement, and primary output.
4. Switch VT away and back with static windows, animations, video, and direct
   scanout.
5. Suspend and resume with output topology changed while suspended.
6. Exercise mixed-refresh outputs and a 59.94 Hz mode.
7. Exercise popup-heavy GTK and Qt clients.
8. Exercise external clipboard, drag-and-drop, input-method, and AT-SPI
   clients.
9. Exercise the compositor overlay and out-of-process shell under runtime
   appearance and accessibility-setting changes.
10. Monitor diagnostics, Tracy captures, memory, GPU resources, and
    descriptor counts during idle and sustained use.

Agent-runnable implementation is complete before this handoff. Hardware
results are recorded as product validation; they do not keep an otherwise
completed implementation task open.

### Documentation result

Update foundation documentation to describe:

- Context-owned host services and text-layout ownership.
- Async pasteboard command and adapter teardown behavior.
- Retained-scene, host-projection, renderer, and transport guarantees.
- Live AT-SPI and text-input host obligations.
- Environment propagation through both Linux UI hosts.
- Portable drag-and-drop and Wayland projection.
- Snapshot-overlay and closing-fade semantics.
- Retained observation lifecycle.
- Multiline editor, menu, collection, and async-resource behavior.
- Structural counters and bounded-resource contracts.
- Refactored module ownership boundaries.

Document deliberate omissions. Do not claim complete AppKit, Core Animation,
Core Graphics, SwiftUI, or toolkit compatibility.

## Final acceptance criteria

The follow-up foundation work is complete when:

- Every retained scene has explicit text, pasteboard, diagnostic, and
  environment ownership through its `UIContext`.
- No mutable process-global UI service installation remains.
- Text layout creation, querying, painting, and release use the correct
  context and creating backend.
- Async clipboard commands cannot expose stale data or mutate a stale editor.
- Retained-scene, host-projection, renderer, and transport suites each prove
  their real production boundary.
- Clipboard, AT-SPI, text input, environment, and drag-and-drop work through
  live Linux transports and release all resources.
- Clean UI and idle outputs perform no publication, acquisition, GPU, or
  presentation work.
- Local changes remain proportional to dirty semantic and visual work.
- Tile crossfade and closing fade are presentation-correlated and
  resource-bounded without a second transition system.
- Observation updates retained views without introducing another tree or
  publication path.
- Multiline text, menus, lists, and grids meet their interaction, focus,
  accessibility, and lifecycle contracts.
- Async image and icon work is cancellable, generation-safe, coalesced, and
  resource-bounded.
- Large mechanisms have focused implementation files without splitting
  ownership.
- Swift isolation, errors, cancellation, native handles, and cross-language
  lifetime are explicit.
- `tools/collider doctor`, `tools/collider build`, and the corrected
  `tools/collider test` pass.
- All agent-runnable optimized structural gates pass before physical hardware
  validation is handed to the user.
