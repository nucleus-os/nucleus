# Nucleus Foundation Follow-up Plan

## State invariant

Nucleus presents one coherent retained UI system through every host.

- Every `View`, `Window`, scene, platform service, visual publication, input
  sequence, accessibility object, and animation belongs to one explicit
  semantic context and has one teardown path.
- In-memory, compositor-embedded, out-of-process Wayland, and React Native
  hosts expose the same semantic behavior. Host differences begin only at
  platform surfaces, event-loop integration, native services, and
  presentation.
- Text, pasteboard, input methods, accessibility, appearance, and other
  platform services are installed explicitly. No scene changes another
  scene's service backend through mutable process-global state.
- A clean UI produces no visual transaction, content registration, output
  acquisition, GPU work, or presentation. Localized semantic changes produce
  work proportional to their dirty ancestry and affected visual footprint.
- Presentation completion, compositor transitions, resource retirement, and
  user-visible state refer to the exact frame accepted for presentation.
- Application data flow remains retained and main-actor-owned. Observation
  updates retained objects; it does not introduce a second view tree, virtual
  DOM, or SwiftUI-style reconciliation pipeline.
- Complex controls implement complete editing, focus, accessibility,
  interaction, and lifecycle behavior before they become public foundation
  claims.
- Swift, Wayland, DBus, io_uring, Vulkan, and C/C++ ownership is visible in
  types. Resource lifetime never depends on a swallowed error or an
  undocumented `unowned` assumption.

Complete the phases below in strict order. Each phase establishes contracts
used by the next phase.

## Scope

This plan completes and proves the Nucleus application and UI foundations
after the initial NucleusUI hardening work. It covers:

- Cross-host semantic and rendering conformance.
- Explicit ownership of UI platform services.
- Linux pasteboard, accessibility, input-method, environment, and
  drag-and-drop adapters.
- Compositor presentation transitions and hardware validation.
- Retained observation and controller ergonomics.
- Production behavior for multiline text, menus, and virtualized
  collections.
- Refactoring of stabilized publication, renderer, accessibility, and Wayland
  mechanisms.
- Swift 6.4 isolation, ownership, diagnostics, documentation, and performance
  gates.

This plan does not port or rewrite Noctalia. It does not add a SwiftUI clone,
preserve deprecated service globals, reproduce the entire AppKit control
catalog, or add speculative widgets without an identified foundation
contract.

## Current follow-up findings

The initial foundation pass established the correct semantic model:

- `UIContext` owns semantic identity and dirty generations.
- `WindowScene` owns retained scene lifecycle and visual publication.
- Publication is sparse, damage-aware, and accepted-cache-safe.
- Animation completion is correlated with accepted or presented work.
- Text layout is isolated behind a Swift protocol.
- Accessibility has a neutral incremental tree and an AT-SPI projection.
- Lists and grids use stable identity and bounded materialization.
- The compositor has one output-topology reconciliation path, an output redraw
  state machine, commit-correlated presentation records, and substantially
  complete Wayland transaction mechanisms.

The remaining risks are concentrated at integration boundaries:

1. Subsystem tests do not yet prove one identical scene through every host
   adapter and the real transaction applier.
2. `Pasteboard.general` and `TextSystem.shared` remain mutable process-wide
   service installations despite scene-local semantic ownership.
3. `Pasteboard.string` falls back to cached local content when an installed
   adapter reports an empty clipboard, which can expose stale data.
4. The shell does not install a NucleusUI `PasteboardAdapter` backed by
   Wayland data control.
5. The AT-SPI export model is tested, but the complete live accessibility-bus
   transport does not have an automated conformance harness.
6. The shell text-input adapter has strong value-level coverage but needs
   complete protocol-transport coverage for preedit, deletion, secure entry,
   and candidate geometry.
7. `TextView` is a multiline `TextField` specialization rather than a complete
   scrolling editor container.
8. `Menu` is a flat stack of buttons and does not yet implement desktop menu
   semantics.
9. Compositor scene code samples tile-crossfade opacity, but the snapshot
   begin/end lifecycle and closing fade are not connected to the live scene
   feeder.
10. Several now-stabilized source files combine multiple mechanisms and are
    too large to remain safe change boundaries.

## Phase 1: Establish one cross-host acceptance harness

### Conformance scene

