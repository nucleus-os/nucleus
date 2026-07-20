# Nucleus UI Foundation Hardening Plan

## Foundation invariant

Every NucleusUI semantic mutation has exactly one authoritative path to exactly
one retained visual object. The UI model owns semantic identity and state. The
publication tier owns render-layer identity, creation, hierarchy, updates,
animation requests, and removal. Platform hosts supply surfaces, input, text
services, accessibility, and a presentation clock through explicit adapters.
No UI object silently falls back to an unrendered context, no coordinate crosses
a boundary without a named conversion, and no frame republishes clean state.

The completed foundation has these additional invariants:

- a window's frame is scene-space geometry and its content root is window-local;
- scene, window, view, surface, backing-pixel, and output coordinates convert at
  one explicit boundary each;
- model state changes eagerly on the main actor while visual state changes only
  through an atomic publication transaction;
- compositor-side animations and main-actor value animations share one
  presentation clock, cancellation model, motion policy, and completion
  contract;
- NucleusUI is a pure Swift module; C++ text and rendering implementations are
  installed behind Nucleus-owned Swift protocols or closure tables;
- accessibility semantics are exported through a real platform adapter rather
  than existing only as test-visible properties;
- AppKit, Core Animation, and Core Graphics names communicate familiar behavior
  without claiming unsupported API or semantic parity.

Each phase below starts only after the preceding phase's exit criteria pass.

## Scope

This plan hardens the reusable Nucleus application and UI foundation:

- `core/swift/Sources/NucleusUI`;
- `core/swift/Sources/NucleusLayers`;
- `core/swift/Sources/NucleusUIEmbedder`;
- `core/swift/Sources/NucleusApp`;
- the render-model and render-host contracts consumed by those packages;
- compositor and out-of-process shell adapters required to prove the public
  foundation end to end;
- behavioral tests, stress tests, diagnostics, and public API documentation for
  those layers.

This plan does not port, rewrite, or reproduce any desktop shell product. It
does not add application-specific widgets, services, configuration schemas,
panels, launchers, compositor integrations, or browser UI. Reusable controls and
platform adapters land only where they complete a general NucleusUI contract.

## Deliberate platform model

The following choices remain intentional:

- NucleusUI is retained and imperative. `ViewBuilder` is construction syntax,
  not a native reconciler or a reactive state engine.
- UI reference types and tree mutation remain `@MainActor`.
- Layout uses intrinsic measurement and explicit two-pass
  measure/arrange containers rather than recreating Auto Layout.
- Logical UI space is top-left-origin and y-down. The framework documents this
  divergence instead of adding a partially supported `isFlipped` model.
- Public geometry remains `Double`; narrowing to render precision happens once
  at the render boundary.
- Backdrop views name semantic materials. Applications do not configure
  renderer blur passes directly.
- NucleusLayers remains a focused retained rendering substrate. It implements
  the Core Animation behavior Nucleus consumes rather than cloning every
  `CALayer` property.
- NucleusApp remains a lightweight scene-entry vocabulary over retained
  NucleusUI. It does not imply SwiftUI-style state observation.

## Phase 1: Establish one UI-to-layer authority

### Structural changes

1. Introduce a pure semantic identity for every `View`.
   - Use a stable `ViewID` or `VisualNodeID` allocated by the owning UI context.
   - Keep the identity stable for the view's lifetime and across hide/show,
     reparenting, layout, repaint, and animation.
   - Stop exposing a semantic view's render `Layer` as its identity.

2. Make `View` own UI model state only.
   - Move frame, bounds origin, transform, opacity, visibility, clipping,
     semantic layer kind, visual style, backdrop request, shadow, content
     recording, and presentation intent into NucleusUI-owned model storage.
   - Delete direct `Layer.apply`, `Layer.attach`, `Layer.detach`, and
     `LayerTransaction.appendAmbient` calls from `View` setters and tree
     mutation.
   - Delete the `View`/`Context.layers` co-ownership and registry-pruning
     lifecycle.

3. Give model state explicit dirty generations.
   - Track structure, geometry, visibility, style, content, transform,
     scrolling, accessibility, and animation-request generations separately.
   - Propagate dirty-subtree summaries to ancestors without walking clean
     descendants.
   - Equality-check and canonicalize every setter before incrementing a
     generation.

