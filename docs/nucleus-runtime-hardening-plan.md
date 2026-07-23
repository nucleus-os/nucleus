# Nucleus Runtime Hardening Plan

## State invariant

Every mutable runtime authority has one explicit owner, every executor and
native-resource boundary is mechanically enforced, and one repository command
reproduces the complete agent-runnable correctness contract in debug, release,
and sanitizer configurations. Portable semantic tests use deterministic time.
Performance work is driven by headless structural and allocation evidence before
hardware profiling begins.

This plan starts after the foundation work in
`docs/nucleus-foundation-follow-up-plan.md`. Its phases are strictly sequential.
Phase N+1 begins only after Phase N's behavioral gate passes. Replaced global
APIs and old execution paths are deleted in the phase that replaces them.

Physical display, input-device, suspend/resume, VT, and real GPU validation are
outside this plan. No phase launches the compositor or shell as an automated
verification step.

## Objectives

1. Remove residual mutable process globals from UI, render-model, resource, and
   host-bundle ownership.
2. Split the remaining large owner files by implementation responsibility
   without adding duplicate owners or indirection.
3. Make debug tests, release structural stress, warning hygiene, and public API
   extraction reproducible through the workspace tool.
4. Exercise first-party Swift/C/C++ ownership and concurrency under sanitizers,
   fault injection, and adversarial teardown.
5. Replace portable real-time sleeps with a context-owned deterministic clock.
6. Establish repeatable headless performance, allocation, copy, and structural
   baselines.

## Current evidence

The completed foundation work leaves these concrete follow-ups:

- `GlyphCatalog.shared` is mutable UI configuration shared by every context in
  the process.
- `RetainedTreeStore.shared` is an implicit render-tree authority.
- `SwiftResourceHost.shared` implicitly owns paint, image, snapshot, runtime
  effect, and implicit-action state.
- `RenderCore`, `FrameDriver`, `RenderCommitSink`, and the production host
  conformers reach into those global authorities instead of receiving their
  runtime's concrete owners.
- `activeProductionHostBundle` is a mutable global installation point.
- `RenderCore.swift`, `InputDispatch.swift`, and `XdgShell.swift` still combine
  several independent mechanisms in one file.
- `tools/nucleus test` runs debug package suites but does not run the six named
  release structural suites.
- A release shell test requires a release
  `libNucleusReactRuntimeHostCxx.a`, but the normal debug RN build and current
  provisioning success condition do not guarantee that archive exists.
- Whole-package `dump-symbol-graph` drives C++ headers through an incompatible
  ExtractAPI language mode; direct Swift compiler symbol-graph emission works.
- ASan is exposed only through the interactive profile workflow, with leak
  detection disabled. Package tests have no sanitizer authority.
- Menu, list, and grid interaction deadlines call `Task.sleep` directly, and
  portable tests wait on wall-clock time.
- Structural stress counters exist, but there is no headless benchmark product
  that reports constant-factor cost, allocations, or copied bytes.

## Cross-phase engineering rules

- Existing compositor, shell, Android, RN, and test runtime roots own the new
  concrete state. Do not add a global service locator or a second runtime graph.
- Do not preserve `.shared` fallbacks, optional compatibility routes, or dual
  commit/resource paths.
- Keep UI and protocol mutation on their existing global actors. Cross-actor
  values are immutable and `Sendable`.
- Keep one `RenderCore`, one retained tree, one resource host, one AT-SPI
  connection owner, and one input dispatcher per runtime graph.
- File decomposition uses extensions, focused value helpers, and existing seams.
  It does not introduce manager objects that mirror owner state, protocols with
  one conformer, type erasure, callback pyramids, or dynamic dispatch in hot
  paths.
- Non-C++ modules do not import C++ modules. C++ bring-up continues through the
  established C-compatible closure/protocol seams.
- No test asserts source declaration shape. Tests assert behavior, ownership,
  wire results, counters, and public compiler output.
- Generated and vendored code remains untouched unless a first-party boundary
  cannot be corrected without changing it.
- Randomized and fuzz failures always print the seed and minimized input.
- Structural and ownership budgets are hard correctness gates. Wall-clock
  measurements are diagnostic until a stable machine-independent bound exists.

## Phase 1: Make every runtime graph explicitly owned

### Required end state

Each host runtime constructs one resource host and one retained-tree store,
threads them through its existing bring-up root, and destroys them after every
context, producer, render operation, and native callback has stopped. No portable
UI or render-model type discovers mutable runtime state through `.shared`.