Create a reusable foundation conformance scene in a test-support target. It
must use public or privileged host seams rather than test-only source-shape
inspection.

The scene contains:

- Multiple ordered windows with distinct roles and activation policies.
- Nested stack, flex, and grid layouts.
- A clipped and transformed scroll hierarchy.
- Static and virtualized collections with stable item identity.
- Text, image, path, gradient, runtime-effect, shadow, backdrop, and material
  content.
- Text fields, secure fields, multiline editing, selection, composition, and
  pasteboard actions.
- Buttons, toggles, radio groups, sliders, segmented controls, selects,
  popovers, context menus, tooltips, and focus scopes.
- Semantic appearance and environment dependencies.
- Accessible roots, relationships, text, values, selection, actions, live
  regions, and offscreen virtual elements.
- Retained and main-actor animations with completion handlers.

Keep stable semantic identifiers for all assertions. Do not infer correctness
from layer allocation order.

### Host drivers

Drive the same conformance scene through these host configurations:

1. An explicit in-memory app host.
2. A direct `WindowScenePublicationContext` embedder.
3. The compositor overlay host.
4. The out-of-process shell Wayland host through a deterministic client
   fixture.
5. The React Native surface/embedder publication host.

Each driver installs the semantic context, visual context, platform services,
surface association, activation state, and teardown hooks required by its real
production path. The driver does not recreate publication or lifecycle
behavior in test code.

### Shared semantic assertions

Run one behavior suite against every driver:

- Construction assigns every retained object to the expected `UIContext`.
- First publication creates one coherent visual topology.
- Repeated clean publication produces no transaction.
- A leaf geometry, style, visibility, content, transform, scrolling,
  accessibility, or animation mutation changes only the expected semantic and
  visual state.
- Reparent, reorder, hide/show, and output migration preserve retained
  identity and resource ownership.
- Pointer capture, responder routing, focus traversal, key-window changes,
  scene deactivation, and removal follow the same contract.
- Text selection, composition, undo, secure-entry redaction, and candidate
  geometry are host-independent.
- Accessibility snapshots and action dispatch remain stable across visual
  changes and virtualization.
- Animation replacement, cancellation, reduced motion, accepted completion,
  and presented completion report exactly one terminal outcome.
- Scene disconnect rejects later publication and input while releasing all
  semantic and visual state.

### Real transaction application

Run the visual assertions through `RenderTransactionApply` and the retained
render tree rather than examining authored transactions alone.

Assert:

- Created, reparented, hidden, and removed render nodes match semantic
  topology.
- Geometry narrows once and remains finite.
- Content registrations resolve to live resources for the accepted
  generation.
- Rejected commits leave publisher caches retryable.
- Old and new presentation footprints produce correct damage.
- Presentation completion resolves the transaction and animation handles
  associated with the accepted frame.
- Teardown retires render nodes, paint registrations, text handles, image
  handles, runtime effects, snapshots, and animations.

### Render-result verification

Add deterministic render-result fixtures for behavior that cannot be proven
from topology:

- Affine transforms, including reflection, skew, rotation, and collapsed
  axes.
- Path fill rules, transformed strokes, arcs, clips, and save/restore.
- Text glyph placement, baselines, wrapping, truncation, selection, and caret
  geometry.
- Images, masks, tinting, saturation, and content modes.
- Blend modes, opacity, shadows, backdrop materials, and nested clips.
- Backing scale and fractional-scale conversion.
- Localized repaint preserving pixels outside damage.
- Full repaint promotion for nonlocal effects and composite-property changes.

Use the production paint lowering and renderer. Compare canonical pixel
buffers or stable hashes with a documented tolerance only where the native
backend cannot produce bit-identical results.

### Stress and performance contracts

Promote the optimized foundation stress fixtures into permanent acceptance
gates:

- Deep trees prove linear flat traversal.
- Wide trees prove there is no per-parent subtree copying.
- Repeated clean frames keep visits, commits, registrations, acquisitions,
  and presentations at zero.
- A localized leaf change bounds nodes visited, snapshots authored, property
  updates, paint bytes, and damage.
- Continuous list and grid scrolling bounds materialized views, visual
  layers, paint registrations, text layouts, image resources, and reuse-pool
  size.
- Repeated popover, tooltip, menu, window, and scene lifecycle returns every
  counter to baseline.
- Rejected commits, output loss, and presentation cancellation do not leak
  completion handles.

