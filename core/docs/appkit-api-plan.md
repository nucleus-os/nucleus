# AppKit API Plan

## State invariant

Across every phase boundary the following must hold:

1. **NucleusUI is the front door.** A client authors against `NucleusUI` alone.
   `NucleusLayers` is not re-exported and is not a client dependency — through the public API
   *or* any privileged one.
2. **Privilege is a module boundary, not an annotation.** What a client may reach is decided by
   what it names in `Package.swift`, which the build graph enforces and a reader can review.
   `@_spi` marks API that is *unstable*, never API that is *privileged*; it grants all-or-nothing
   access per group and any client can simply write the import.
3. **NucleusUI is GPU-free to test.** `Application.defaultContext` uses
   `InMemoryCommitSink`; `installStubHost()` supplies stub registrars. Every phase is
   unit-testable with no compositor and no GPU.
4. **`throws` marks an actionable runtime failure, never ceremony and never control flow.**
   Host-contract violations are preconditions.
5. **One representation per concept.** No parallel command vocabularies, no duplicated
   lowering switches, no compatibility shims for a replaced API.
6. **`Float` at the paint-command boundary, `Double` on the geometry plane.**

## Context

Nucleus's product thesis is an AppKit-like Swift API for native desktop UI. `NucleusUI`
has AppKit's *shape* — `open class View: Responder`, `Window`/`WindowScene`, `Control`,
eager property setters, `setNeedsLayout`/`setNeedsDisplay`, `hitTest`, a
`CATransaction`-shaped `Transaction` — but not AppKit's *extension points*. It was built
to satisfy the clients it has, and it fits them exactly.

The forcing function is Noctalia, a shipping 339k-LOC C++ Wayland shell that already links
the Nucleus render SDK, shares the Clang/libc++ ABI contract, uses Nucleus SkParagraph for
text, and renders Vulkan 1.4/Graphite. Its `src/ui` is *already* AppKit-shaped — retained
class tree, imperative construction, measure/arrange, hit testing, dirty propagation — with
~40 controls proven in production. It is the best available behavioral specification for what
this API must contain; the native Swift shell port is the production acceptance client that
proves whether the API is real.

The first production consumer is a native Swift port of Noctalia built directly with these
APIs. React Native is not the target view hierarchy for that port and is not on its completion
path. The existing RN runtime remains a build client and integration fixture; Phase 6 keeps it
coherent when the old paint vocabulary is deleted. Any later migration of selected native
shell surfaces to React Native is a separate post-parity decision made against the completed
Swift product.

The port grows inside the existing `shell/` SwiftPM package; it is not a new package. Phase 5
creates a `NucleusShellProduct` target for native views, controllers, and product composition.
That target imports public `NucleusUI` and app-facing shell models, but not `NucleusLayers`,
`NucleusRenderer`, or React Native. `NucleusShellRuntime` remains the privileged Wayland/render
host, and the `NucleusShell` executable remains a thin bootstrap. This module boundary is what
“out-of-module” means below: the production client lives outside package `Nucleus`, even though
both packages remain in one workspace.

The gap is not "missing controls". Controls are the cheap, well-specified part. Four
structural blockers:

1. **Extensibility is closed.** `View.draw(_ dirtyRect:)` is `open` but returns `Void` with
   no canvas — a no-op hook. The real entry, `displayCommands(in:)` (`View.swift:409`), is
   `package`, and `Nucleus`/`NucleusReactNative`/`NucleusShell` are three separate SwiftPM
   packages with no `-package-name` set, so `package` means "core only".
2. **Five renderable primitives** (`rect`, `roundedRect`, `image`, `line`, `textLayout`).
   Noctalia needs 13 node types plus 15 SkSL runtime-effect assets.
3. **Three event types** (`action`, `pointerDown`, `pointerUp`). No keyboard at all.
4. **Single-pass `StackView`.** No measure/arrange, no flex.

### Three findings that shape the plan

**The renderer is far ahead of the API.** `nucleus::skia::Canvas` already has
`drawShaderRect`, and `makeRuntimeShader(sksl, uniforms, count)` already compiles SkSL —
`Backdrop.swift:58` uses it for vibrancy. `Paint` already carries
`blend`/`blurSigma`/`saturation`, but `drawPaintCommand` sets **only** `paint.color`. The
capability exists; the wire cannot express it.

> **Resolved in Phases 2–5.** The POD carries the full style set, `drawPaintCommand`
> populates all of it, and paths, gradients, strokes, and compiled SkSL are reachable,
> pixel-tested, and now *emitted* — `GraphicsContext` is the authoring surface and
> `NucleusShellProduct` is the client using it.

**The leak is already visible.** `NucleusReactRuntimeCxx` is the real out-of-module
content-emitting client, and it cannot override `displayCommands`, so
`ReactLayerContentCommitter.swift` reaches around the pipeline via `@_spi backingLayer` +
raw `NucleusLayers.PaintContent`, duplicating `ViewLayerPublisher`'s lowering including a
copied `paintKind` switch (`:58`). It exists *only* because `displayCommands` is `package`.
Retiring that duplication is Phase 6's repository-coherence gate. The drawing work is accepted
by the native `NucleusShellProduct` client authoring and rendering real shell views through the
public API.

> **Traced before Phase 2; the framing was incomplete.** RN does not use
> `ViewLayerPublisher` at all — it builds its own layer tree and registers paint per
> component. The committer duplicated *lowering* (deleted in Phase 5, when RN moved onto the
> shared seam) and carries RN's only *paint-registration* path (now `PaintRegistration`).
> What is left for Phase 6 is the mount-architecture change, not the duplication.

**The paint path has never had a client that could catch its bugs.** Two verified latent
defects, both unobservable today for the same reason:
- `StackView`'s arranged subviews are **unhittable**. `layout()` positions children at
  `bounds.origin.x + margins.left` (parent space, `:201`); `hitTest` converts to child-local
  by subtracting the frame origin (`:441`). Click `(15,25)` with
  `stack.frame = (10,20,200,300)`: `localPoint = (5,5)` → child frame starts at `x:10` →
  `5 < 10` → nil. Every other `layout()` in the tree places children at `x: 0`
  (`ShellOverlayMenuView.swift:253, :334`), using only `bounds.size`. `StackView` is the only
  code in the tree that consumes `bounds.origin`, and it is simply wrong.