### Resource and retained-tree ownership

Change `SwiftResourceHost` from a global singleton into a normal runtime-owned
object:

- Delete `SwiftResourceHost.shared`.
- Keep `PaintContentStore`, `SnapshotService`, `ImageStore`,
  `RuntimeEffectStore`, and the immutable implicit-action snapshot as its owned
  members.
- Make every Swift resource-host conformer require a concrete
  `SwiftResourceHost` at initialization.
- Make `FrameDriver` and render-time resolver closures use the concrete host
  owned by their `RenderCore`.
- Drain eviction and retirement queues through that concrete host only.

Change `RetainedTreeStore` into an explicitly injected authority:

- Delete `RetainedTreeStore.shared`.
- Give the store the concrete implicit-action source it needs at construction.
- Remove the fallback from `expandImplicitActions` to the global resource host.
- Make `RenderCommitSink` require a store; remove its default `.shared` value.
- Make `RenderCore.create` require the same store and resource host used by its
  producer commit sink.
- Preserve one tree revision, animation ledger, completion ledger, and
  presentation-dirty authority per runtime graph.

The host-specific existing roots perform construction:

1. Construct `SwiftResourceHost`.
2. Construct `RetainedTreeStore` against that resource host's implicit-action
   authority.
3. Construct the production host bundle and `RenderCommitSink` against those
   objects.
4. Construct UI contexts and producers with that bundle and sink.
5. Construct `RenderCore` with the same store and resource host.
6. On shutdown, stop producers and async work, disconnect contexts, retire
   resources, destroy `RenderCore`, and finally release the store and resource
   host.

Apply this order in:

- The compositor render service/runtime.
- The out-of-process shell render engine/runtime.
- Android render-engine bring-up.
- Direct/headless embedder fixtures.
- RN/Fabric host-projection fixtures.

### Host-bundle ownership

Delete the mutable `activeProductionHostBundle` installation model:

- Make production bundle construction return a concrete
  `NucleusAppHostBundle` owned by the host runtime.
- Pass the bundle into each layers/UI context that consumes it.
- Make every registrar and lifecycle conformer capture or store its concrete
  runtime-owned resource host.
- Delete `currentProductionHostBundle`, the global install/uninstall API, and all
  callers in the same phase.
- Preserve C/C++ boundaries by carrying only the existing opaque handles and
  scalars. Do not expose `SwiftResourceHost` or `RetainedTreeStore` through a C++
  module import.

If a C callback requires a stable context pointer, the owning host bundle retains
one single-reference callback context and releases it when the bundle is torn
down. The pointer is never recovered through a process-global Swift variable.

### Context-owned glyph configuration

Delete `GlyphCatalog.shared`:

- Add the default glyph catalog to `UIContext` construction and environment
  propagation.
- Require both Linux UI hosts, Android, and test contexts to install their
  catalog before view construction when named glyphs are used.
- Preserve `GlyphView.catalog` as the explicit per-view override.
- Resolve a glyph from the explicit override, then the owning context. An
  unattached view without an explicit catalog resolves no named glyph.
- Invalidate only glyph views whose effective catalog or catalog generation
  changes.
- Remove tests that save and restore the global catalog. Replace them with two
  context-isolation fixtures.

### Typed runtime identity

Remove dummy non-zero handles whose comments say the value is ignored:

- Define a typed Swift runtime/resource-host identity where identity is part of
  the Swift contract.
- Keep raw integer or opaque pointer forms only at genuine C-compatible closure
  boundaries.
- Validate a boundary handle against its owning bundle before mutation.
- Reject stale handles after runtime teardown without reaching released Swift
  objects.

### Phase 1 behavioral gate

Prove all of the following before Phase 2:

- Two complete runtime graphs coexist in one process with distinct trees,
  resource stores, implicit-action tables, glyph catalogs, and completion
  ledgers.
- A commit into runtime A cannot change runtime B's revision, frame demand,
  resource counts, animation state, or diagnostics.
- Identical resource payloads deduplicate within one runtime and never share
  handles across runtimes.
- Destroying runtime A while runtime B remains active releases only A's paint,
  image, snapshot, effect, completion, and callback state.
- A late callback carrying A's retired identity is rejected deterministically.
- Both Linux hosts, Android, retained-scene, embedder, and Fabric fixtures use the
  explicit runtime graph.