4. Make `ViewLayerPublisher` the exclusive visual-layer owner.
   - Maintain a cache from semantic identity to one visual `Layer`.
   - Create a layer before inserting or updating it.
   - Reparent retained layers without recreating them.
   - Publish hidden state as a property; do not garbage-collect a hidden
     subtree.
   - Remove a visual subtree only when its semantic subtree leaves all published
     roots or its owning scene is destroyed.
   - Release registered content and other resources when the visual cache entry
     is removed.

5. Replace the semantic/visual `Context` split.
   - Add a pure `UIContext` for semantic identity, environment, text services,
     motion/accessibility preferences, and invalidation.
   - Keep `NucleusLayers.Context` exclusively visual.
   - Make `WindowScenePublicationContext` own one `UIContext` and one visual
     layer context without treating the semantic side as an in-memory layer
     sink.
   - Remove semantic ambient layer buffers entirely.

6. Define one atomic publication operation.
   - Collect created layers, hierarchy changes, sparse property updates,
     content registrations, animation requests, and removals into one ordered
     visual transaction per context.
   - Preserve create-before-insert-before-update ordering.
   - Abort the transaction and retain the previous published cache state when
     content registration or commit fails.
   - Apply cache changes only after the commit sink accepts the transaction.

### Behavioral gates

- First publication into a real `TransactionApplier` succeeds with no
  missing-layer update or insertion.
- Publishing through either a standalone scene or an embedder produces the same
  layer topology and properties.
- The semantic side has no layer-mutation queue and cannot retain resource
  handles.
- One semantic view maps to one visual layer object in one visual context.
- Reparenting preserves the layer ID and registered content.
- Hide/show preserves the layer ID, content generation, and active animation
  state.
- Destroying a semantic subtree removes each visual layer once and releases its
  resources once.
- A completely clean publication produces no layer transaction.

## Phase 2: Normalize scene, window, view, surface, and output coordinates

### Coordinate contracts

1. Define the coordinate spaces in public documentation and internal types.
   - Scene space places windows and embedder-owned scene content.
   - Window space begins at the content area's `(0, 0)`.
   - View space includes the view's bounds origin and transform.
   - Surface space is Wayland surface-local logical space.
   - Backing space is the surface's pixel space.
   - Output space describes the host's logical output arrangement.

2. Make content roots window-local.
   - `Window.frame` remains in scene space.
   - The content root frame becomes `(0, 0, windowWidth, windowHeight)`.
   - Resizing a window changes the root size without copying the window's scene
     origin into the root.

3. Add a window placement layer during publication.
   - Parent each content root below a stable window host layer.
   - Put the window's scene position and window-level ordering on that host
     layer.
   - Keep child frames relative to their actual parents.
   - Preserve a stable placement layer across window moves and resizes.

4. Centralize conversions.
   - Add explicit scene-to-window, window-to-scene, window-to-surface,
     surface-to-window, point-to-backing, and backing-to-point operations.
   - Continue routing view-to-view conversion through the common ancestor and
     bounds/transform machinery.
   - Delete manual origin addition and subtraction from hit testing, hover,
     tooltips, popovers, text input, and platform input adapters.

5. Make native scene publication part of every host frame.
   - Give a platform host one scene-publication entry point that publishes
     visible native windows and any embedder placements.
   - Attach the published scene root to the render store before a surface can
     present it.
   - Associate each presentation surface with the intended scene/output region
     without relying on disjoint arbitrary coordinates as an input-routing
     workaround.
   - Propagate publication failures through diagnostics and prevent presentation
     of an incomplete native scene.

### Behavioral gates

- A pointer down, drag, and up on a nested control in a nonzero-origin window
  delivers the exact local coordinates on every event.
- Pointer release activates a control after capture in a nonzero-origin window.
- Nested scroll offsets and rotated/scaled ancestors produce matching drawing
  and hit-test coordinates.
- Tooltips and popovers anchor correctly in nonzero-origin windows.
- Text candidate rectangles are correct in surface-local coordinates.
- Two surfaces at different output positions render only their intended scene
  regions and route input to the matching window.
- Fractional backing scale round-trips points and rectangles without applying
  scale twice.
- Native application, compositor-overlay, and out-of-process shell hosts all
  exercise the same publication contract.

## Phase 3: Rebuild transactions and animation around presentation time

### Transaction contract