- **Borders render as fills.** `styleCommands` (`ViewStyle.swift:66`) emits `strokeWidth`;
  `drawPaintCommand` never sets `paint.style`, and Skia defaults to fill. Zero production
  blast radius — `Border` is set only in `ViewTests.swift:124, :532`, which assert the
  *command*, never pixels.

  > **Closed end to end.** Phase 3 made the rasterizer honor a stroke request; Phase 5's
  > `ViewStyle.draw(in:bounds:)` requests it. Guarded by a command-level assertion that the
  > border carries `.stroke` while the background does not, and by pixel tests on the
  > stroked rounded rect — including a negative one proving a stroke *width* alone does not
  > stroke.

Neither is caught because the overlay does its own hit testing and never sets a border. That
is the thesis of this work: the API is untested because it has no demanding client.

The compositor overlay overrides `layout()` six times and nothing else — no `draw`, no
`displayCommands`, no command construction. Making `displayCommands` public is a
**zero-source-change** for it. It proves the *publication* API (Phase 7), not drawing.

Phases 2–4 are deliberate pipeline groundwork: they make the renderer capability complete and
headless-testable before the authoring client arrives. Starting with Phase 5, each restructuring
lands with a concrete deletion and each newly exposed capability lands with a real native client
and behavioral coverage. No surface added from Phase 5 onward remains half-wired or justified
only by a hypothetical future client.

---

## Status

| Phase | | |
|---|---|---|
| 0 | Render-SDK link contract | **complete** |
| 1 | The error contract | **complete** |
| 2 | Widen the paint POD, delete the wire fiction | **complete** |
| 3 | Skia facade and rasterizer | **complete** |
| 4 | RuntimeEffectRegistrar | **complete** |
| 5 | GraphicsContext and the vocabulary collapse | **complete** |
| 6 | Retire the RN committer | **complete** |
| 7 | Publication, and privilege as a module boundary | pending |
| 8 | Event vocabulary and responder wiring | pending |
| 9 | Layout: measure/arrange and flex | pending |
| 10 | TextField and input-method foundation | pending |
| 11 | ScrollView, the interaction capstone | pending |
| 12 | TextView and multiline editing | pending |

### Where this stands

Phases 0–5 built the pipeline and the API on top of it. Drawing is now reachable by a client:
`NucleusShellProduct` in `shell/` authors real shell chrome — paths, arcs, gradients, strokes,
caps — against public `NucleusUI` alone, and its tests are the out-of-package authoring proof.

Both carry-forward constraints are discharged, and Phase 6 closed the last of the parallel paint
path: React Native authors through `draw(in:)` like any other client. Borders stroke end to end.

The remaining phases are additive rather than structural: publication (7), input (8), layout (9),
and then the text/scroll/editing stack (10–12). Each lands with a real native client, per the
principle above. Phase 7 is the pivot — after it, the port grows inside `NucleusShellProduct`
and later phases are driven by what it actually needs.

## Phase 0 — Render-SDK link contract — complete

Unplanned prerequisite. `swift build` succeeded for `core` but every executable and test
target that links the full Skia closure died at `Ld` with `unable to find library
-lallocator_base` (plus `allocator_core`, `allocator_shim`, `raw_ptr`), which blocked all
compositor tests and therefore Phase 1's acceptance gate.

Root cause: `BuildSkia.swift` sets `skia_use_partition_alloc=false` because CEF-enabled hosts
install no process-wide allocator shim, so GN correctly stops emitting those four archives.
The matching `-l` line was removed from `core/Package.swift` but not from the four packages
that carry a byte-identical link line.

- Removed the stale allocator link flags from `react-native/Package.swift`,
  `compositor/compositor/Package.swift`, `compositor/compositor-core/Package.swift`, and
  `shell/Package.swift`.
- Corrected the rationale in `BuildSkia.swift`: the flag stays, but the reason is now that
  *nothing* installs a shim and the process allocates through system malloc, so Skia must
  stay neutral rather than become the only PartitionAlloc owner.

**Landed with:** the `shell` executable links; the compositor test suite runs (284 tests);
`NucleusCompositorRenderRuntimeTests` and `NucleusCompositorOverlayTests` execute for the
first time.

## Phase 1 — The error contract — complete

Signatures settle before new surface is built against them, or every later phase churns twice.

The scale of the ceremony exceeded the plan's assumption: **NucleusUI declared 85
`throws(UIError)` and contained 3 `throw` statements.** `Context.makeLayer` does not throw;
`Responder.init`'s entire body is two assignments — so `View.init() throws(UIError)` threw
nothing. The whole cascade propagated from a `NucleusLayers` module with 3 throw sites in it,
all `invalidArgument` for programmer errors.

- `View.init`, `addSubview`, `removeFromSuperview`, `setProperties`, `frame`/`bounds`
  setters, `layout()`, `draw()`, `displayCommands()`, `layoutIfNeeded()`,
  `displayIfNeeded()`, and `hitTest` are non-throwing.
- `throws` retained only where a commit can genuinely fail — everything routing through
  `CommitSink.commit(_:) throws(LayerError)`: `Transaction.commit`/`run`/`animate`,
  `ViewLayerPublisher.publish`, `WindowScene.publish` and `ensureRootAttached`,
  `HostedSurface.detach`, and `StackView`'s arranged-subview transition machinery.
- **Typed throws was control flow.** `Responder.performAction` threw `.notImplemented` when
  no handler was registered and `Control.sendAction` caught it to return `.notHandled`. Now
  `performAction -> Bool`, mirroring `NSApplication.sendAction(_:to:from:)`; the chain walk
  went recursive → iterative.
- **Dead error-swallowing collapsed.** `Window.syncTitlebar`/`syncTitlebarThrowing` existed
  only to drop a `VisualEffectView` allocation failure that cannot occur; the split is gone.
  Same for `HostedSurface.init`'s wrapper and four unreachable `do`/`catch` arms in
  `ShellOverlayScene`.

Results: NucleusUI **85 → 25** `throws(UIError)`; overlay **104 → 16** `try`. No construction
site throws. `shell` required zero source changes. `ActionTests` rewritten to the returned
`Bool` contract, plus new coverage for the rewritten chain walk.