Record the limits as behavioral expectations in the tests. Tracy remains the
diagnostic source for explaining a failure, not the only place the contract
exists.

### Phase 1 completion gate

- One conformance scene runs through every supported host driver.
- Shared assertions exercise production semantic, publication, transaction,
  and teardown paths.
- Render-result fixtures cover the graphics contract at actual output pixels.
- Optimized stress tests enforce bounded work and resource lifetime.
- Failures identify the semantic, publication, renderer, adapter, or
  presentation stage responsible.

## Phase 2: Make platform-service ownership contextual

### Service bundle

Add one main-actor `UIHostServices` value owned by `UIContext`.

It contains:

- A `TextSystem` instance.
- A `Pasteboard` instance.
- A typed diagnostic sink for recoverable platform-service failures.
- Host environment update entry points.
- Future service slots only when a concrete adapter is introduced.

The service bundle contains portable protocols and Swift values. It does not
import Wayland, DBus, Skia C++, Android JNI, or another platform module.

Construct `UIContext` with its complete service bundle. A host may share one
heavy text backend object across contexts, but each context receives an
explicit `TextSystem` installation and owns its installation generation.

### Remove mutable service globals

Delete `TextSystem.shared` and `Pasteboard.general`. Fix every caller in the
same phase.

Views and controls derive services from their owning `UIContext`:

- Font resolution, metrics, shaping, retained layout, and text drawing use
  `view.uiContext.services.textSystem`.
- Copy, cut, paste, and selection commands use
  `view.uiContext.services.pasteboard`.
- Detached tests construct a `UIContext` with explicit deterministic
  services.
- App and embedder hosts construct services before materializing retained
  content.

Do not keep deprecated wrappers or a fallback global context.

### Pasteboard correctness

Correct the portable pasteboard contract:

- When an adapter is installed, its `nil` read means the native clipboard is
  empty. Do not return stale local content.
- Local storage is used only by a pasteboard with no installed adapter.
- Installing or removing an adapter has explicit cache semantics.
- A failed native transfer reports through the service diagnostic sink.
- Secure controls never write their content.
- Clipboard reads do not block the main actor.

Change `PasteboardAdapter` to model asynchronous native reads when the
Wayland transport requires them. Do not hide a blocking file-descriptor read
behind a synchronous property.

### Text-system ownership

Keep layout handles retained by the backend instance that created them while
moving lookup through the context-owned `TextSystem`.

Verify:

- Replacing one context's backend does not invalidate another context.
- Existing layout leases release through their creating backend.
- Font collection generation invalidates only affected contexts.
- Missing production backends report a hard host diagnostic.
- Headless tests install an explicit test backend rather than relying on
  process order.

### Platform-host construction

Extend `PlatformAppHost` so service creation is part of scene
materialization. The materializer must receive the visual context and complete
host services before it constructs the first `View` or `Window`.

Update:

- The in-memory app host.
- The compositor overlay host.
- The shell host.
- The UI embedder.
- The React Native host.
- Test composition roots.

### Multi-context verification

Add behavior tests that keep multiple contexts alive concurrently:

- Each context uses a distinct text backend generation.
- Each context reads and writes only its installed pasteboard.
- Replacing one adapter does not change another context.
- Destroying one context does not release another context's layouts or
  platform service objects.
- Async child tasks inherit only the construction context in which they were
  created.

### Phase 2 completion gate

- Every UI platform service is installed through `UIContext`.
- No mutable process-global text or pasteboard backend remains.
- Native-empty pasteboard state cannot reveal cached content.
- Multiple live contexts use independent service installations.
- All production and test hosts construct services before retained UI
  materialization.

## Phase 3: Complete Linux platform adapters

### Wayland pasteboard adapter

Implement the shell's `PasteboardAdapter` using the compositor's privileged
`ext-data-control-v1` path.

The adapter must:

- Bind the manager and create one device for the active seat.
- Track selection offers and advertised MIME types.
- Prefer UTF-8 plain-text MIME types in a deterministic order.
- Read offers without blocking the main actor.
- Write data from immutable `Sendable` payloads through owned pipe
  descriptors.
- Keep an offered source alive until cancellation or replacement.
- Handle source cancellation, seat replacement, compositor reconnect, and
  shell shutdown idempotently.