1. Replace the open-ended public transaction lifecycle with scoped execution.
   - Make transaction configuration immutable before the mutation body runs.
   - Provide a throwing scoped API that always commits or aborts.
   - Keep a noncopyable internal transaction token only where manual assembly is
     required.
   - Give every internal noncopyable transaction an auto-aborting `deinit`.
   - Reject unsupported nesting explicitly or define nested transactions as
     deterministic merges into the outer transaction.

2. Resolve action policy when each mutation is authored.
   - A policy change cannot retroactively rewrite earlier mutations.
   - Prefer a single immutable action policy on the scoped transaction.
   - Remove comments and setters that imply unsupported CATransaction behavior.

3. Tie completion to renderer acknowledgement.
   - Allocate a completion token in the publication transaction.
   - Deliver completion after the target transaction is presented or its
     animation reaches a terminal state.
   - Distinguish completed, cancelled, superseded, skipped for reduced motion,
     and failed outcomes.
   - Do not approximate renderer completion with a producer wall-clock deadline.

### Animation model

4. Keep compositor-side animation for presentation-safe layer properties.
   - Support opacity, position, bounds, transform, scroll offset, and visual
     corner radius through typed key paths.
   - Add model and presentation value queries where interaction needs the
     currently displayed value.
   - Define replacement by layer/property and stable animation ID.
   - Preserve the final model value independently of the presentation override.

5. Add a main-actor value animator.
   - Drive it from the host's predicted presentation timestamp.
   - Animate arbitrary scalar progress used by layout, paint, controls, graphs,
     spinners, and semantic effects.
   - Return a cancellable `AnimationHandle`.
   - Support cancellation by handle, owner, semantic property key, and subtree
     destruction.
   - Support completion, repeat, autoreverse, Bézier timing, spring timing, and
     a real elapsed-time mode for deadlines that must ignore motion speed.
   - Coalesce invalidation so any number of values changing in one frame request
     one publication.

6. Unify motion policy.
   - Store reduced-motion and animation-speed preferences in `UIContext`.
   - Skip presentation animation atomically when reduced motion is active while
     still assigning final model values and completing handles.
   - Validate duration, speed, spring parameters, and sampled values as finite.

7. Reimplement conveniences on the unified contract.
   - Make fade-in accept or restore an explicit target opacity.
   - Make fade-out completion capable of hiding or removing the view without a
     flash.
   - Express stack removal/reflow transitions through animation handles instead
     of independent deadline polling.
   - Remove direct `try?` commits from `Layer` convenience properties.

### Behavioral gates

- Abandoning or throwing from a transaction leaves no explicit buffer on a
  context stack.
- Action policy applies only to mutations authored under that policy.
- Completion does not fire before presentation acknowledgement.
- Superseding or cancelling an animation reports exactly one terminal outcome.
- Fade-out followed by fade-in restores the intended nonzero opacity.
- Reduced motion assigns final values and completes synchronously without
  leaving presentation overrides.
- Destroying an animation owner prevents every later setter callback.
- Semantic animations publish through both standalone and embedded scene paths.

## Phase 4: Make text a pure Swift service boundary and finish input-method hosting

### Text backend isolation

1. Move the C++ bridge out of the NucleusUI module.
   - Define a pure Swift `TextLayoutBackend` contract owned by NucleusUI or a
     lower pure Swift text-protocol module.
   - Carry Swift strings, font descriptors, scalar paragraph settings, result
     metrics, opaque handle tokens, and explicit lifecycle operations across the
     seam.
   - Install the Skia implementation from a C++-interop backend target during
     host bring-up.
   - Remove `.interoperabilityMode(.Cxx)` from NucleusUI, NucleusUIEmbedder,
     NucleusApp, and consumers that otherwise import no C++ module.

2. Actor-confine text resources.
   - Bind layout-handle creation, query, retain, and release to the backend's
     declared executor.
   - Remove `@unchecked Sendable` from layout storage.
   - Use `isolated deinit` or an explicit actor-confined resource owner for
     handle release.

3. Retain the measured layout handle.
   - Return a retained handle with the same operation that produces line
     metrics.
   - Reuse it for glyph hit testing, caret geometry, selection rectangles, and
     drawing.
   - Invalidate it only when text, runs, paragraph style, container width, scale,
     or backend generation changes.

4. Replace unconditional text traps with a host error policy.
   - Keep preconditions for impossible internal invariants.
   - Report missing backend installation, font resolution failure, and resource
     failure through a diagnostic and recoverable fallback contract.
   - Provide deterministic fallback metrics or a clearly rendered missing-text
     state rather than terminating the shell process.