**Landed with:** every `try` at an overlay construction site deleted.

## Phase 2 — Widen the paint POD, delete the wire fiction — complete

The premise held, and more strongly than the plan claimed. `nucleus_paint_command`,
`nucleus_paint_command_kind`, and `artifact_store` appear **nowhere in the tree except the
comments that reference them** — no C header, no second implementation, no generator over
`Types.swift`. `PaintCommand` is a `Span` passed between Swift modules in one process. The
"wire-stable discriminants" constraint was preserving compatibility with something that no
longer exists.

- **`PaintCommandKind` renumbered densely** (`rect` 0 … `textLayout` 4). The `0`/`3` gaps and
  `.none` are gone.
- **`PaintCommand` widened**: `reserved` deleted; `kind` is now the **stored enum** rather
  than a `_kind: UInt32` plus a `?? .none` accessor that could silently coerce a bad value.
  Added `flags` (`stroke`/`antialias`/`evenOddFill`), `blend`, `alpha`, `blurSigma`,
  `saturation`, `effectHandle`, `payloadOffset`, `payloadLength`.
- **`NucleusLayers.PaintCommand` collapsed to a typealias.** Beyond the plan as written, but
  squarely its intent: the domain struct was a field-for-field copy whose `.wireValue` was a
  pure identity map. It is now `NucleusTypes.PaintCommand` itself — the same treatment `Color`
  and `PaintCommandKind` already had in that exact file. The identity bridge is deleted and
  `withWireCommands` maps nothing, so the widened fields were added once instead of twice.
  This removes one of the four near-identical structs Phase 5 was scheduled to collapse.
- **The silent-drop policy is gone.** `paintDrawCommandKind(_:) -> PaintDrawCommandKind?` is
  deleted. Translation is two exhaustive switches with no `default`, so an added kind or
  blend mode is a compile error at every site that must learn it.
- **`PaintDrawCommand` widened to match**, and its hand-written `==` — hand-written only
  because `Float4` is a tuple — now covers **every** stored property. This is the
  re-registration gate; a field omitted there makes two visually different commands compare
  equal and silently drops the repaint.
- `PaintDrawBlendMode` is duplicated into `NucleusRenderModel` rather than imported, because
  that module deliberately resolves no dependencies (`core/Package.swift:244-247`) — the same
  posture `PaintDrawCommandKind` already had toward `PaintCommandKind`.

**Phase 1 residue swept.** Phase 1 verified only NucleusUI and the overlay; `NucleusApp`,
`react-native`, `shell`, and the test targets were never rebuilt against the new signatures.
Cleared 2 warnings in `NucleusApp/WindowGroup.swift`, 7 in `NucleusReactRuntimeCxx`
(including a `do`/`catch` around `addSubview` that had been swallowing an error and was by
then unreachable), 1 in `NucleusShellRuntime/ShellHost.swift`, and 219 across the NucleusUI
test targets.

`RenderPaintContentTests`' discriminant-mapping assertions were deleted — they pinned the
exact fiction being removed. Replaced with two behavioral tests: one varying every field of
`PaintDrawCommand` in turn to prove each participates in equality, and one pinning that
commands differing only in payload slice are unequal.

**Landed with:** the silent-drop `guard let … else { continue }` deleted, plus the
`NucleusLayers.PaintCommand` duplicate and its identity bridge. Nothing new is drawable;
every existing draw still works.

## Phase 3 — Skia facade and rasterizer — complete

Added to `Graphite.hpp`/`Graphite.cpp`:

- **`class Path`** (Impl-holding facade, the existing `Shader` pattern), built POD-in via
  `makePath(verbs, verbCount, points, pointCount, evenOdd)`. A verb array that runs past the
  supplied points returns an invalid path rather than partial geometry — a malformed encoding
  fails visibly instead of rendering wrong.
- `Canvas::drawPath`, `clipPath`, `drawPathWithShader`, and `concat(const float m[9])`.
- **No `drawArc`.** `arcTo` is a path verb consuming the oval rect plus start/sweep angles, so
  a spinner or countdown ring is a stroked path — one primitive, one switch case.
- **`Paint` gained** `style`, `strokeWidth`, `strokeCap`, `strokeJoin`, `miter`. This is the
  fix for borders-render-as-fills.
- **Gradients as `Shader` factories** — `makeLinearGradient`, `makeRadialGradient`,
  `makeSweepGradient`. Note this Skia carries the newer `SkGradient`/`SkShaders::` API, not
  `SkGradientShader`; the factories build an `SkGradient::Colors` span. `makeSweepGradient`
  rejects an inverted angle range up front, because `SkShaders::SweepGradient` returns null
  there and would otherwise surface as a silently missing draw.

**`TextureProducer` now populates the whole paint.** `drawPaintCommand` set only
`paint.color`; it now carries alpha, blend, blur, saturation, antialias, stroke style, and
stroke width. Everything Phase 2 widened is consumed here — the capability existed in the
rasterizer all along and was being dropped at the last step.

**`makeRasterSurface` added, beyond the plan as written.** `makeOffscreenSurface` hangs off
the Graphite context and so needs a GPU; without a CPU raster target none of this drawing
work could be pixel-tested at all, which would have broken the GPU-free-to-test invariant
exactly where it matters most. `Surface::readPixelsRGBA` reads it back, mirroring
`Image::readPixelsRGBA`.

**Landed with:** `lineRect` deleted. `.line` synthesized an axis-aligned rect sized to the
stroke width and could express neither a diagonal nor a cap nor a join; it is now a real
stroked two-point path.

11 pixel tests in `NucleusSkiaGraphiteTests`, run headless against the full static Skia
archive set. The load-bearing one is `strokedPathLeavesItsInteriorUnpainted`: it asserts the
edge *is* painted and the interior is *not*, so it cannot pass by reading back an empty
buffer, and it fails if `style` ever defaults back to fill. That is new coverage — nothing in
the tree had ever rendered a border.

## Phase 4 — RuntimeEffectRegistrar — complete