- Enforce configured transfer-size bounds.
- Close every file descriptor exactly once on success, cancellation, timeout,
  peer failure, and teardown.
- Report transport errors through the context service diagnostic sink.

Use move-only or single-reference owners for transferred descriptors. Do not
store copyable raw integers as long-lived ownership.

Add a deterministic client/server fixture that proves cross-client copy,
paste, replacement, clearing, cancellation, MIME negotiation, large payload
transfer, and disconnect cleanup.

### Live AT-SPI conformance

Add a test accessibility bus and run `SystemdAtSPIAdapter` against it.

Verify:

- Application registration and deregistration.
- Root and child enumeration.
- Stable object paths across property-only updates.
- Accessible, Action, Application, Component, Text, EditableText, Selection,
  and Value methods and properties.
- Coordinate conversion and extents.
- Focus, state, property, text, selection, live-region, insertion, and removal
  events.
- Virtualized offscreen elements.
- Secure-text redaction at every method and property.
- Action dispatch back onto the main actor.
- Bus loss and reconnect cleanup.

Message encoding and decoding tests use actual DBus messages. Keep pure export
model tests for policy coverage.

### Complete text-input transport coverage

Drive the shell's real `zwp_text_input_v3` listener and request path through a
wire fixture.

Cover:

- Enable, disable, focus replacement, and window teardown.
- Surrounding-text UTF-8 byte offsets and UTF-16 model conversion.
- Preedit text, cursor range, style spans, replacement, and cancellation.
- Commit strings and delete-surrounding-text in both directions.
- Cursor rectangle updates through window and surface coordinates.
- Content hints and purposes.
- Serial and commit-count ordering.
- Multilingual grapheme clusters, combining marks, emoji, and bidirectional
  text.
- Secure fields exporting neither surrounding nor selected text.

### Environment sources

Install scene environment updates from the Linux host:

- Light and dark appearance.
- Increased contrast.
- Reduced motion.
- Reduced transparency.
- Text scale.

Read the authoritative portal or desktop setting source through a platform
adapter. Normalize it into `UIEnvironment` before updating `UIContext`.
Subscription and reconnection remain owned by the shell host and stop before
scene teardown.

### Drag-and-drop foundation

Add a platform-neutral NucleusUI drag-and-drop contract over retained input
sequences:

- Stable drag-session identity.
- Immutable offered type metadata.
- Async payload loading.
- Enter, update, exit, drop, cancellation, and source-completion events.
- Explicit accepted operation negotiation.
- Drag preview ownership and teardown.
- Accessibility actions for equivalent non-pointer operation.
- Coordinate conversion through transformed and scrolled views.

Project it through the shell Wayland client and the compositor's existing
data-device mechanisms. Do not merge clipboard and drag lifecycle state simply
because both use Wayland data offers.

### Phase 3 completion gate

- Shell copy and paste interoperates with external Wayland clients.
- Native clipboard reads never block the main actor or expose stale content.
- The live AT-SPI adapter passes bus-level behavior tests.
- Text input passes real protocol-transport tests, including secure entry.
- Environment changes update only dependent retained views.
- Drag-and-drop has one portable lifecycle and one Wayland projection.
- Adapter teardown returns bus objects, proxies, offers, sources, and file
  descriptors to baseline.

## Phase 4: Complete compositor transitions and hardware behavior

### Tile content crossfade

Connect the existing transition snapshot mechanism to the live scene feeder.

When a tile transition begins:

1. Capture the last accepted content at the exact transition boundary.
2. Register the capture as a retained snapshot resource.
3. Call `WindowSceneAuthor.beginContentCrossfade`.
4. Associate the snapshot and transition generation with the window.
5. Request frames through the output redraw state machine.

For each authored frame:

- Sample geometry and opacity from the same predicted presentation time.
- Keep snapshot geometry identical to the live backing geometry.
- Continue requesting frames while either geometry or overlay opacity changes.

When the transition settles, is superseded, or becomes terminal:

1. Remove the overlay through `endContentCrossfade`.
2. Release the snapshot only after the renderer can no longer reference it.
3. Complete or cancel the transition exactly once.

Handle re-tiling during an active transition by replacing the transition
generation atomically.

### Closing fade

Connect unmap and close behavior to presentation-time opacity:

- Stop accepting input immediately.
- Retain the last accepted visual content for the closing transition.
- Keep the window visible in the authored scene while the fade is active.
- Drive opacity from the output presentation clock.
- Remove topology and release content only after terminal presentation or
  cancellation.
- Cancel immediately for session-lock security transitions, output loss, or
  host shutdown where retaining content is invalid.

Do not let a client buffer lifetime depend on the visual fade. Use a compositor
snapshot when the Wayland buffer must be released.

### Transition correctness

Add deterministic tests for:

- Tile begin, midpoint, settle, cancellation, and supersession.
- A second tile transition during an active crossfade.
- Closing a static, animating, direct-scanout, or crossfading window.
- Client buffer replacement during a transition.
- Output removal and scale change during a transition.
- Session lock activation while a transition is visible.
- Snapshot registration and retirement.
- Exactly-once completion.

Remove stale comments that describe already-connected or still-unconnected
transition behavior inaccurately.

### Render and presentation validation

Verify the complete path on production render mechanisms:

- Composite to direct-scanout and direct-scanout to composite transitions.
- Localized damage under animated geometry.
- Fractional scale and transformed damage rounding.
- Mixed-refresh output scheduling.
- Fractional millihertz refresh modes.
- Frame callback and presentation-feedback correlation.
- Explicit synchronization and DMA-BUF retirement.
- Clean idle with no scene traversal or render submission.

Add Tracy zones and counters for snapshot capture, transition lifetime,
direct-scanout eligibility changes, output acquisition, submitted damage, and
presentation completion.

### User-owned hardware validation

After all non-interactive gates pass, hand off this matrix:

1. Log into a single-output session.
2. Connect, remove, and reconnect a second output repeatedly.
3. Change mode, scale, placement, and primary output.
4. Switch VT away and back with static windows, animations, video, and direct
   scanout.
5. Suspend and resume with output topology changed while suspended.
6. Exercise mixed-refresh outputs and a 59.94 Hz mode.
7. Exercise popup-heavy GTK and Qt clients.
8. Exercise external clipboard, drag-and-drop, input methods, and AT-SPI
   clients.
9. Monitor compositor diagnostics, Tracy captures, memory, GPU resources, and
   file-descriptor counts during idle and sustained use.

### Phase 4 completion gate

- Tile crossfade and closing fade use exact presentation-time state.
- Transition snapshots have bounded and verified lifetime.
- Output loss, session lock, supersession, and teardown produce one terminal
  transition result.
- Real render tests cover damage and scanout transitions.
- Every agent-runnable compositor and shell gate passes before hardware
  handoff.
- Hardware validation reports no stale output, resource, presentation,
  clipboard, input-method, or accessibility state.

## Phase 5: Add retained observation and controller ergonomics

### Data-flow contract

Keep the retained model:

- Views are constructed once and keep identity.
- Application models own domain state.
- Observation writes values into existing views and controllers.
- Structural replacement remains explicit.
- Publication continues to observe NucleusUI dirty generations, not
  application-model observation internals.

Do not re-run arbitrary view bodies as an update engine.

### Observation lifetime

Add a main-actor observation token owned by a retained lifecycle owner.

The token:

- Uses Swift Observation to track dependencies read by one update closure.
- Re-registers tracking after every accepted update.
- Coalesces multiple model changes before the next UI publication boundary.
- Runs its update inside the owning `UIContext`.
- Supports a `TransactionConfiguration` for animated or nonanimated updates.
- Cancels when its view, controller, window, or scene disconnects.
- Holds observed models according to an explicit strong or weak ownership
  choice.
- Never runs after cancellation.

Expose focused APIs on `ViewController` and `View`; do not expose raw
observation bookkeeping as public mutable state.

### Controller patterns

Add retained controllers for repeated application patterns:

- A snapshot controller that observes ordered model identity and applies
  `CollectionSnapshot` changes to lists and grids.
- A selection controller that separates model selection from focused visual
  identity.
- A form controller that coordinates validation, enabled state, default
  action, cancellation, and first invalid responder.
- A search/filter controller that performs background computation on
  immutable `Sendable` values and applies results on the main actor.
- An async resource controller for images, icons, and service-backed values
  with generation-based stale-result rejection.

Keep these controllers portable and independent of shell services.

### Concurrency contract