### Editing and IME

5. Make candidate geometry a window-owned contract.
   - Keep a text client's caret rectangle in client-local coordinates.
   - Convert through view, window, and surface spaces before invoking a platform
     adapter.
   - Pass the adapter a surface-local rectangle and the surface identity it
     belongs to.

6. Install text-input adapters as part of window hosting.
   - Construct the platform text-input object per seat according to the
     protocol's ownership rules.
   - Connect and disconnect it as windows enter and leave hosted surfaces.
   - Assign the adapter to every hosted window's `TextInputContext`.
   - Preserve active-client state across surface enter/leave.
   - Use an actor-isolated destructor for the Wayland proxy and make explicit
     close idempotent.

7. Complete Wayland text-input state handling.
   - Verify commit/done serial semantics against the protocol state machine.
   - Remove unused serial state.
   - Preserve delete, commit, and preedit ordering.
   - Handle text-change cause, language, and preedit styling when the neutral
     Nucleus contract can represent them.

8. Correct secure editing.
   - Discard undo/redo and composition history when a field becomes secure.
   - Make the public API explicit that `stringValue` returns real text.
   - Keep `takeSecureCredential` as the preferred credential exit and document
     the limits of Swift `String` scrubbing.
   - Ensure logs, accessibility, clipboard, input-method surrounding text,
     selection APIs, layout width, and debug descriptions cannot expose secure
     contents.

9. Complete reusable editing capabilities.
   - Add a platform-neutral pasteboard/data-exchange adapter and standard
     copy/cut/paste/select-all actions.
   - Add multiline text editing as a separate `TextView` backed by the same
     editor model and layout service.
   - Extend text runs with underline, strikethrough, links, baseline offset, and
     semantic emphasis.
   - Extend paragraphs with line spacing/height, base writing direction, locale,
     additional wrapping/truncation modes, and unconstrained line count.

### Behavioral gates

- A pure Swift target imports NucleusUI without enabling C++ interoperability.
- One measured layout services repeated caret and selection queries without
  creating another backend handle.
- Layout handles are released on the correct executor exactly once.
- IME preedit, commit, delete-surrounding, candidate placement, and surface
  focus work in nonzero-origin and fractional-scale windows.
- Enabling secure mode after ordinary edits leaves no recoverable undo entry.
- Pasteboard operations respect focus, selection, secure entry, and responder
  routing.
- Bidirectional text and grapheme selection remain correct across multiple
  attributed runs.

## Phase 5: Correct the Core Graphics-shaped recording model

### Transform and path model

1. Carry the current transform consistently on every paint command.
   - Keep path geometry in local coordinates.
   - Let the render backend apply the complete affine transform to path fills,
     strokes, arcs, clips, gradients, images, and text.
   - Delete partial path pre-transformation that scales an arc rectangle using
     only matrix `a` and `d`.

2. Apply scalar geometry according to the transform.
   - Transform strokes as outlines so anisotropic scale behaves correctly.
   - Transform radial gradients as the corresponding ellipse where required.
   - Preserve reflection, rotation, skew, and scale-to-zero semantics.
   - Remove the determinant-based fallback that renders a nonzero scalar under a
     collapsed transform.

3. Correct `Path` state.
   - Compute an arc's real start and end points.
   - Connect the previous current point to the arc start according to the path
     contract.
   - Update `currentPoint` to the arc end.
   - Set the subpath start to the actual arc start when an arc opens a subpath.
   - Preserve current-point and close behavior under positive, negative, and
     full-circle sweeps.

### Numeric and semantic validation

4. Canonicalize drawing input at the public boundary.
   - Reject or normalize NaN and infinite geometry.
   - Clamp image saturation and other normalized effects.
   - Validate gradient stops, preserve deterministic ordering, and define how
     duplicate positions interpolate.
   - Define behavior for empty and negative-size rectangles consistently.
   - Correct `Rect.union` so any zero-area rectangle follows the documented empty
     semantics.

5. Document the supported graphics subset.
   - State the coordinate orientation, color-space behavior, blend modes,
     clipping model, interpolation behavior, and recording precision.
   - Remove claims that command storage or scalar handling exactly mirrors Core
     Graphics where it deliberately differs.
   - Keep advanced color spaces, patterns, PDF contexts, and other unneeded
     Core Graphics breadth outside the API until a real Nucleus consumer
     requires them.