- Searches of first-party foundation and render code find no mutable `.shared`
  fallback for glyph, render-tree, resource-host, or host-bundle state.

## Phase 2: Split the remaining large owners without changing authority

Phase 1 pins explicit ownership before file boundaries move. Phase 2 changes
implementation organization only; wire behavior, actor isolation, resource
identity, and counter results remain unchanged.

### Split live AT-SPI transport

Keep `AtSPIService` as the only connection, registration, reconnect,
queue, and teardown owner. Move implementation into these focused files:

- `AtSPIService.swift`: bus discovery, connection, registration,
  embedding, reconnect, diagnostic deduplication, processing, and close.
- `AtSPIMessageDispatch.swift`: object-path lookup, interface/method routing,
  signature validation, and exactly-once protocol-error translation.
- `AtSPIAccessibleInterfaces.swift`: Accessible, Application, Properties, role,
  state, relation, and object-reference replies.
- `AtSPIActionComponentInterfaces.swift`: Action, Component, Value, and
  Selection handling.
- `AtSPITextInterfaces.swift`: Text and EditableText decoding, UTF-16 range
  conversion, secure-text rejection, and mutation results.
- `AtSPIEventEncoder.swift`: event mapping, message construction, emission, and
  bounded pending-event behavior.
- `AtSPIMessageCodec.swift`: shared-writer extensions, scalar/container
  decoding, reply construction, and checked string/length conversion.

`AtSPIWireContract.swift` remains the one signature and introspection authority.
Interface files consume it rather than duplicating signatures.

Do not give the focused files their own connection, slot collections, object
maps, retry state, or event queues. Cross-file methods remain actor-isolated on
the service. State that must be visible across extension files stays internal
to the `NucleusLinuxAccessibility` module.

### Split render orchestration

Keep `RenderCore` as the one owner of Vulkan/Graphite lifetime, `FrameDriver`,
the injected store/resource host, output state, imported client resources,
snapshots, and shutdown order. Move implementation into:

- `RenderCoreBringup.swift`: Vulkan qualification, device selection, Graphite
  construction, and explicit dependency injection.
- `RenderCoreOutputs.swift`: output geometry, root-context association,
  lock-composition state, and presentation ledgers.
- `RenderCoreFrameRecording.swift`: frame demand, target wrapping, tree snapshot,
  frame-plan submission, telemetry, and accepted-presentation bookkeeping.
- `RenderCoreCapture.swift`: output/surface readback, dmabuf capture, and checked
  blit operations.
- `RenderCoreClientResources.swift`: dmabuf import, acquire semaphores, SHM upload,
  upload coalescing, release synchronization, and retirement.
- `RenderCoreSnapshots.swift`: snapshot capture, registration, resolution,
  reference lifetime, and retirement.
- `RenderCoreTeardown.swift`: resource shutdown, completed-submission retirement,
  GPU idle, Graphite release, and device/instance teardown.

Retain all stored state on `RenderCore`. Existing focused value types such as
`ClientAcquireSemaphore`, `PendingShmUploadQueue`,
`OutputPresentationLedger`, and `CaptureOverlay` remain values; do not turn them
into independently scheduled owners.

### Split compositor input dispatch

Keep `InputDispatch` as the sole accepted input-stream state and routing owner.
Move mechanisms into:

- `InputDispatchFocus.swift`: pointer/keyboard focus and session-lock gating.
- `InputDispatchKeyboardTouch.swift`: shortcut tap, XKB state, keyboard routing,
  and touch grabs.
- `InputDispatchPointer.swift`: motion, buttons, scrolling, seat delivery, and
  pointer constraints.
- `InputDispatchChrome.swift`: chrome hit testing, buttons, double-click policy,
  cursor intent, and interactive move/resize grabs.
- `InputDispatchOverlay.swift`: embedded overlay pointer/key projection,
  workspace commands, and overlay frame requests.
- `InputDispatchState.swift`: accepted stream snapshots, timestamps, key maps,
  display removal, and terminal reset.

Do not copy cursor/button/focus state into helpers. Every event still enters one
`dispatch` method and produces one terminal `Result`.

### Split XDG protocol mechanics

Keep `XdgShell` as the global factory and delegate seam. Retain the existing
`XdgPositioner.swift`, then move:

- wm-base binding and ping/pong mechanics to `XdgWmBase.swift`.
- configure ledger, ack/commit latch, geometry, and role construction to
  `XdgSurface.swift`.