- Mutable observed application models are main-actor isolated.
- Background work consumes immutable `Sendable` snapshots.
- Completion returns through explicit main-actor closures or tasks.
- Observation closures do not capture non-Sendable platform handles.
- Cancellation is idempotent and propagates to outstanding async work.
- A stale generation cannot overwrite a newer value.

### Behavioral tests

Verify:

- A model property update changes the retained view without replacing it.
- Multiple writes coalesce into one publication.
- Observation dependency changes stop observing values no longer read.
- Removing a view or disconnecting a scene cancels its observation.
- Animated updates preserve immediate semantic state and presentation-time
  completion.
- Snapshot movement preserves cell identity.
- Async results apply only to their current generation.
- Multiple contexts observing the same immutable service result remain
  isolated in mutation and teardown.

### Phase 5 completion gate

- Application state can drive retained UI without manual subscription
  bookkeeping.
- Observation introduces no second view hierarchy or publication path.
- Every observation has an explicit lifecycle owner.
- Controller updates integrate with semantic transactions and dirty
  generations.
- Cancellation, stale-result rejection, and actor isolation pass behavioral
  tests.

## Phase 6: Complete complex foundation controls

### Multiline text editor

Replace the thin `TextView` specialization with a complete multiline editor
container.

Implement:

- A text content view inside a clipping scroll view.
- Width-constrained shaping and reflow.
- Independent content size and viewport size.
- Vertical and horizontal scrolling policy.
- Multiline hit testing, caret movement, and selection.
- Up, down, page up, page down, home, end, document start, and document end.
- Preferred horizontal caret position across vertical movement.
- Selection autoscroll during pointer drag and input-method updates.
- Caret visibility after editing, undo, redo, composition, and resize.
- Line, paragraph, word, and document selection commands.
- Large-document layout invalidation that avoids reshaping unaffected text
  when the backend can support incremental paragraphs.
- Accessibility Text and EditableText ranges in the same UTF-16 coordinate
  space as the editor model.

Secure multiline entry remains unsupported unless a concrete consumer
requires it. Reject that configuration rather than exposing an incompletely
redacted editor.

### Desktop menus

Replace the flat button stack with a retained menu model and presentation
controller.

Support:

- Commands, separators, nested submenus, checked items, radio groups, and
  alternate items.
- Titles, glyphs, key equivalents, enabled state, hidden state, and
  accessibility labels.
- Up/down navigation, home/end, left/right submenu navigation, escape, enter,
  and mnemonic or type-ahead selection.
- Delayed submenu opening and pointer-aim tolerance.
- Screen-edge and output-aware placement.
- Correct focus restoration and dismissal cascades.
- Command validation immediately before presentation and activation.
- Stable item identity without recreating unaffected submenu views.
- Accessible Menu and MenuItem topology, state, actions, and focus events.

Menus remain portable retained content presented through `Popover`. Wayland
popup serials and configure state stay in the shell adapter.

### Virtualized collection behavior

Extend list and grid foundations with:

- Animated insertion, removal, and movement from stable snapshots.
- Range selection with keyboard and pointer anchors.
- Type-ahead focus where textual item metadata is available.
- Reorder sessions integrated with drag-and-drop.
- Variable row and cell sizes with bounded measurement caching.
- Scroll-position preservation across snapshot changes.
- Focus and accessibility preservation across movement and recycling.
- Deterministic invalidation when an item's content revision changes.

Keep collection identity independent of view and layer identity.

### Async image and icon resources

Add a retained resource request model:

- Stable request identity.
- Decode target size and backing scale.
- Cancellation and stale-generation rejection.
- Shared decode cache with explicit memory bounds.
- Negative-result caching for missing icons.
- Theme and appearance invalidation.
- Placeholder and failure state represented by consumer policy rather than
  renderer fallback.

The resource model communicates with `ImageResource` and the renderer through
the existing portable seams.

### Foundation control matrix

Run every control through:

- Pointer, touch, keyboard, and focus behavior.
- Disabled, selected, pressed, hovered, focused, error, and busy state.
- Appearance, increased contrast, reduced motion, reduced transparency, and
  text scale.
- Fractional scale and transformed parent coordinates.
- Accessibility role, value, state, actions, and events.
- Scene deactivation, window removal, and repeated lifecycle teardown.
- Optimized resource-bounded stress.

### Phase 6 completion gate

- `TextView` is a complete scrolling multiline editor rather than a
  size-growing field.