### Behavioral gates

- Rotated, skewed, reflected, and anisotropically scaled ellipses and arcs match
  backend reference output.
- Strokes and radial gradients transform correctly under nonuniform scale.
- A collapsed transform produces no visible stroked geometry.
- Arc current-point behavior passes start, continuation, sweep-direction,
  full-circle, and close-subpath tests.
- Invalid numeric inputs cannot produce NaN bounds, damage, or renderer state.
- Every paint operation saves, restores, clips, and transforms through one
  consistent state model.

## Phase 6: Complete layout, scrolling, list, and grid foundations

### Constraint and invalidation hygiene

1. Canonicalize `LayoutConstraints`.
   - Require finite nonnegative minima.
   - Permit positive infinity only for maxima.
   - Normalize NaN, negative infinity, reversed ranges, and invalid insets.
   - Keep `constrain`, `inset`, and tight/up-to constructors closed over valid
     constraints.

2. Stop equal assignments from invalidating work.
   - Equality-check frame, transform, visibility, alpha, style, layout
     properties, scale, and window geometry.
   - Separate size changes from origin-only moves so layout and repaint are
     invalidated only when required.
   - Preserve scroll as one visual property update without repainting child
     recordings.

### Containers

3. Correct stack flexible-space resolution.
   - Implement iterative freeze-and-redistribute shrink behavior.
   - Respect zero shrink factors and minimum sizes.
   - Resolve insufficient `equalSpacing` space without overflowing by
     construction.
   - Replace quadratic identity membership loops with identity sets.

4. Extend reusable layout vocabulary.
   - Add first/last text-baseline alignment.
   - Add a wrapping flex container with row/column gaps and per-line alignment.
   - Add a grid container supporting fixed, flexible, and content-sized tracks.
   - Keep explicit minimum, maximum, basis, grow, and shrink policies on the
     child rather than introducing Auto Layout constraints.

### Scrolling and virtualization

5. Add a platform-neutral scroll interaction state machine.
   - Support pointer/touch dragging.
   - Track continuous-scroll velocity.
   - Begin kinetic scrolling at Wayland axis stop.
   - Cancel inertia on a new interaction.
   - Integrate reduced motion and deterministic frame-clock sampling.
   - Define bounded overscroll behavior or clamp without leaving ambiguous
     partial support.

6. Make scroll indicators interactive retained controls.
   - Add thumb hit testing, dragging, track paging, visibility policy, and
     frame-clock fade.
   - Preserve nested-scroll propagation when an inner view reaches its extent.

7. Strengthen `ListView`.
   - Require unique stable keys and diagnose duplicates.
   - Add item revisions so content changes do not require rebuilding every
     visible row.
   - Add insertion/removal/move snapshots with deterministic focus and selection
     preservation.
   - Add single and multiple selection models, keyboard navigation, activation,
     and scroll-to-selection.
   - Rebind recycled rows without detaching and recreating their visual layers.

8. Add a virtual grid.
   - Reuse the list's data-source identity, revision, selection, focus, and
     recycling contracts.
   - Support fixed or adaptive columns, row/column gaps, square cells, overscan,
     hit testing, keyboard navigation, and scroll-to-item.

### Behavioral gates

- Constraint constructors and transforms cannot propagate NaN into layout.
- Stack shrink always accounts for the full resolvable deficit after children
  reach minimum size.
- Wrapping and grid layout remain deterministic under fractional dimensions.
- Continuous scrolling produces one scroll-offset visual update per frame and
  no child repaint.
- Kinetic scrolling stops, cancels, and chains into a parent predictably.
- List and grid recycling preserve stable visual identity, focus, selection,
  pressed state, and active animations for an unchanged item.
- Large lists and grids retain only the visible pool plus configured overscan.

## Phase 7: Finish responder, input, focus, and control behavior

### Pointer and touch routing

1. Replace the scene's single capture slot with per-sequence capture.
   - Give mouse/pointer and each touch sequence a stable identity.
   - Track hover separately from capture.
   - Capture a pointer-down only after the target handles it or explicitly
     requests capture.
   - Release on up, cancellation, subtree removal, window removal, surface
     leave, and host teardown.

2. Extend neutral event data where platform adapters need it.
   - Carry device identity, active button mask, pointer sequence identity,
     pressure/tool metadata when available, and scroll phase state.
   - Keep raw platform numbering inside adapters.
   - Do not add generic gesture or drag-and-drop APIs until a platform consumer
     defines their required contract.