**The plan's approach did not work, and the reason is structural.** It called for
compile-on-first-use "via `makeRuntimeShader`", but that call compiles the SkSL *and* binds
uniforms in one step, returning a `Shader`. Uniforms ride the per-frame payload blob and
change every frame; the program does not. Routing through `makeRuntimeShader` would have
recompiled every SkSL program on every draw — precisely the cost the registrar exists to
avoid — while looking like it was caching.

So the facade gained a compile/bind split first:

- **`class RuntimeEffect`** wrapping `sk_sp<SkRuntimeEffect>`, built by
  `makeRuntimeEffect(sksl)`, vending `makeShader(uniforms, count)` and
  `makeShaderWithImage(...)`.
- `makeRuntimeShader` and `makeRuntimeShaderWithImage` are retained for `Backdrop.swift`
  (which holds no handle) but are now expressed through the split, so there is one code path.

On that foundation, mirroring the image pipeline exactly:

- **`RuntimeEffectStore`** in `NucleusRenderModel`, holding SkSL *source* — not a compiled
  object — so registration stays GPU-independent and works headless, the same posture
  `ImageStore` has. Deduped by source: the shell's effect set is small and fixed but
  registered repeatedly as views come and go, so identical programs must share one handle.
- `RuntimeEffectRegistrar` / `RuntimeEffectLifecycle` in `NucleusAppHostProtocols`, their
  `Swift…` conformers in `NucleusAppHostBundle`, and slots in `Host`, `LifecycleHost`,
  `NucleusAppHostBundle`, and `installStubHost()`.
- **`RuntimeEffect`** in `NucleusLayers` — a refcounted handle mirroring `PaintContent`.
- `FrameDriver.compiledEffects`, a compiled-program cache keyed by handle, evicted through
  `RuntimeEffectStore.onEvict` exactly as `decodedImages` is evicted through
  `ImageStore.onEvict`. Handles are monotonic and never reused, so without eviction a
  compiled program would persist until shutdown.

9 tests: 4 on the store (dedupe bumping the refcount, eviction firing once on the last
release, no handle reuse after eviction) and 5 headless facade tests (one compiled program
binding two different uniform sets, invalid SkSL rejected, mismatched uniform size rejected
rather than binding garbage, and an effect painting through `drawPathWithShader`).

## Phase 5 — GraphicsContext and the vocabulary collapse — complete

**A prerequisite surfaced first: the payload blob had never been plumbed.** Phase 2 added
`payloadOffset`/`payloadLength` to both PODs, but `PaintContentRegistrar.register` still took
only a command span, `PaintContentStore.Content` held no bytes, and the rasterizer had nothing
to read — the offsets pointed into a blob that did not exist. Paths could not render until
that transport landed, so it went in first: the registrar, the store, `PaintContent.register`,
`LayerTransaction.setPaintCommands`, and `FrameDriver` all carry payload now.

**The format lives in `NucleusTypes.PaintPayload`.** Encoder and decoder are one file because
they are one format, and both `NucleusUI` and `NucleusRenderer` already depend on
`NucleusTypes`, so neither side can drift without that file changing. A slice is
self-describing (four region counts, then verbs/points/scalars/colors) and the decoder rejects
out-of-range slices, inconsistent region sizes, unknown verbs, and verbs that over-consume
points — a malformed payload becomes a dropped draw rather than geometry built from misread
bytes.

**Vocabulary.** `.path` replaces `.line`, which was a second way to say the same thing;
`.clipPath`/`.save`/`.restore` were added because a clip is canvas state that must be replayed
and cannot be baked into geometry the way a transform can. `PaintCommand` gained `shading`.

**API.** `GraphicsContext` is a `@MainActor final class`, wholly non-throwing, with the
CoreGraphics-shaped surface the plan specified. A public `Path` value type mirrors `CGPath`,
including an implicit `move` so a stray `addLine` cannot emit points no verb consumes. A new
`AffineTransform` is applied to geometry *as it is recorded*, so commands carry no matrix.
`Shading` makes the SkSL escape hatch a peer of the gradients.

**The recording mints nothing, which resolves the phase's flagged hardest risk.** The plan
warned that `makeTextLayoutHandle` falls back to minting a fresh transient handle, so arrays
containing text never compare equal and the view re-registers on every publish. Rather than
work around it, `PaintRecording.textLayouts` holds the layouts and `textLayoutHandle` carries a
**one-based index into that array** while recording; `PaintRegistration` resolves indices to
registry handles at registration time and releases transients when the returned value dies. Two
recordings of the same text are therefore equal, and the diff suppresses the re-registration.
`Label`'s layout cache no longer papers over anything.

**The shared seam.** `PaintRegistration.register(_:width:height:in:)` performs the one lowering,
registers the content, and returns an owning `RegisteredPaint` carrying the
`LayerPropertyUpdate` and holding content plus transient text handles alive until the caller has
applied it. It has no tree walk and no backing-layer dependency. `ViewLayerPublisher.publishPaint`
now delegates to it, and it is host-facing SPI — `NucleusShellProduct` sees `GraphicsContext` and
never a recording, layer, registrar, or commit sink.

**Deletions.** `draw(_ dirtyRect:)`, `displayCommands(in:)`, `LayerContentBuilder`,
`ViewLayerContentCommand`, `LayerContentCommandKind`, `layerPaintCommand`, `layerPaintKind`,
`TextLayout.layerContentCommands`, `dirtyDisplayRects`, and the whole verified-dead backdrop
path — `reconcileBackdrop`, `ensureBackdrop`, `ensureContentLayer`, `usesBackdropLayer`, and the
`contentLayer`/`contentFrame` cache fields that could then never be non-nil. `styleCommands`
became `ViewStyle.draw(in:bounds:)`. A tree-wide grep confirms none of these names survives.

**Borders stroke.** `ViewStyle.draw` now sets the stroke flag, closing the emitting half of the
defect Phase 3 half-fixed. **This defect is now closed end to end.**

**React Native moved onto the seam in this phase, not Phase 6.** Phase 5 deletes the vocabulary
RN was using, and every phase must land green, so the committer now calls `PaintRegistration`
and `ReactParagraphView` records through a `GraphicsContext`. That deletes the duplicated
lowering, the duplicated `paintKind` switch, and the transient-handle minting. What remains for
Phase 6 is the mount-architecture work it actually describes: collapsing `ReactParagraphView`
and its sibling plain `View` into one `View` subclass overriding `draw(in:)`, and deleting the
committer file.