- toplevel request decoding, interactive authorization, configure events, and
  destruction to `XdgToplevel.swift`.
- popup construction, placement, grab authorization, configure, reposition,
  and teardown to `XdgPopup.swift`.

Every libwayland resource keeps one Swift owner and one idempotent destruction
path. Protocol errors remain translated once at request entry points.

### Access-control and dependency gate

- Keep public and SPI surfaces unchanged unless a symbol is proven unnecessary;
  delete unnecessary symbols and fix all callers immediately.
- Use `package` access only for cross-file implementation state.
- Keep package DAG rules intact: input does not import shell, non-C++ modules do
  not import C++ modules, and renderer value helpers do not acquire host policy.
- Add no tests based on file size, declaration location, or source shape.

### Phase 2 behavioral gate

Run the full behavioral suites established by the foundation plan and verify:

- AT-SPI live bus replies, errors, reconnects, incremental events, virtual
  objects, and teardown are byte-for-byte and count-for-count equivalent.
- Render frame plans, pixels, damage, snapshots, resource retirement,
  presentation outcomes, and telemetry are unchanged.
- Input focus, pointer, keyboard, touch, overlay, chrome, cursor, and interactive
  grab fixtures produce the same results.
- XDG construction, configure/ack/commit, popup placement, serial validation,
  protocol errors, and destruction remain wire-equivalent.
- Structural counters and allocations do not increase for clean publication,
  one-leaf updates, input dispatch, or frame construction.
- Each large mechanism now exposes one visually obvious owner and focused
  implementation boundaries.

## Phase 3: Make workspace verification complete and reproducible

### One authoritative test sequence

Extend `tools/nucleus test` so its unqualified invocation performs this strict
sequence:

1. Test `swift-tracy`.
2. Test `swift-vulkan`.
3. Test `swift-wayland` with C++ interoperability.
4. Test `core` with C++ interoperability.
5. Test `platform-linux`.
6. Test `react-native` with C++ interoperability.
7. Test `compositor/compositor-core` with C++ interoperability.
8. Test `compositor/compositor`.
9. Test `shell`.
10. Build and provision every release-only native archive required by downstream
   release test products.
11. Run all six named release structural suites.
12. Emit and validate public foundation symbol graphs.

Keep component selection for local iteration, but the unqualified command is the
complete repository authority. It prints the component, package, configuration,
and suite before execution and includes them in every failure.

### Release archive provisioning

Make release provisioning explicit:

- Build `NucleusReactRuntimeCxx` in release first so its generated C++ header
  exists.
- Build the `NucleusReactRuntimeHostCxx` release product, not only its target
  object.
- Extend `provision-cxx-libs` with a required configuration argument.
- When `release` is required, fail unless every declared archive exists in the
  release product directory and is copied successfully.
- Verify archive fingerprints and configuration metadata before a downstream
  shell or compositor release link.
- Keep debug and release archives separate. Never fall back from one
  configuration to the other.

### Release structural suite integration

Run these exact suites after debug tests:

- `NucleusFoundationPublicationStressTests`
- `NucleusFoundationLifecycleStressTests`
- `NucleusTextEditorStressTests`
- `NucleusCollectionStressTests`
- `NucleusPlatformTransportStressTests`
- `NucleusCompositorTransitionStressTests`

The orchestrator owns their package paths and required compiler flags. Developers
do not reproduce six hand-written commands to obtain the release gate.

### Public API extraction

Add `tools/nucleus api` and invoke it from the complete test sequence:

- Build the public Swift targets with compiler-native `-emit-symbol-graph` and a
  dedicated output directory under `core/.build`.
- Emit at least `NucleusTypes`, `NucleusLayers`, `NucleusUI`,
  `NucleusUIEmbedder`, `NucleusRenderModel`, and `NucleusRenderHost`.
- Use public minimum access and omit synthesized members.
- Validate that every requested module produced a non-empty graph.
- Report public symbols missing ownership, actor-isolation, units, coordinate
  space, lifetime, or error documentation where those concepts apply.
- Do not drive unrelated C++ header targets through whole-package ExtractAPI.
- Do not freeze obsolete APIs for compatibility. An intentional deletion updates
  the generated surface and all callers in the same phase.

### Warning hygiene

Clear existing first-party warnings, including:

- Deprecated C-string construction in the PAM helper.
- Redundant typed-catch casts in DBus tests.
- Ignored `createFile` results in shell service tests.
- Optional `pkg-config` diagnostics that currently obscure whether the audit
  dependency is intentionally absent or incorrectly provisioned.
- Workspace process-launch signal-reset warnings that can be corrected in
  first-party code.

After cleanup, enable warnings-as-errors for first-party Swift, C, and C++
targets. Scope the rule so generated and vendored warning policy remains owned by
those dependencies.

### Phase 3 behavioral gate

Source `tools/host-env.sh` and require all of the following to pass from a
correctly provisioned checkout:

```sh
tools/nucleus doctor
tools/nucleus build
tools/nucleus test
tools/nucleus api
```

Then verify failure reporting by intentionally selecting a nonexistent component
and by running the release provisioner against a temporary missing-archive
fixture. These fixtures must fail before downstream linking and identify the
missing component/configuration/archive.

The gate passes with no first-party compiler warnings and without launching a UI
host.

## Phase 4: Add sanitizers, fault injection, and adversarial teardown

Phase 3 establishes reliable normal builds before instrumented builds are added.
Sanitizer configurations are verification modes, not product feature profiles;
they compile the same integrations and code paths.

### Sanitizer command ownership

Add a workspace sanitizer command that:

- Sources the same host environment and native SDK metadata as normal tests.
- Uses separate package build directories so sanitizer artifacts never satisfy a
  normal debug/release link.
- Reports package, test product, sanitizer, seed, and relevant runtime options.
- Runs focused suites sequentially to preserve readable native diagnostics.
- Exits on the first sanitizer finding after preserving its complete report.

### Address and leak sanitizers

Run ASan and LSan over first-party ownership-heavy targets:

- Layer/context construction and teardown.
- Render transaction apply and retained-tree destruction.
- Paint, image, runtime-effect, snapshot, and upload lifecycles.
- Wayland resource construction, arbitrary destruction order, and client
  disconnect.
- DBus message, slot, watch, timeout, reconnect, and close.
- Shell pasteboard and drag transfer descriptors.
- RN host construction, mounting bursts, runtime failure, and teardown.
- C/C++ buffer conversion and callback trampolines.

Enable leak detection for test products. If an external runtime makes leak
detection unusable, isolate that exact product and document the external
allocation; do not disable leak detection globally.

### Undefined-behavior sanitizer

Instrument first-party C/C++ shims and libraries for:

- Signed and unsigned overflow before narrowing.
- Shift-width and alignment violations.
- Invalid enum and boolean representations.
- Out-of-bounds pointer arithmetic.
- Null and misaligned pointer dereference.
- Object lifetime misuse across Swift/C++ callbacks.

Keep existing checked Swift arithmetic at C/C++ boundaries and add fixtures for
maximum dimensions, row strides, offsets, plane counts, descriptor lengths, and
UTF encodings.

### Thread sanitizer

Run TSan separately over concurrency-focused suites:

- Async render wake coalescing and shutdown.
- Image decode worker submission, cancellation, drain, and deinit.
- RN mount and JS timer delivery across threads.
- DBus callback processing, cancellation, and reconnect.
- Pasteboard and drag async generation replacement.
- Observation scheduling and cancellation.
- Renderer completion and retirement callbacks.

Do not combine TSan with ASan. Fix races by restoring actor isolation, immutable
message passing, or one documented `Mutex`; do not silence findings with
unchecked annotations.

### Deterministic fault injection

Use existing protocol and host seams to inject failures at ownership boundaries:

- Allocation or registration failure after each successfully created native
  resource.
- DBus connection loss before registration, during a reply, while events are
  queued, and during teardown.
- Wayland client destruction before ack, during drag, while a buffer is pending,
  and after resource retirement begins.
- Vulkan import, semaphore, capture, submit, and completion failures.
- Short reads/writes, `EINTR`, `EAGAIN`, closed descriptors, and invalid sync
  files.
- RN runtime failure before install, during mount delivery, and during shutdown.
- Async image cancellation before resolve, decode, registration, and UI apply.

Fault controls exist only in test-owned fakes or injected closures. Production
code does not gain environment-controlled alternate behavior.

### Boundary fuzzing

Add bounded fuzz/property harnesses for pure first-party decoders and validators:

- AT-SPI/DBus scalar, variant, container, and signature decoding.
- Wayland request state machines and serial ledgers.
- Dmabuf plane/offset/stride layout validation.
- SHM and raw-pixel row conversion.
- Paint/path payload decoding.
- UTF-8/UTF-16 surrounding-text, selection, and preedit conversion.
- Collection snapshot/reorder generation validation.

Persist the seed and minimized byte/value input for every failure. Fuzz harnesses
enforce maximum input sizes and never require a compositor session.

### Phase 4 behavioral gate

- All focused ASan/LSan, UBSan, and TSan suites pass with zero first-party
  findings.
- Every injected failure returns a typed error, protocol error, cancellation, or
  diagnostic and restores structural/native counters to baseline.
- Random destruction order never double-destroys, leaks, traps through `unowned`,
  or calls a released owner.
- Fuzz/property runs complete their configured deterministic corpus and seeds
  without crashes, hangs, unbounded allocation, or sanitizer findings.
- The normal `tools/nucleus test` gate still passes after sanitizer-specific
  changes.

## Phase 5: Make portable time deterministic

Phase 4 validates current cancellation and callback ownership before the clock
source changes.

### One context-owned monotonic clock

Add one package-level UI clock value owned by `UIContext`. It provides:

- A monotonic `now` value.
- Cancellation-aware sleep until a monotonic deadline.
- Duration-to-deadline conversion with checked/saturating arithmetic.
- No calendar, timezone, wall-clock, or platform-run-loop behavior.

The production implementation uses `ContinuousClock`. A manual test
implementation stores ordered waiters, advances only when the fixture requests
it, resumes every waiter whose deadline was reached, and removes cancelled
waiters exactly once.

The clock crosses no C/C++ boundary and adds no dynamic dispatch to layout,
publication, input, or render hot paths. A small captured closure/value seam is
sufficient; do not introduce a timer manager hierarchy.

### Migrate portable interaction deadlines

Replace direct sleeps in strict order:

1. Menu submenu-open, pointer-aim, dismissal, and type-ahead deadlines.
2. List type-ahead reset.
3. Grid type-ahead reset.
4. Async image negative-cache expiry and retry tests where wall-clock time is
   currently observable.
5. Any remaining portable UI debounce or delayed-action task discovered by the
   migration audit.

Each task remains owned by its existing controller/view and is cancelled by
selection changes, snapshot changes, hierarchy removal, scene disconnect, and
deinit. Advancing the clock after cancellation must not mutate UI state.

Animation sampling remains driven by authored/presentation timestamps. Do not
replace frame-clock semantics with the interaction clock.

### Deterministic tests

Replace wall-clock waits with explicit clock advancement:

- Assert the state immediately before a deadline.
- Advance to one tick before the deadline and assert no transition.
- Advance to the deadline and drain the owning actor once.
- Assert exactly one transition and one structural update.
- Cancel or replace the task, advance beyond the old deadline, and assert no
  stale transition.
- Exercise multiple deadlines at the same instant in stable insertion order.

Keep real polling in live Wayland and DBus transport suites. Those tests validate
kernel/socket integration rather than portable semantic time.

### Phase 5 behavioral gate

- Portable core UI tests contain no `Task.sleep`, `usleep`, `nanosleep`, timer,
  or `asyncAfter` wait for semantic behavior.
- Menu, list, grid, image retry, observation, and teardown tests pass using the
  manual clock.
- Cancelling, replacing, disconnecting, and destroying clock-owned tasks returns
  waiter/task counters to baseline.
- Test outcomes are identical under slow and fast test executors because no
  assertion depends on scheduling latency.
- Live transport suites continue to pass with their real kernel-driven polling.

## Phase 6: Add headless performance and allocation baselines

Phase 5 removes scheduler latency from portable measurements before benchmark
baselines are recorded.

### Benchmark product and command

Add a release-built, headless benchmark executable and expose it through
`tools/nucleus benchmark`:

- It imports only portable/core modules and first-party headless test support.
- It does not initialize DRM/KMS, create a Wayland display, launch either UI
  host, or require a physical GPU.
- It records the Swift toolchain revision, architecture, build configuration,
  workload name, input size, deterministic seed, iteration count, and metric
  schema.
- It writes stable JSON plus a concise human-readable summary under the owning
  package's `.build` directory.
- It exits nonzero for structural, allocation, copy, leak, or correctness budget
  failures. Timing regressions are reported separately until a reliable
  environment-normalized policy is established.

Do not add a generic benchmark framework dependency when a focused executable
and `ContinuousClock` measurements cover these workloads.