### Responder and focus safety

3. Prevent responder-chain cycles.
   - Restrict arbitrary `nextResponder` mutation or validate assignments.
   - Add cycle detection to raw-event and action traversal as a final safety
     boundary.
   - Keep framework-owned parent/view-controller/window routing authoritative.

4. Complete focus scopes.
   - Preserve tree-order traversal as the default.
   - Add explicit focus groups/scopes for popovers, menus, dialogs, and
     composite controls.
   - Restore focus by stable key after retained-tree replacement.
   - Add a standard focus-ring drawing hook and accessibility focus notification.

### Controls

5. Make control state observable and drawable.
   - Invalidate display when enabled, hovered, highlighted, pressed, focused, or
     selected state changes.
   - Provide a state-to-style seam so custom controls do not reimplement the
     state machine.
   - Ensure disabling a pressed control releases capture and clears transient
     state.

6. Correct keyboard activation.
   - Activate buttons with Space and Return according to focus/default-button
     rules.
   - Preserve pressed visual feedback across key down/up.
   - Route standard editing and selection actions through the responder chain.
   - Keep tab-stop behavior distinct from programmatic first-responder
     eligibility.

7. Establish a compact reusable control set.
   - Complete button chrome, toggle, checkbox, radio group, slider, range
     slider, progress indicator, separator, segmented control, select/popover,
     and context-menu primitives.
   - Build each control from shared focus, accessibility, animation, text, and
     style contracts.
   - Keep product-specific appearance out of NucleusUI.

### Behavioral gates

- Two simultaneous touch sequences retain independent targets and local
  coordinates.
- An unhandled pointer-down does not steal capture.
- Removing a captured view delivers cancellation and leaves no retained view.
- Responder cycles cannot hang event or action delivery.
- Button pointer, keyboard, programmatic, and accessibility activation share one
  primary-action path.
- Every control state change produces the required repaint and accessibility
  notification exactly once.
- Focus remains trapped within modal scopes and returns to the prior stable key
  when the scope closes.

## Phase 8: Export real accessibility and appearance policy

### Platform-neutral accessibility tree

1. Give accessible elements stable semantic IDs.
   - Snapshot role, label, description, value, state, actions, selection,
     orientation, range, parent/child relationships, and window ownership.
   - Compute frames through the normalized coordinate pipeline.
   - Support virtual children for lists, grids, text ranges, and other
     non-materialized content.

2. Expand roles and actions.
   - Add the roles needed by standard controls, menus, lists, grids, headings,
     dialogs, alerts, switches, sliders, tabs, and secure text.
   - Add focus, press, increment, decrement, select, expand/collapse, dismiss,
     and text-editing actions.
   - Preserve secure-field redaction in every value and text-range operation.

3. Publish incremental accessibility changes.
   - Diff semantic generations rather than rebuilding the entire tree.
   - Notify focus, value, selection, structure, bounds, announcement, and live
     region changes.
   - Remove accessible objects deterministically with their semantic owners.

### Linux adapter

4. Implement an AT-SPI2 bridge outside NucleusUI.
   - Translate the neutral tree and actions onto the AT-SPI D-Bus interfaces.
   - Marshal calls onto the UI actor without blocking it on D-Bus work.
   - Preserve stable object paths for stable semantic IDs.
   - Cleanly unregister windows and descendants on scene teardown.

### Environment policy

5. Consolidate accessibility and appearance preferences in `UIContext`.
   - Include reduced motion, reduced transparency, increased contrast, color
     appearance, and text scale.
   - Resolve semantic backdrop materials once from the environment.
   - Invalidate only consumers affected by a changed preference.
   - Keep the preference source in the platform host.

### Behavioral gates

- A fake accessibility adapter observes a stable, correctly framed tree and can
  invoke actions.
- The AT-SPI bridge exposes windows, controls, text, lists, and dialogs with
  stable object identity.
- Focus, value, selection, announcement, and subtree changes emit the matching
  platform event.
- Virtualized offscreen items remain discoverable without materializing their
  visual views.
- Secure text cannot be read through accessibility.
- Reduced transparency, increased contrast, text scale, and reduced motion
  update all affected UI through one environment change.

## Phase 9: Clarify NucleusApp, context ownership, and public API claims