**The production client.** `NucleusShellProduct` was added to `shell/` depending on `NucleusUI`
alone — the dependency list *is* the boundary being proven. Its first view, `StatusPillView`,
draws a rounded pill with gradient or flat fill, a hairline outline, and a dot or swept-arc
progress ring: real shell chrome, exercising paths, arcs, gradients, strokes, and caps through
the public API only.

**Verification.** All five packages build with zero warnings attributable to the phase; 164 core
tests, 284 compositor tests, and 7 out-of-package shell-product tests pass. New coverage:
10 payload-codec tests (round trip, append-does-not-move-earlier-slices, and every rejection
path), 6 registration tests, and 2 stroked-rounded-rect pixel tests. The registration tests pin
what nothing previously could — that an unchanged view and, critically, unchanged *text* do not
re-register, while a changed drawing does; they assert the first publish *does* register, so
they cannot pass by never registering at all.

## Phase 6 — Retire the RN committer — complete

Repository coherence, not a commitment to build the native shell in React Native. New shell
product UI remains native Swift.

Phase 5 had already deleted the duplicated lowering and moved RN onto `PaintRegistration`, so
what remained was the mount-architecture change:

- **`ReactParagraphView` is a real `View` subclass** overriding `draw(in:)` and
  `intrinsicContentSize`. It was a standalone text holder living *beside* a plain `View`, which
  is what a component looks like when the framework gives it no way to author content.
  `ReactParagraphComponentView` now holds one object and passes it as its own `view`.
- **`ReactLayerContentCommitter.swift` is deleted.** Its remaining step — binding a recording's
  update to RN's own layer — became a default implementation on the `ReactComponentView`
  protocol, so `ReactBaseComponentView` and `ReactImageComponentView` share one path instead of
  carrying a copy each. It lives in `ReactLayerBinding.swift` because `NucleusLayers` and
  `NucleusUI` both define a `Rect` and the mount consumer works in the NucleusUI one.

RN now authors through `draw(in:)` like any other client, and the only RN-specific step left is
layer binding — which exists because RN builds its own layer tree, not because it reaches around
the framework.

**Graphics-state hardening landed alongside.** `GraphicsContext.recording` now closes off any
unbalanced `saveGState`. A `draw(in:)` override that saves and returns early would otherwise
leave the rasterizer's canvas saved, and a clip set after it would leak forward through the rest
of that view's recording. Blast radius was one view's own texture, but Phase 11's ScrollView
leans on clipping, so the recording should be self-balancing before anything depends on it.
`withGraphicsState {}` remains the form that cannot unbalance.

**Landed with:** the committer file deleted and the last `appendAmbient`/`backingLayer` use
confined to one shared binding step; 5 graphics-state tests; all suites green.

## Phase 7 — Publication, and privilege as a module boundary

`NucleusShellProduct` becomes a hosted, publishable NucleusUI application. The reason this is
one phase rather than two is that "what a product may reach" and "how that limit is enforced"
are the same decision, and the current answer to the second half does not hold.

**The enforcement mechanism is wrong today.** `NucleusUI` carries 47 `@_spi` declarations under
a single group, `NucleusCompositor`, consumed by three different clients — the compositor
overlay, the shell runtime, and the React Native runtime. Two of those are not the compositor.
Three consequences follow:

1. **SPI is all-or-nothing per group.** React Native needs `PaintRegistration`,
   `layerContent.recording`, and `backingLayer`; the import that grants those grants all 47,
   including `CommitSink`, `Layer`, `WindowScenePublicationContext`, and the hosted-surface
   registry. Partial access is not expressible.
2. **`NucleusUI` re-exports `Layer` and `CommitSink` as SPI typealiases.** State invariant 1 —
   `NucleusLayers` is not re-exported and is not a client dependency — holds for the public API
   and silently does not for the privileged one.
3. **SPI is a speed bump, not enforcement.** Any client can write the import. A module boundary
   is enforced by the build graph and is reviewable in `Package.swift`. Phase 5 proved this in
   this repository: `NucleusShellProduct`'s dependency list *is* the boundary being proven, and
   it held. The same boundary drawn with SPI would have proven nothing.

The cost is not hypothetical. Phase 5 widened SPI to make the shell-product tests compile; those
tests then asserted on command counts rather than pixels, which is why they passed over an arc
bug that rendered every dot indicator as nothing. Privileged access handed to product tests
produced the appearance of coverage.

**Three tiers, expressed as modules.**

- **Product API** — `NucleusUI`, `NucleusApp`. Application authors, including the shell port.
  Ends this phase with **zero `@_spi` declarations**. Everything public here is intended for
  product code, and `NucleusLayers` types appear in no signature.
- **Embedder API** — a new `NucleusUIEmbedder` product. Code that embeds a NucleusUI scene into
  a platform and feeds it a surface, input, and a frame clock: the compositor, the shell
  runtime, the React Native runtime. Plain `public`. It lives inside the `Nucleus` package, so
  it reaches `NucleusUI`'s internals through **`package` access**, which core already configures
  (`-package-name core`) and which is precisely what that feature exists for. It vends scene
  publication, paint registration, and render-context installation.
- **SDK internals** — `NucleusLayers`, `NucleusRenderer`, `NucleusAppHostBundle`. Reachable from
  the embedder tier and the render stack; never named in a product-tier signature.

"Embedder" is the term of art for this role (Flutter, V8) and names the relationship precisely.
It also avoids a collision: `NucleusAppHostProtocols`/`NucleusAppHostBundle` are the *resource
provision* seam — registrars the host process supplies **downward** to the render stack — while
this tier is scene control **into** NucleusUI. `NucleusUIHost` sitting beside `NucleusAppHostBundle`
would need explaining every time. Those existing names are defensible and are not renamed here;
if they are ever touched for another reason, `NucleusRenderResources` describes them better.

`@_spi` is then reserved for what it is actually good at: API intended to ship but not yet
committed to as stable. Not privileged — *unstable*.