### Publication workloads

Measure:

- Initial publication of 1K and 10K retained semantic nodes.
- Completely clean republication.
- One dirty leaf at shallow and deep positions.
- Reparenting and reorder without content replacement.
- Paint-content change with and without registration reuse.
- Animated mutation acceptance and terminal completion.

Record semantic nodes visited, layers staged, topology mutations, bytes encoded,
paint registrations, allocations, copied bytes, and elapsed distribution.

### Text and collection workloads

Measure:

- Large multiline document initial layout.
- Local edits near the start, middle, and end.
- Width/scale/backend invalidation.
- Long-document viewport scrolling with paragraph reuse.
- List/grid initial materialization and continuous scrolling.
- Snapshot insertion, removal, move, filtering, selection preservation, and
  reorder.
- Variable measurement with localized revision changes.

Record layout creations, reused paragraphs, materialized views/layers,
measurements, cache occupancy/evictions, reuse-pool occupancy, copied text bytes,
allocations, and elapsed distribution.

### Resource and host-projection workloads

Measure:

- Duplicate async image request coalescing.
- Decode/register/apply lifecycle across cache hit, miss, failure, expiry, and
  cancellation.
- Large AT-SPI tree initial export and one-node incremental updates using the
  in-process model/codec path.
- RN mount bursts, update-only transactions, deletion, and retirement.
- Observation fan-out, dependency replacement, coalescing, and cancellation.

Record cache entries/bytes, decode jobs, registrations, emitted objects/events,
mount payloads, observation tokens, tasks, allocations, copies, and elapsed
distribution.

### Render-model workloads

Measure without a physical presentation backend:

- Render transaction validation and apply for large trees.
- Retained-tree snapshot and clean-demand checks.
- Frame-plan construction for large layer trees.
- Damage projection and region simplification.
- Snapshot/resource reference changes and retirement-ledger processing.
- Presentation completion matching for large animation batches.

Record layers walked, damage rectangles before/after simplification, allocations,
copied payload bytes, completion records, resource operations, and elapsed
distribution.

### Budget policy

- Store structural limits next to each workload and explain why they are
  independent of machine speed.
- Treat zero-work expectations, bounded caches, maximum allocations, maximum
  copied bytes, and retained-resource baselines as hard failures.
- Report median, tail, and total elapsed measurements, but do not fail solely on
  wall-clock time until repeated evidence establishes a stable normalized bound.
- Compare like-for-like toolchain, architecture, build configuration, and input
  schema only.
- When a metric regresses, reduce the workload to the smallest reproducer and use
  existing Tracy/profile tooling only after the structural/allocation source is
  known.

### Phase 6 behavioral gate

- Every benchmark validates its semantic result before recording performance.
- Two runs with the same seed produce identical structural, allocation, copy,
  cache, and resource metrics.
- Clean publication, unchanged snapshots, and idle render-model checks report
  their documented zero-work results.
- Large text, collection, image, AT-SPI, RN, observation, and render-model
  workloads remain within explicit memory/resource bounds.
- Benchmark setup and teardown return every exposed counter to baseline.
- `tools/nucleus doctor`, `tools/nucleus build`, `tools/nucleus test`,
  `tools/nucleus api`, the sanitizer command, and
  `tools/nucleus benchmark` all pass without launching a UI host.

## Final acceptance criteria

This hardening plan is complete when:

- No mutable glyph, retained-tree, render-resource, or production host-bundle
  authority is discovered through a process-global singleton or installation
  variable.
- Every host constructs, passes, and tears down one explicit runtime graph.
- Two runtime graphs are behaviorally and resource-lifetime isolated in one
  process.
- AT-SPI, render orchestration, input dispatch, and XDG protocol code have focused
  implementation boundaries while retaining one owner each.
- The unqualified workspace test command covers every debug package suite, all
  six release structural suites, required release archive provisioning, and
  public API extraction.
- First-party builds are warning-clean.
- ASan/LSan, UBSan, TSan, deterministic fault injection, and bounded fuzz/property
  harnesses report no first-party ownership, concurrency, or undefined-behavior
  failures.
- Portable semantic tests use manually advanced monotonic time rather than
  wall-clock sleeps.
- Headless benchmarks publish deterministic structural, allocation, copy, cache,
  resource, and timing evidence for the core hot paths.
- All automated work completes without compositor/shell launch or physical
  hardware validation.