### Explicit context ownership

1. Remove silent production fallback contexts.
   - Require a `UIContext` and visual host context when constructing a
     renderable scene.
   - Keep explicit in-memory contexts for tests and tooling.
   - Diagnose view construction outside an installed context immediately rather
     than producing an orphan tree.

2. Replace the process-wide context stack as the long-term ownership model.
   - Make a scene or scene-construction scope explicitly own its `UIContext`.
   - Pass environment and service dependencies through that scope.
   - Keep synchronous convenience scoping only as construction syntax.
   - Prevent an async operation from accidentally resuming under a different
     ambient context.

### Scene and window lifecycle

3. Define NucleusApp's retained lifecycle precisely.
   - Materialize scene descriptions once.
   - Let the host own presentation, output/surface assignment, activation, and
     teardown.
   - Add scene lifecycle callbacks and environment updates without introducing
     reactive body reconciliation.
   - Support multiple windows and platform surface roles through typed host
     requests.

4. Make window roles platform-useful.
   - Keep scene ordering separate from Wayland surface role.
   - Add typed window/surface intent for ordinary application, layer-shell,
     popup, notification, overlay, lock, and hosted content where the host needs
     it.
   - Keep protocol-specific anchors, exclusive zones, keyboard interactivity,
     and configure/ack state in the Wayland adapter.

### API honesty and Swift 6.4 hygiene

5. Remove false parity claims.
   - Replace “verbatim,” “property-for-property,” and “mirrors” with an explicit
     behavioral mapping when the API is a subset.
   - Document top-left coordinates, retained construction, whole-recording
     drawing, semantic materials, and supported layer-animation properties.
   - Maintain a concise Apple-to-Nucleus mapping for familiar concepts and their
     deliberate differences.

6. Remove unnecessary actor isolation from value vocabulary.
   - Keep `Window`, `View`, scenes, mutable controllers, and UI services on the
     main actor.
   - Remove `@MainActor` from immutable `Sendable` enums and option sets such as
     role and level vocabularies.
   - Prefer typed throws for recoverable host/backend operations.
   - Use noncopyable types only for resources with real single-consumption
     semantics.
   - Use `isolated deinit` for actor-confined platform resources.

### Behavioral gates

- Production view construction cannot silently enter an in-memory context.
- Two concurrently owned scenes cannot mint identities or environment state
  into each other's context.
- NucleusApp hosts multiple retained scenes with deterministic activation and
  teardown.
- Platform role configuration remains outside the portable view model.
- Public documentation distinguishes supported Apple-shaped behavior from
  intentional divergence.
- Pure value types are usable from non-main executors without unnecessary
  isolation hops.

## Phase 10: Make publication and repaint scale with dirty work

This phase optimizes the corrected single-authority architecture. It does not
preserve the current full-tree snapshot algorithm for compatibility.

### Incremental publication

1. Replace recursive child snapshot arrays with a flat traversal.
   - Preallocate from retained visible-node counts where useful.
   - Append parent-before-child records directly.
   - Eliminate subtree array copying.

2. Traverse dirty branches only.
   - Use per-category model generations and the publisher's last-seen
     generations.
   - Reconcile structure only when a structural generation changes.
   - Reconcile geometry, style, visibility, content, and animation independently.
   - Preserve a fast clean-root exit.

3. Keep geometry precision stable.
   - Diff public model geometry as `Double`.
   - Narrow once while lowering the committed transaction to render-model
     precision.
   - Canonicalize insignificant negative zero and invalid numeric state before
     diffing.

4. Reduce content churn.
   - Reuse equal `PaintRecording` registrations.
   - Cache text/image/runtime-effect resource keys independently of view
     identity.
   - Preserve registered content across reparent, hide/show, recycling, and
     geometry-only changes.
   - Retire generation-scoped resources only after the renderer can no longer
     reference them.

### Damage and repaint

5. Add damage-aware paint publication.
   - Track invalidated local regions when a view can safely provide them.
   - Preserve untouched texture content or issue partial texture updates.
   - Fall back to whole-recording replacement for effects or commands that
     cannot be safely localized.
   - Promote frequently animated visual properties to retained semantic layer
     properties instead of repainting them.

6. Keep output damage derived from published changes.
   - Geometry changes damage old and new presentation bounds.
   - Visibility, backdrop, shadow, clip, transform, and content changes report
     their actual affected bounds.
   - Clean outputs do not acquire or present.