**The compositor overlay is two things, and splits along a line that already exists.**
Measured: `ShellOverlayScene.swift` holds 29 of the overlay's 31 privileged uses in 719 lines;
the menu, notification, hotkey, controller, and shadow files hold **zero** across 1,059 lines,
while importing SPI anyway. That is the speed-bump argument proving itself in this repository —
the import is free, so it was applied blanket-wise and nobody noticed. The UI files become an
ordinary product-tier target; the scene becomes the compositor's embedder, exactly as Phase 5
split `NucleusShellProduct` from `NucleusShellRuntime`.

**Hosted surfaces are compositor vocabulary and leave `NucleusUI`.** `HostedSurface` has exactly
one consumer — the overlay. Neither the shell runtime nor React Native uses it. It describes a
Wayland client's surface placed inside the compositor's scene, and it lives in the universal UI
framework only because the publication code happened to.

Publication does not need the concept. `publish(hostedSurfaces:)` consumes exactly `level`,
`id`, `rootLayerID`, and `visible` from each entry: it sorts by `(level, sequence)`, interleaves
with windows, and assigns `orderIndex`. So publication takes a generic placement record —
a foreign layer root to interleave with the scene's windows by level:

```
ScenePlacement { id, rootLayerID, level, visible }
```

and `HostedSurface` — `rootView`, `role`, `frame`, `commitsFrameUpdates`, `detach()`, and its
registry — moves wholesale into the compositor package, which maps its surfaces to
`ScenePlacement` values when publishing.

The generic form is **strictly smaller**, because two members are already dead:

- **`HostedVisualContent.role`** is written from `surface.role` and read by nothing — not by
  `publish()`, not by the compositor. It moves with `HostedSurface` and stops crossing the
  boundary at all.
- **`PublishedVisualContentKind`** (`.viewLayer` / `.hostedSurface`) is written by two factory
  methods and read by **zero production code**; its only readers are four `ViewTests`
  assertions. The discriminant exists mainly to make one interleaving test expressible, and
  that test states its intent better as an assertion on the resulting id sequence.

Both are deleted, along with `HostedVisualContent` itself. `PublishedVisualContent` keeps
`(id, rootLayerID, orderIndex, visible)`. Deleting the discriminant is safe rather than risky:
the compositor created every hosted surface and holds the registry, so if it ever needs to know
whether an id is a client surface, it already does — core telling it is a redundant
representation, and re-adding a discriminant later is cheap.

**Sequence.**

First, split the single `NucleusCompositor` group into honest names by consumer. This is
mechanical and it is a diagnostic: the resulting groupings say what the embedder tier must
contain, rather than that shape being guessed up front. Anything only one consumer needs is a
candidate for staying private to it — the overlay's five zero-privilege files should fall out
here as needing nothing at all.

Then narrow publication to `ScenePlacement`, delete `PublishedVisualContentKind` and
`HostedVisualContent`, and move `HostedSurface` and its registry into the compositor package.
Publication shrinks before it moves, so the embedder tier is built around the smaller surface
rather than inheriting the larger one.

Then stand up `NucleusUIEmbedder` and move the remaining embedder slice into it, deleting SPI
annotations as each declaration lands behind the module boundary instead:
`WindowScenePublicationContext`, `PublishedScene`, `PaintRegistration`, `PaintRecording`, and
the `Layer`/`CommitSink` typealiases. The window, scene, and view operations a product needs
become plain public `NucleusUI`.

Then split the overlay into its product and embedder halves, and repoint all three consumers at
`NucleusUIEmbedder`. No target outside the embedder tier imports `NucleusUI` with an SPI
annotation.

**Product tests test through the product API.** `NucleusShellProductTests` currently reads
recordings through SPI. Asserting on a recording is a hosting concern; a product test should
observe rendered output or public view state. Where a product test genuinely cannot observe
something, that is a missing product-tier seam, not a reason to grant privilege.

`HostedSurface` is not the synchronized external-image path: it publishes a root layer for a
host to place and does not bind dynamic image content. `ContentKind.external` and
`IOSurfaceContent.bind(id:)` are sufficient only after a resource is safely registered under
that identity. CEF's rotating DMA-BUF frames additionally require producer waits, exact frame
identity, queue-family/layout ownership, Graphite completion, and consumer release. That
specialized render-host contract belongs to the shell migration's CEF phase, not this generic
publication API.

Files: new `core/swift/Sources/NucleusUIEmbedder/`; `core/Package.swift`;
`NucleusUI/{WindowScene,WindowScenePublicationContext,HostedSurface,PublishedVisualContent,GraphicsContext,PaintRegistration,View}.swift`;
`NucleusApp/`; `shell/Package.swift`, `NucleusShellRuntime/ShellHost.swift`,
`shell/Tests/NucleusShellProductTests/`; `compositor/compositor-core/Package.swift` and a new
overlay product target alongside `NucleusCompositorOverlay/ShellOverlay/*`;
`react-native/Package.swift`, `NucleusReactRuntimeCxx/ReactLayerBinding.swift`.

**Lands with:** `NucleusShellProduct` constructing and publishing its native view hierarchy
through plain public `NucleusUI`, with no SPI import anywhere in the shell product target or its
tests; no `@_spi` declaration left in `NucleusUI`; `HostedSurface`, `HostedVisualContent`, and
`PublishedVisualContentKind` gone from core; and raw layer, commit-sink, and registration access
reachable only by targets that name `NucleusUIEmbedder` in `Package.swift`.

## Phase 8 — Event vocabulary and responder wiring

The narrow waist is `Action.swift` — 29 lines. Everything above it is already AppKit-shaped
and everything below it is built but unreachable.

`WireEventKind` (`compositor-core/Sources/NucleusCompositorServerTypes/ServerTypes.swift:16`)
is NSEvent in all but name — 24 cases including `leftMouseDown`, `mouseMoved`, `keyDown`,
`flagsChanged`, `scrollWheel`, and touch. `WireEventRecord` (`:314`) is CGEvent-shaped
(`kind, flags, timestampNs, x, y, data0…data3`). NucleusUI discards most of it, while the
out-of-process shell needs the same normalized vocabulary from Wayland client callbacks.

`core/` deliberately resolves no compositor or shell dependency. NucleusUI defines the
platform-neutral event; compositor and shell adapters translate into it.