- Menus implement desktop keyboard, pointer, submenu, placement, command, and
  accessibility behavior.
- Collection snapshot changes preserve identity, focus, scroll position, and
  bounded materialization.
- Async image and icon work is cancellable, generation-safe, and
  resource-bounded.
- Complex controls pass the cross-host acceptance harness.

## Phase 7: Refactor stabilized mechanisms and finish Swift 6.4 hygiene

### Split `ViewLayerPublisher`

Keep one publisher authority while splitting its implementation into focused
files:

- Publication orchestration and accepted-cache lifecycle.
- Flat dirty traversal and semantic snapshots.
- Visual topology reconciliation.
- Property diffing and geometry lowering.
- Paint, text, image, runtime-effect, and snapshot registration.
- Damage derivation.
- Animation and transaction-completion binding.
- Metrics and Tracy publication.

Use package-scoped value types for intermediate records. Do not introduce
protocol dispatch inside the hot traversal without a measured need.

### Split `View`

Keep the public `View` type and move implementation into responsibility-based
extensions:

- Hierarchy and context ownership.
- Geometry and coordinate conversion.
- Layout invalidation and measurement.
- Display invalidation and recording.
- Input, tracking, cursor, and hit testing.
- Focus and responder behavior.
- Environment and appearance.
- Accessibility.
- Animation state.

State remains stored by `View`; extensions organize mechanisms rather than
creating parallel owner objects.

### Split the AT-SPI adapter

Separate:

- Bus discovery, connection, registration, and teardown.
- Object-path and interface dispatch.
- DBus argument decoding.
- DBus reply encoding.
- Accessible and Application interfaces.
- Action and Component interfaces.
- Text and EditableText interfaces.
- Selection and Value interfaces.
- Event encoding and emission.
- AT-SPI role, state, coordinate, and enum mapping.

Keep `AtSPIExportModel` as the pure projection and policy boundary.

### Split render orchestration

Refactor `RenderCore` around:

- Transaction acceptance and retained-tree application.
- Frame demand and output scheduling.
- Resource registration and retirement.
- Paint and image production.
- Snapshot capture.
- Presentation submission and completion.
- Shutdown.

Keep one render owner. The split must not add a second scheduling or resource
registry path.

### Split Wayland mechanics

Refactor `InputDispatch` and `XdgShell` after their wire conformance tests pin
behavior:

- Resource request decoding.
- Protocol state and ledgers.
- Serial validation.
- Policy decisions.
- Window-manager execution.
- Event projection.
- Destruction and disconnect cleanup.

Wayland protocol errors remain translated once at request boundaries.

### Error and diagnostic audit

Remove swallowed errors from foundation and compositor state mutation:

- Interactive move and resize updates.
- Scene author operations.
- Platform service installation.
- DBus connection and transport.
- Render transaction application.
- Snapshot capture and retirement.
- Async clipboard and resource transfers.

Use typed throws for internal recoverable failures. Convert errors into host
diagnostics, protocol errors, cancellation outcomes, or programmer traps at
the owning boundary.

Do not log repeatedly for a persistent identical failure; deduplicate by
operation, resource identity, and generation.

### Isolation and ownership audit

Audit every:

- `@unchecked Sendable`.
- `nonisolated(unsafe)`.
- `unowned` reference.
- Retained closure crossing an actor or C callback boundary.
- Raw file descriptor.
- Wayland resource pointer.
- DBus message and slot.
- Vulkan handle.
- C++ resource handle.

Apply these rules:

- Use executor isolation for mutable UI, compositor, and protocol state.
- Use immutable `Sendable` values across executors.
- Use `Mutex` only for genuine non-actor synchronous sharing.
- Use move-only owners for lexical native resources and single reference
  owners for resources stored in collections.
- Extract scalar identity before actor hops.
- Mark retained closures `@Sendable` and with their intended global actor.
- Replace `unowned` with weak lookup or explicit owner-managed invalidation
  wherever external teardown can reverse the assumed order.
- Keep unchecked conformance only for opaque native handles whose access
  contract is documented and mechanically enforced.

### Public API hygiene

- Generate symbol graphs for the public foundation modules.
- Require public types and members to document ownership, actor isolation,
  coordinate space, units, lifetime, and error behavior where applicable.
- Remove Apple-shaped names whose behavior does not match the documented
  subset.