### Instrumentation and stress gates

7. Add persistent tracing around:
   - semantic dirty counts by category;
   - nodes visited and skipped;
   - visual layers created, retained, reparented, hidden, and removed;
   - property updates and content registrations;
   - text layouts and retained-handle hits;
   - paint bytes and damage regions;
   - animation counts and completion latency;
   - accessibility nodes diffed and events emitted.

8. Add deterministic stress fixtures.
   - Deep view trees prove traversal is linear.
   - Wide trees prove flat publication avoids per-parent subtree copying.
   - Repeated clean frames produce zero commits and zero content registrations.
   - One leaf property change visits only its dirty ancestry and leaf.
   - Continuous list/grid scrolling keeps layer and resource counts bounded.
   - Hide/show, reorder, output move, fractional-scale change, and scene teardown
     preserve resource-lifetime invariants.

### Exit criteria

- Publication work is proportional to changed structure/state rather than total
  scene size on clean and localized-update frames.
- A clean frame performs no transaction encoding, content registration, output
  acquisition, or presentation.
- Deep-tree traversal allocates no child snapshot arrays.
- Geometry is narrowed exactly once.
- Resource counts remain bounded during long-running scrolling, animation,
  tooltip, popover, and scene lifecycle stress tests.
- Tracing distinguishes producer invalidation, publication, renderer apply,
  raster work, and presentation.

## Phase 11: Close correctness, diagnostics, and documentation gates

### Error and lifetime audit

1. Remove swallowed errors from foundation code.
   - Replace `try?` mutation/commit paths with scoped transactions, explicit
     propagation, or a host diagnostic policy.
   - Treat duplicate semantic IDs, duplicate list keys, cross-context layer use,
     responder cycles, invalid geometry, and protocol state violations as
     actionable diagnostics.

2. Audit ownership boundaries.
   - Prove scene, window, view, visual layer, registered content, text handle,
     animation handle, accessibility object, Wayland proxy, and output surface
     teardown order.
   - Eliminate unowned references where externally driven teardown can violate
     lifetime assumptions.
   - Make close/remove operations idempotent.

3. Audit public Sendable and isolation declarations.
   - Remove unchecked conformance where executor ownership can express the
     contract.
   - Ensure callbacks crossing adapters are either `Sendable` values or
     explicitly marshalled onto the owning actor.
   - Keep non-Sendable platform handles out of portable public values.

### Behavioral verification

4. Add end-to-end tests using the real render transaction applier.
   - Construct, publish, mutate, animate, hide, reparent, and destroy a scene.
   - Verify render topology, model properties, presentation completion, damage,
     and resource release.
   - Exercise standalone, compositor-embedded, and Wayland-client host adapters
     through the same conformance suite.

5. Add randomized behavioral tests.
   - Generate valid view-tree mutations and compare semantic topology with the
     published render topology.
   - Generate transforms and verify point conversion round trips where the
     transform is invertible.
   - Generate layout constraints and assert canonical finite results.
   - Generate text edit/composition sequences and assert valid UTF-16,
     grapheme, selection, undo, and secure-entry state.

6. Run the complete host verification path.
   - Source `core/tools/host-env.sh` from the monorepo root.
   - Run the relevant core, compositor-core, shell-adapter, and complete
     top-level build/test commands.
   - Run optimized stress fixtures with tracing enabled.
   - Run the compositor and shell only when interactive validation is explicitly
     requested.

### Documentation result

7. Publish the final foundation contract.
   - Document UI and visual ownership.
   - Document every coordinate space and conversion.
   - Document transaction, animation, completion, and reduced-motion semantics.
   - Document text backend installation, editing, IME, secure entry, and
     pasteboard behavior.
   - Document graphics and Core Animation subsets.
   - Document layout, scrolling, list/grid identity, responder, focus, and
     accessibility behavior.
   - Document NucleusApp's retained lifecycle and platform host obligations.

### Final exit criteria

- Every mutable foundation concept has one owner and one publication route.
- Every platform service is installed through an explicit adapter.
- Standalone and embedded scenes share the same tested semantics.
- No first publication, coordinate conversion, transaction lifetime, text
  handle, animation completion, or accessibility path relies on a silent
  fallback.
- Public API claims match implemented behavior.
- Full host builds and behavioral suites pass without modifying vendored
  dependencies or relying on an interactive compositor session.