- `Event` becomes a tagged record carrying kind, modifier flags, location, timestamp, button,
  click count, scroll deltas, key code, characters, and touch payload as applicable.
- `EventType` grows pointer down/up/moved/dragged/entered/exited, scroll wheel, key
  down/up, flags changed, and touch events.
- Wire `firstResponder` and `isKeyWindow`. Keyboard events route key-window → first
  responder; pointer events hit-test and then traverse the responder chain.
- Add `becomeFirstResponder`, `resignFirstResponder`, `acceptsFirstResponder`, and explicit
  pointer capture.
- `Control` gains pointer-exit and drag-cancel behavior.
- Produce characters with XKB UTF-8 and compose state instead of reducing keyboard input to a
  keysym.
- Add key repeat at the NucleusUI host boundary.
- Add both adapters now: compositor wire events → NucleusUI events, and shell Wayland
  keyboard/pointer/touch callbacks → NucleusUI events.

Files: `NucleusUI/{Action,Responder,Control,Window,WindowScene}.swift`;
`NucleusCompositorOverlay/ShellOverlay/{ShellOverlayTypes,ShellOverlayScene}.swift`;
`compositor-core/.../InputXkb.swift`; `NucleusShellWayland/`; `NucleusShellRuntime/`.

**Lands with:** the overlay's raw menu-key switch, private pointer-button capture, and
left-click-only filter deleted; the native shell routes real pointer, keyboard, modifier, and
scroll input through the same responder semantics.

## Phase 9 — Layout: measure/arrange and flex

`intrinsicContentSize` takes no container width, so a `StackView` cannot ask a `Label` "how
tall at width 200?" — text wrapping cannot participate in layout. Noctalia's `Node`
measure/arrange with `LayoutConstraints` is the production reference.

- Two-phase measure/arrange: `measure(_ constraints:)` takes a proposed range, then `arrange`
  assigns final geometry. `intrinsicContentSize` is the unconstrained case.
- Add grow/shrink/basis, distribution, and cross-axis alignment to the native arrangement
  model.
- Drop `bounds.origin` from `StackView` child placement so arranged frames are child-local,
  matching `hitTest` and every correct manual layout.
- Stop `displayIfNeeded` and `layoutIfNeeded` from recursing into clean subtrees, and remove
  dirty-state mutation from the `intrinsicContentSize` getter.
- Add a layout scheduler rather than running layout incidentally during publication.
- Use `NucleusShellProduct`'s first real bar/root views as the external-client acceptance test;
  do not add shell-specific layout code to compensate for a missing general rule.

Files: `NucleusUI/{View,StackView,Geometry,ViewLayerPublisher}.swift`;
`NucleusCompositorOverlay/ShellOverlay/{ShellOverlayNotificationView,ShellOverlayHotkeyView,ShellOverlayScene}.swift`;
`shell/Sources/NucleusShellProduct/` bar and root views.

**Lands with:** the overlay's coordinate workaround and manual `layoutIfNeeded()` calls
deleted, and the native shell laying out wrapped text and flexible bar regions with only
NucleusUI constraints.

## Phase 10 — TextField and input-method foundation

Secure credential entry is required before the native shell can prove its lock-screen path,
so single-line editing lands before scrolling and multiline editing.

The text substrate already exposes glyph positions, selection rectangles, caret affinity,
grapheme boundaries, and bidi geometry. Build one editor model on it:

- UTF-8/UTF-16 mapping, selection, caret movement, affinity, deletion, insertion, password
  masking, undo grouping, and composition state.
- Native `TextField` with pointer selection, keyboard navigation, focus, caret animation,
  horizontal reveal, placeholder, and secure-entry behavior.
- A platform-neutral input-method client seam owned by NucleusUI/app-host protocols.
- Shell-side `zwp_text_input_v3` client integration: enable/disable, surrounding text, content
  type and purpose, cursor rectangle, preedit, commit, deletion, and done serials.
- Nucleus Compositor server-side `zwp_text_input_v3` binding so the same out-of-process shell
  path works there.
- Secure fields never expose credentials to logs, clipboard, persistence, accessibility
  values, or optional higher-level runtimes.

Files: new `NucleusUI/{TextEditorModel,TextField}.swift`; `NucleusUI/TextSystem.swift`;
`NucleusAppHostProtocols/`; `NucleusShellWayland/`; `NucleusShellRuntime/`;
`compositor-core/` text-input binding.

**Lands with:** the native shell lock surface accepting composed text through the Wayland
input method without a JavaScript runtime.

## Phase 11 — ScrollView, the interaction capstone

This phase fails if drawing, events, or layout are incomplete: it requires clipping from
GraphicsContext, wheel and drag input from the responder system, constrained content sizing,
pointer capture, presentation-driven animation, and damage scheduling.

- Implement viewport and document views, content size, offset, insets, clipping, and
  scroll-to-visible.
- Add wheel, touchpad, drag, fling, deceleration, rubber-band, and cancellation behavior.
- Drive motion from presentation time rather than a fixed timer.
- Define nested scrolling and responder handoff without shell-specific gesture arbitration.
- Use the native shell's first control-center page as the production acceptance client.

`AnimationKeyPath` already reserves `scrollOffsetX`/`scrollOffsetY`, so the render model
anticipates the primitive.

Files: new `NucleusUI/ScrollView.swift`; `NucleusUI/{View,Responder}.swift`;
`shell/Sources/NucleusShellProduct/` control-center panel.

## Phase 12 — TextView and multiline editing

Build multiline editing on the Phase 10 editor model and Phase 11 ScrollView rather than
creating a second text engine.

- Add `TextView` with wrapping, multiline selection, vertical caret movement, page movement,
  drag selection, autoscroll, and scroll-to-caret.
- Complete preedit and candidate geometry across wrapped bidi lines.
- Keep selection/caret geometry derived from the existing TextSystem and retain one offset
  mapping for field and view.
- Use a real native shell settings or editor surface as the acceptance client.

Files: new `NucleusUI/TextView.swift`; `NucleusUI/{TextEditorModel,TextSystem}.swift`;
`shell/Sources/NucleusShellProduct/` settings or editor surface.

---

## Verification