- Remove implementation details that became public only to connect packages;
  use `package` or the existing compositor SPI.
- Keep C++ modules out of non-C++ public module graphs.
- Use typed IDs instead of unrelated integer handles at Swift boundaries.
- Adopt Swift 6.4 ownership and isolation features where they make lifetime
  mechanically clearer.

The symbol graph is an audit input, not a promise to preserve obsolete API.
Delete replaced APIs and fix callers in the same phase.

### Phase 7 completion gate

- Large mechanisms have focused file boundaries and one visible owner.
- Hot paths preserve or improve measured allocation and traversal behavior.
- Recoverable errors reach an explicit diagnostic or typed outcome.
- Native and Swift ownership assumptions are enforced in types or lifecycle
  operations.
- Public API documentation matches implemented behavior and host obligations.
- No refactor changes cross-host semantic results.

## Phase 8: Final verification and acceptance

### Behavioral verification

Run:

- The cross-host foundation conformance suite.
- Graphics render-result fixtures.
- Text, editing, IME, and pasteboard transport suites.
- Live AT-SPI bus conformance.
- Drag-and-drop client/server fixtures.
- Compositor Wayland wire conformance.
- Renderer and presentation tests.
- Observation and controller lifecycle tests.
- Complex control behavior tests.
- Randomized semantic, geometry, editing, collection, accessibility, and
  teardown tests.

Every test asserts runtime behavior or resource contracts. Do not inspect
source declarations or file shape.

### Optimized stress verification

Run optimized fixtures with Tracy enabled for:

- Deep and wide publication.
- Continuous scrolling and snapshot mutation.
- Multiline editing and repeated text-layout invalidation.
- Repeated menus, submenus, popovers, tooltips, and drag sessions.
- Repeated scene and host lifecycle.
- Tile, close, and direct-scanout transitions.
- Clipboard, input-method, accessibility, and environment reconnect.
- Multi-context service replacement and teardown.

Verify bounded:

- Semantic nodes visited.
- Visual layers and topology mutations.
- Paint bytes and registrations.
- Text handles and layout creation.
- Images, runtime effects, and snapshots.
- Damage regions and output acquisitions.
- Animation and completion records.
- Accessibility objects and emitted events.
- Wayland resources, DBus objects, native allocations, and file descriptors.

### Complete host verification

Source the host environment and run the repository entry points:

```sh
source tools/host-env.sh
tools/nucleus doctor
tools/nucleus build
tools/nucleus test
```

Run targeted package suites while implementing each phase, then run the
complete commands above after Phase 8. Do not launch the compositor or shell
as an agent-run verification step without explicit user direction.

### Documentation result

Update the foundation contracts to document:

- Context-owned host services.
- Cross-host conformance guarantees.
- Async pasteboard and drag-and-drop behavior.
- Live AT-SPI and input-method host obligations.
- Retained observation and controller lifecycle.
- Multiline editor and menu behavior.
- Transition snapshot and closing-fade semantics.
- Performance counters and bounded-resource contracts.
- Refactored module ownership boundaries.

Documentation describes supported behavior and deliberate omissions. It does
not claim complete AppKit, Core Animation, Core Graphics, SwiftUI, or toolkit
compatibility.

## Final acceptance criteria

The follow-up foundation work is complete when:

- One behavior suite proves the same retained scene through every supported
  host and the real render transaction applier.
- Pixel-result fixtures enforce the documented graphics behavior.
- Every scene receives explicit text, pasteboard, diagnostic, and environment
  services through its `UIContext`.
- No mutable process-global text or pasteboard installation remains.
- Clipboard, AT-SPI, input methods, environment settings, and drag-and-drop
  work through their live Linux transports and release all resources.
- Clean UI and idle outputs perform no publication, acquisition, GPU, or
  presentation work.
- Local changes remain proportional to dirty semantic and visual work.
- Tile crossfade and closing fade are presentation-correlated and
  resource-bounded.
- Observation updates retained views without introducing another tree or
  publication pipeline.
- Multiline text, menus, lists, and grids meet complete interaction, focus,
  accessibility, and lifecycle contracts.
- Large implementation files have focused responsibilities without splitting
  ownership.
- Errors, cancellation, isolation, and native-resource lifetime are explicit.
- Full host builds, tests, optimized stress gates, and user-owned hardware
  validation pass.