NucleusUI is **GPU-free by design** and that property must hold. `Application.defaultContext`
(`Application.swift:5`) uses `InMemoryCommitSink`; `installStubHost()`
(`NucleusLayers/Host.swift:199`) installs stub registrars and is needed only where paint
registration happens (`ViewTests`, `LayerTests`). Every phase is unit-testable with no
compositor and no GPU.

Tests assert **runtime behavior and contracts, never source-code shape** — no `@hasDecl`, no
"this API no longer exists" tests.

- **Phase 0** — done: all five packages build; the compositor suite runs.
- **Phase 1** — done: NucleusUI builds with zero warnings on a forced full recompile; 96
  tests in 12 suites pass; 18 overlay tests pass.
- **Phase 2** — done: all five packages build with no warnings attributable to the phase; 129
  core tests and 284 compositor tests pass. The exhaustive-switch conversion is verified by
  the compiler. Existing rendering is unchanged — the phase adds capability without emitting
  it.
- **Phase 3** — done: 11 headless pixel tests cover stroke-vs-fill, path encoding rejection,
  arc verbs, gradients, `concat`, and `clipPath`; all other suites stay green.
- **Phase 4** — done: store semantics (dedupe, refcount, eviction) and the facade
  compile/bind split are covered headless; all other suites stay green.
- **Phase 5** — done: `StatusPillView` in `shell`'s `NucleusShellProduct` target (outside
  package `Nucleus`) draws paths, arcs, gradients, and strokes through the public API; 7 tests
  there are the out-of-package authoring proof. Pixel coverage runs through `makeRasterSurface`
  on CPU raster, so it stays headless. The stroked-rounded-rect pixel tests cover the shape
  `ViewStyle` actually emits for a border, paired with a negative test proving a stroke *width*
  alone does not stroke — the style is what matters.
- **Phase 5, registration seam**: invoke `PaintRegistration` directly outside
  `ViewLayerPublisher` to prove empty-recording clearing and registered/transient-handle
  lifetime through update application. Separately count stub-registrar calls through the
  publisher: an unchanged recording must not register again, while a payload change must.
- **Phase 5, hardest risk** — resolved structurally rather than worked around. Recordings mint
  no handles: text is referenced by index and resolved at registration, so equal drawings
  compare equal. `PaintRegistrationTests` counts registrations through a counting registrar and
  pins that an unchanged view, and unchanged text specifically, re-register nothing while a
  changed drawing does.
- **Phase 6** — done: RN builds and the whole tree stays green with the committer deleted;
  graphics-state balancing is covered by 5 tests.
- **Phase 7**: `NucleusShellProduct` creates and publishes its scene through plain public
  `NucleusUI`. The mechanical gates are that `NucleusUI` contains no `@_spi` declaration, that no
  target outside the embedder tier imports `NucleusUI` with an SPI annotation, and that removing
  `NucleusUIEmbedder` from a product target's dependencies fails to build. Publication ordering
  is asserted through the resulting id sequence rather than a content-kind discriminant. Product
  tests observe rendered output or public view state rather than recordings.
- **Phase 8**: dispatch tests for key routing (key-window → first responder), scroll, pointer
  enter/exit, drag-cancel, and capture. The overlay menu behaves identically with
  `handleMenuKey` deleted, and the shell adapter routes the same event vocabulary into a
  native window.
- **Phase 9**: extend `LayoutTests.swift` with measure/arrange under constraints, flex
  distribution, and text-wrap-participates-in-layout. **Add the missing test that would have
  caught the coordinate bug: lay out a `StackView` at a non-zero origin and hit-test a point
  inside an arranged subview.** No existing test does this, which is why the bug survives.
  `LayoutTests.swift:27` (`verticalStackUsesIntrinsicSizesAndSpacing`) pins the buggy
  placement — stack at `x:10` → first child at `x:10` — and must be rewritten to expect `x:0`.
- **Phase 10**: editor-model tests cover UTF-8/UTF-16 mapping, grapheme and word movement,
  secure masking, selection, deletion, preedit replacement, and commit ordering. A shell
  client/server integration test covers text-input-v3 enable, preedit, commit, deletion, and
  done serials without exposing the secure value.
- **Phase 11**: scroll offset, clipping, wheel/drag routing, nested handoff, cancellation, and
  physics settling are headless and deterministic under a supplied presentation clock.
- **Phase 12**: multiline caret movement, wrapped bidi selection, preedit geometry,
  autoscroll, and scroll-to-caret reuse the Phase 10 editor behavior rather than duplicating
  offset logic.

**End-to-end, on hardware.** Run the native shell under niri and exercise its first bar,
lock, and panel surfaces with real pointer, keyboard, input-method, scrolling, publication,
Graphite, Vulkan, and Wayland presentation. Run the compositor overlay checks under
Nucleus Compositor for the same shared NucleusUI semantics. This is the user-owned
validation step; a goal is complete when every agent-runnable gate passes and only this
remains.

## Risks

- **The tier split is the last cheap moment (Phase 7).** Every consumer added before it is a
  consumer to repoint afterwards, and the shell port is about to become the largest one. Doing
  it after the port grows means moving a boundary that product code already depends on.

- **RN's publish path** — retired. RN authors through `draw(in:)` and registers through the
  shared seam; only layer binding remains RN-specific, because RN builds its own layer tree.
- **Text-layout handle stability** — retired. Handles are no longer minted while recording, so
  the failure mode does not exist; registration-counting coverage guards the regression.
- **Payload-offset determinism** — discharged. `PaintPayload.append` is append-only, and a test
  pins that appending a later slice does not move an earlier one.
- **Borders render as fills** — closed end to end in Phase 5. The rasterizer honors the stroke
  and `ViewStyle` requests it.
- **Rendering changed for the first time in Phase 5**, so "nothing changed" is no longer an
  available gate for any later phase. Coverage from here on has to be positive.
- **Input methods (Phase 10)**, **scroll physics (Phase 11)**, and **multiline editing
  (Phase 12)** are the phases whose substance is genuinely novel work rather than mechanical
  restructuring.
- **Zero risk to the overlay** for all drawing phases, verified: `compositor/` and `shell/`
  never reference `ViewLayerContentCommand` or `LayerContentCommandKind`.
