# AppKit API Plan

## State invariant

Across every phase boundary the following must hold:

1. **NucleusUI is the front door.** A client authors against `NucleusUI` alone.
   `NucleusLayers` is not re-exported and is not a client dependency.
2. **NucleusUI is GPU-free to test.** `Application.defaultContext` uses
   `InMemoryCommitSink`; `installStubHost()` supplies stub registrars. Every phase is
   unit-testable with no compositor and no GPU.
3. **`throws` marks an actionable runtime failure, never ceremony and never control flow.**
   Host-contract violations are preconditions.
4. **One representation per concept.** No parallel command vocabularies, no duplicated
   lowering switches, no compatibility shims for a replaced API.
5. **`Float` at the paint-command boundary, `Double` on the geometry plane.**

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
~40 controls proven in production. It is both the best available spec for what this API must
contain and the acceptance test for whether it is real.

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
`Backdrop.swift:58` uses it for vibrancy. `drawShaderRect` has **zero Swift call sites**.
`Paint` already carries `blend`/`blurSigma`/`saturation`, but `drawPaintCommand`
(`TextureProducer.swift:255`) sets **only** `paint.color`. The capability exists; the wire
cannot express it.

**The leak is already visible.** `NucleusReactRuntimeCxx` is the real out-of-module
content-emitting client, and it cannot override `displayCommands`, so
`ReactLayerContentCommitter.swift` reaches around the pipeline via `@_spi backingLayer` +
raw `NucleusLayers.PaintContent`, duplicating `ViewLayerPublisher`'s lowering including a
copied `paintKind` switch (`:58`). It exists *only* because `displayCommands` is `package`.
Retiring it is the acceptance test for the drawing work.

**The paint path has never had a client that could catch its bugs.** Two verified latent
defects, both unobservable today for the same reason:
- `StackView`'s arranged subviews are **unhittable**. `layout()` positions children at
  `bounds.origin.x + margins.left` (parent space, `:201`); `hitTest` converts to child-local
  by subtracting the frame origin (`:441`). Click `(15,25)` with
  `stack.frame = (10,20,200,300)`: `localPoint = (5,5)` → child frame starts at `x:10` →
  `5 < 10` → nil. Every other `layout()` in the tree places children at `x: 0`
  (`ShellOverlayMenuView.swift:253, :334`), using only `bounds.size`. `StackView` is the only
  code in the tree that consumes `bounds.origin`, and it is simply wrong.
- **Borders render as fills.** `styleCommands` (`ViewStyle.swift:58`) emits `strokeWidth`;
  `drawPaintCommand` never sets `paint.style`, and Skia defaults to fill. Zero production
  blast radius — `Border` is set only in `ViewTests.swift:124, :532`, which assert the
  *command*, never pixels.

Neither is caught because the overlay does its own hit testing and never sets a border. That
is the thesis of this work: the API is untested because it has no demanding client.

The compositor overlay overrides `layout()` six times and nothing else — no `draw`, no
`displayCommands`, no command construction. Making `displayCommands` public is a
**zero-source-change** for it. It proves the *publication* API (Phase 11), not drawing.

Each phase lands with a concrete deletion as its proof, so nothing is ever half-wired.

---

## Status

| Phase | | |
|---|---|---|
| 0 | Render-SDK link contract | **complete** |
| 1 | The error contract | **complete** |
| 2 | Widen the paint POD, delete the wire fiction | pending |
| 3 | Skia facade and rasterizer | pending |
| 4 | RuntimeEffectRegistrar | pending |
| 5 | GraphicsContext and the vocabulary collapse | pending |
| 6 | Retire the RN committer | pending |
| 7 | Event vocabulary and responder wiring | pending |
| 8 | Layout: measure/arrange and flex | pending |
| 9 | ScrollView, the capstone | pending |
| 10 | IME and text editing | pending |
| 11 | Publication and hosted-surface de-SPI | pending |

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

## Phase 2 — Widen the paint POD, delete the wire fiction

There is no wire. `NucleusTypes/Types.swift` is hand-maintained with no IDL or codegen;
`PaintCommand` is passed as a `Span` between Swift modules **in the same process**. No
serialization, no versioning, no second implementation. "Wire-stable discriminants"
(`RenderPaintContent.swift:13`) describes an ABI that was never load-bearing.

- **Widen `NucleusTypes.PaintCommand`**: drop `reserved`; add `payloadOffset: UInt32`,
  `payloadLength: UInt32`, `effectHandle: UInt64`, `_blend: UInt32`, `_flags: UInt32`
  (fill/stroke, antialias, even-odd), `alpha`, `blurSigma`, `saturation: Float`.
- **Renumber `PaintCommandKind` densely.** Delete the `0`/`3` gaps and `.none`.
- **Delete the silent-drop policy.** `paintDrawCommandKind(_:) -> PaintDrawCommandKind?`
  returning nil and `continue`-ing (`SwiftResourceHostConformers.swift:54`) is
  wire-versioning for a wire that doesn't exist. In-process, an unknown discriminant is a
  programmer error currently manifesting as a silently missing draw. Make the decode an
  **exhaustive switch with no `default`**, so the compiler forces every downstream update.
  Highest-leverage change here.
- `PaintContentRegistrar.register` takes a parallel payload blob alongside the command span.
  The recorded unit is a `PaintRecording`: `(commands, payload, retained: [AnyObject])`, the
  side table keeping text layouts / images / effects alive across registration.
  `withWireCommands` (`Content.swift:196`) becomes `withWireRecording`.

**Encoding rationale — split by lifetime, not by data type.** Per-frame variable-length data
(path verbs/points, gradient stops, uniform values) rides the payload blob at
`offset+length`. Stable expensive resources (images, text layouts, SkSL programs) get handle
registrars. `ImageRegistrar` works because a path is a stable identity, decoded lazily,
shared, refcounted. A path built inside `draw(in:)` has none of those: no identity, used
once, dies with the command list — handle-minting it means thousands of retain/release
round-trips per frame. SkSL is the opposite: 15 stable assets, expensive compilation, reused
every frame, so it gets a real registrar while its *uniforms* ride the blob.

Files: `NucleusTypes/Types.swift` (`:143`, `:1012`),
`NucleusRenderModel/RenderPaintContent.swift`, `NucleusAppHostProtocols/HostProtocols.swift`,
`NucleusAppHostBundle/SwiftResourceHostConformers.swift`,
`NucleusLayers/{Content,PaintCommand,DirectBridge,Host}.swift`.

**Lands with:** the silent-drop `guard let … else { continue }` deleted. Nothing new is
drawable; every existing draw still works.

## Phase 3 — Skia facade and rasterizer

To `NucleusSkiaGraphite/cxx/include/NucleusSkiaGraphite/Graphite.hpp` + `Graphite.cpp`:

- **`class Path`** (Impl-holding facade, the existing `Shader` pattern), built POD-in:
  `Path makePath(const uint8_t* verbs, size_t, const float* points, size_t, bool evenOdd)`.
- `Canvas::drawPath(const Path&, Paint)`, `Canvas::clipPath(const Path&, bool antialias)`.
- **No `drawArc`.** Add an `arcTo` verb to the path vocabulary (`SkPath::arcTo` exists).
  Spinner and countdown ring become *a stroked path with an arc verb* — one primitive, one
  switch case, rather than a bespoke facade call and a fifth enum arm each.
- **`Paint` gains** `style` (fill/stroke), `strokeWidth`, `strokeCap`, `strokeJoin`, `miter`.
  This fixes borders-render-as-fills.
- `Canvas::concat(const float m[9])` (SkMatrix row-major). `translate`/`scale`/`rotate` are
  just concat.
- **Gradients as `Shader` factories** returning the existing `Shader` type:
  `makeLinearGradient`, `makeRadialGradient`, `makeSweepGradient`.
- `Canvas::drawPathWithShader(const Path&, const Shader&, Paint)` — unifies gradients and
  SkSL: both are "a Shader bound to a draw". `drawShaderRect` stays for its sole caller,
  `Backdrop.swift:58`.
- Blend/blur/saturation need **zero facade work** — they become reachable the moment
  `drawPaintCommand` populates them.

`TextureProducer` (already `.interoperabilityMode(.Cxx)`) decodes the payload slice and calls
`makePath`. `NucleusRenderModel` stores `payload: [UInt8]` and never interprets it, so its
zero-dependency invariant (`core/Package.swift:247`) holds by construction — the identical
posture `makeRuntimeShader` already has.

No SkPath caching initially: `producePaintCommands` only re-runs when the paint handle
changes, and the texture is already cached by `(layerId, revision)`. A speculative LRU is
complexity bought without measurement.

Files: `Graphite.hpp`, `Graphite.cpp`, `NucleusRenderer/render/TextureProducer.swift`.

**Lands with:** `lineRect` (`TextureProducer.swift:276`) deleted — `.line` exists only to
fake strokes. The renderer can now draw everything; nothing upstream emits it yet.

## Phase 4 — RuntimeEffectRegistrar

Reach the SkSL capability that already exists. Compile-on-first-use behind a handle via
`makeRuntimeShader`; a `RuntimeEffectStore` mirroring `PaintContentStore`; a `RuntimeEffect`
handle type mirroring `ImageHandle`. Lands before the API so `GraphicsContext` vends it on
day one.

Files: `NucleusAppHostProtocols/HostProtocols.swift`, `NucleusRenderModel/`,
`NucleusAppHostBundle/SwiftResourceHostConformers.swift`, `NucleusRenderer/`,
`NucleusLayers/Content.swift`.

## Phase 5 — GraphicsContext and the vocabulary collapse

Four near-identical structs exist — `ViewLayerContentCommand`, `NucleusLayers.PaintCommand`,
`NucleusTypes.PaintCommand`, `PaintDrawCommand` — with three mapping switches between them,
two duplicated across packages. That is the disease; the payload was the symptom. Collapse to
two: `NucleusTypes.PaintCommand` + payload (the registrar POD) and
`NucleusRenderModel.PaintDrawCommand` (the decoded stored form). **7 switches → 1 decode
switch.**

**API.** `GraphicsContext` is a `@MainActor final class`, non-Sendable — AppKit's
`NSGraphicsContext` is a class, and `inout struct` would tax every helper signature for
nothing.

```
open func draw(in context: GraphicsContext) throws(UIError)
```

Surface mirrors CoreGraphics: `saveGState`/`restoreGState`/`withGraphicsState {}`;
`translateBy`/`scaleBy`/`rotateBy`/`concatenate`; `beginPath`/`move(to:)`/`addLine(to:)`/
`addCurve`/`addQuadCurve`/`addArc`/`closePath`; `fillPath`/`strokePath`/`clip(to:)`;
`fillColor`/`strokeColor`/`lineWidth`/`lineCap`/`lineJoin`/`blendMode`/`alpha`;
`drawLinearGradient`/`drawRadialGradient`; and `fill(_ path: Path, with: Shading)` where
`Shading` is `.color | .linearGradient | .radialGradient | .sweepGradient |
.effect(RuntimeEffect, uniforms:)` — the SkSL escape hatch is a first-class `Shading` case. A
public `Path` value type mirrors `CGPath`.

**Deletions.** `draw(_ dirtyRect:)`, `displayCommands(in:)`, `LayerContentBuilder`,
`ViewLayerContentCommand`, `LayerContentCommandKind`, `NucleusLayers.PaintCommand`,
`layerPaintCommand`, `layerPaintKind`, `PaintCommand.wireValue`,
`TextLayout.layerContentCommands`. `styleCommands` becomes `ViewStyle.draw(in:bounds:)`,
invoked by `displayIfNeeded` *before* `draw(in:)` so style still under-paints subclass
content. Text drawing becomes `GraphicsContext.draw(_ layout: TextLayout, in: Rect)` — plain
`public`, a headline developer surface rather than SPI.

**The `@_spi`-vs-`open` collision resolves by deletion.** `ViewLayerContentCommand` ceases to
exist, so no SPI type appears at the override point. `GraphicsContext`, `Path`,
`RuntimeEffect` are plain `public`; `draw(in:)` is plain `open`. `View.layerContent` stays
`@_spi` — it is publication plumbing, not a developer surface — with `commands` retyped to
`recording`.

**`.backdrop` is verified dead — delete, don't preserve.** `VisualEffectView.swift:132` and
`ViewLayerPublisher.swift:541` both construct a **`LayerDescriptor`** (`LayerKind.backdrop`),
a different enum. Nothing anywhere constructs a `ViewLayerContentCommand` with
`kind == .backdrop`, so `reconcileBackdrop`'s scan (`:396`) never matches. Dead with it:
`ensureBackdrop`, `usesBackdropLayer` (always false), and therefore the entire
`else if usesBackdropLayer` branch at `:276` — `ensureContentLayer`, `state.contentLayer`,
`state.contentFrame` — plus both `.filter { $0.kind != .backdrop }` no-ops.

**`dirtyRect` cannot be honored, so delete it.** `PaintContent.register` registers a
whole-canvas list and `producePaintCommands` rasterizes the whole canvas into a *fresh*
texture. There is no partial-texture-update path. A subrect-only redraw would yield a texture
containing only the subrect — un-dirty pixels are gone, not preserved. AppKit's contract
preserves them; ours structurally cannot, and the proof it is already fiction is that all
four in-tree overrides ignore the parameter and rebuild from `bounds`. `dirtyDisplayRects`
and the parameter are deleted. `setNeedsDisplay(_ rect:)` keeps its AppKit signature (callers
unaffected) but the rect only marks the view dirty. Partial repaint lands when a
partial-texture-update path lands, not faked at the API.

**Migrating the four overrides.** `Label` → `context.draw(textLayout(containerWidth:), in:)`,
layout cache untouched. `Button` → the `.close` glyph's two rects become one stroked path
with a round cap. `ImageView` → `context.draw(image, in: bounds, cornerRadius:)`.
`VisualEffectView` returns `[]` today, so the override is simply **deleted** — its backdrop is
a `LayerDescriptor` concern, untouched. It is the easiest migration, not the hardest.

Files: new `NucleusUI/{GraphicsContext,Path}.swift`;
`NucleusUI/{View,ViewLayerContent,ViewStyle,ViewLayerPublisher,TextLayout,Label,Button,ImageView,VisualEffectView}.swift`.
One phase — the type deletion and the four overrides cannot compile apart.

**Lands with:** `ViewTests.swift:119`
(`semanticViewStyleFeedsLayerContentWithoutPublicDrawCommands`) rewritten against the
recording. Its stance — style paints without the subclass drawing — is preserved and still
worth pinning. The `lastDirtyRect` assertion at `:116` is deleted with the parameter.

## Phase 6 — Retire the RN committer

`ReactLayerContentCommitter.swift` deleted in full. `ReactParagraphView` becomes a real
`View` subclass overriding `draw(in:)`, publishing through the normal `ViewLayerPublisher`
path. That deletes the duplicated `paintKind` switch (`:58`), duplicated `paintCommand`
(`:41`), duplicated transient-handle minting (`:79`), the direct `PaintContent.register`, and
the `appendAmbient`/`backingLayer` SPI use — restoring the NucleusUI-is-the-front-door
invariant. This is the largest structural payoff of the drawing work and is a goal, not a
side effect.

**Gate this phase on tracing RN's actual publish path.** The committer calls
`view.displayIfNeeded()` then commits directly, which implies RN may not run
`ViewLayerPublisher` for these views. If so this is a mount-architecture change, not a
deletion. It is the one place where "delete the duplicate" may not be mechanical.

`ReactComponentViews.swift:38 displayCommands(containerWidth:)` is a plain method on a
non-View wrapper — rename to avoid confusion, otherwise untouched.

## Phase 7 — Event vocabulary and responder wiring

The narrow waist is `Action.swift` — 29 lines. Everything above it is already AppKit-shaped
and everything below it is built but unreachable.

`WireEventKind` (`compositor-core/Sources/NucleusCompositorServerTypes/ServerTypes.swift:16`)
is NSEvent in all but name — 24 cases including `leftMouseDown`, `mouseMoved`, `keyDown`,
`flagsChanged`, `scrollWheel`, the touch set. `WireEventRecord` (`:314`) is CGEvent-shaped
(`kind, flags, timestampNs, x, y, data0…data3`). `EventFlagBit` (`InputXkb.swift:13`) mirrors
CGEventFlags bit positions exactly. NucleusUI discards all of it:
`ShellOverlayTypes.swift:94` narrows 6 kinds to 2 and drops keycode and modifiers.

`core/` deliberately resolves no compositor dependency, so NucleusUI does **not** import
`WireEventKind`. Both converge on AppKit as the shared reference; the compositor's adapter
translates.

- `Event` becomes a tagged record mirroring `WireEventRecord`'s shape: kind, modifier flags,
  location, timestamp, plus per-kind payload (button, clickCount, scrollDeltaX/Y, keyCode,
  characters).
- `EventType` grows the NSEvent-shaped set: pointer down/up/moved/dragged/entered/exited,
  scrollWheel, keyDown/keyUp, flagsChanged.
- **Wire `firstResponder` and `isKeyWindow`.** Both are dead code today — assigned at
  `Window.swift:155` and `WindowScene.swift:80`, read by nothing outside tests. Keyboard
  events route key-window → first responder; pointer events keep hit-testing. Add
  `becomeFirstResponder`/`resignFirstResponder`/`acceptsFirstResponder`.
- Add pointer capture (implicit grab) to `Responder`.
- `Control` gains pointer-exit/drag-cancel — today the press latch clears on any `pointerUp`
  regardless of location.
- **Characters have no producer anywhere.** `XkbKeyboard.keyGetOneSym` returns a keysym only;
  no `xkb_state_key_get_utf8`, no compose state. Add both to feed `event.characters`.
- Add a key-repeat timer for NucleusUI views. The only repeat today is
  `wl_keyboard_send_repeat_info(25, 600)` (`WlSeat.swift:443`), delegated to Wayland clients —
  NucleusUI views are not Wayland clients and have no repeat at all.

Files: `NucleusUI/{Action,Responder,Control,Window,WindowScene}.swift`;
`NucleusCompositorOverlay/ShellOverlay/{ShellOverlayTypes,ShellOverlayScene}.swift`;
`compositor-core/.../InputXkb.swift`.

**Lands with:** `ShellOverlayScene.handleMenuKey` (`:433-473`, a raw switch over hardcoded
evdev integers driving `moveHighlight` directly), `capturedPointerButtons` (`:564-576`), and
the `button != 272` left-click filter (`:552`) all deleted. Menu keyboard nav becomes a
first-responder implementation. Right-click and middle-click reach views for the first time.

## Phase 8 — Layout: measure/arrange and flex

`intrinsicContentSize` takes no container width, so a `StackView` cannot ask a `Label` "how
tall at width 200?" — text wrapping cannot participate in layout at all. Noctalia's `Node`
measure/arrange with `LayoutConstraints` is the reference.

- Two-phase measure/arrange: `measure(_ constraints:)` taking a proposed size, then
  `arrange`. `intrinsicContentSize` becomes the degenerate no-constraint case.
- Flex (grow/shrink/basis, distribution, cross-axis alignment) in the arrangement model.
- **Fix the coordinate-space bug** (see Context): drop `bounds.origin` from `StackView`'s
  arithmetic so children are placed child-local, matching `hitTest` and every manual
  `layout()`.
- Fix `displayIfNeeded`/`layoutIfNeeded` recursing into all children unconditionally (O(tree)
  per publish regardless of dirty state), and `intrinsicContentSize` being a getter that
  clears its own dirty flag as a side effect (`View.swift:377`).
- Add a layout scheduler. Today there is none — layout runs inside
  `ViewLayerPublisher.appendViewTree` (`:122-123`) during publication, which is why the
  overlay force-calls `layoutIfNeeded()` in four places to read frames before publish.

Files: `NucleusUI/{View,StackView,Geometry,ViewLayerPublisher}.swift`;
`NucleusCompositorOverlay/ShellOverlay/{ShellOverlayNotificationView,ShellOverlayHotkeyView,ShellOverlayScene}.swift`.

**Lands with:** `ShellOverlayNotificationListView`'s `layout()` override
(`ShellOverlayNotificationView.swift:218`, which exists solely to work around the coordinate
bug) and the overlay's four manual `layoutIfNeeded()` calls deleted.

## Phase 9 — ScrollView, the capstone

The one primitive that fails if any of Phases 5, 7, or 8 is wrong: clipping
(GraphicsContext), `scrollWheel` (events), content sizing (measure/arrange).
`AnimationKeyPath` already reserves `scrollOffsetX`/`scrollOffsetY` (`Types.swift:26-27`), so
the render model anticipates it.

Scroll physics — rubber-band, inertia, fling — is real work beyond the API surface and is the
substance of this phase. Closes the roadmap's "native scroll physics" moat.

Files: new `NucleusUI/ScrollView.swift`; `NucleusUI/{View,Responder}.swift`.

## Phase 10 — IME and text editing

Closes the roadmap's "native IME + Nucleus text editing/selection" moat. The substrate
already exists and is unconsumed: `TextSystem` has `glyphPosition(at:)`,
`selectionRects(forUTF16Range:)`, `caretForOffset(_:affinity:)`, grapheme breaks, bidi.

- `TextField` and `TextView` on that substrate, with selection, caret affinity, and editing.
  `TextView` builds on Phase 9's ScrollView.
- Bind `ZwpTextInputV3` server-side — the bindings are generated and sitting unused in
  `swift-wayland/Sources/WaylandServerDispatch/`; nothing binds them.
- Preedit/composition, candidate handling, and the `text_input_client.h`-equivalent seam.

Files: new `NucleusUI/{TextField,TextView}.swift`; `compositor-core/.../` text-input binding;
`NucleusUI/TextSystem.swift`.

## Phase 11 — Publication and hosted-surface de-SPI

The overlay's entire SPI dependency: `WindowScenePublicationContext` (`init(commitSink:)`,
`withSemanticContext`, `makeWindowScene`, `makeHostedSurfaceRegistry`), `CommitSink`, `Layer`,
`WindowScene.publish(hostedSurfaces:)`, `attachHostedSurface(_:using:)`,
`attachHostedSurfaces(_:where:using:)`, `HostedSurface`, `HostedSurfaceRegistry`,
`PublishedScene`, `HostedVisualContent`.

Promote that to public, keeping SPI only for what is genuinely compositor-privileged.
`HostedSurface.rootView`/`role`/`level`/`frame`/`init` are `package` while the registry
around them is SPI — half-opaque either way.

`HostedSurface` is **not** the external-texture path despite appearing to be: it publishes a
`rootLayerID` for the compositor to place and never binds content. External textures
(CEF/dmabuf) go through `ContentKind.external` → `IOSurfaceContent.bind(id:)`
(`Content.swift:180`, already public) → `importDmaBufImage` → `Recorder.wrapBackendImage`.
Already the least-gated content route; needs nothing here.

Files:
`NucleusUI/{WindowScene,WindowScenePublicationContext,HostedSurface,PublishedVisualContent}.swift`;
`NucleusCompositorOverlay/ShellOverlay/*`, `NucleusCompositorOverlayScene/Runtime.swift`.

**Lands with:** `NucleusCompositorOverlay` and `NucleusShellRuntime/ShellHost.swift`
importing `NucleusUI` with no `@_spi(NucleusCompositor)`.

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
- **Phases 2–4**: existing rendering is unchanged — these phases add capability without
  emitting it. The exhaustive-switch conversion is verified by the compiler.
- **Phase 5**: an out-of-module `View` subclass (a fixture target outside package `Nucleus`)
  draws paths, gradients, and an SkSL effect and produces the expected command stream. Pixel
  coverage goes through the live Graphite offscreen path — `NucleusSkiaGraphiteTests` already
  links the full static Skia archive set and runs real Skia ops. **Add a stroked-border pixel
  test**: nothing renders a border today, so this is new coverage, not a regression check.
- **Phase 5, hardest risk**: the `[PaintCommand] ==` diff in `publishPaint` is the real
  re-registration gate, and **payload must participate in equality** — two different paths at
  the same `offset+length` would otherwise compare equal and silently drop the repaint.
  Worse, `makeTextLayoutHandle` (`ViewLayerPublisher.swift:635`) prefers a stable
  `layout.storage?.retainedHandle()` and falls back to minting a fresh transient handle; on
  the fallback the arrays never compare equal and the view re-registers **every publish**.
  `Label` papers over this by caching its layout. **No existing test would catch a regression
  here** — add one that counts registrations through the stub registrar.
- **Phase 6**: gated on tracing RN's publish path first.
- **Phase 7**: dispatch tests for key routing (key-window → first responder), scroll, pointer
  enter/exit, drag-cancel, capture — extending `ResponderTests.swift`. The overlay menu's
  keyboard nav is the end-to-end proof: identical behavior with `handleMenuKey` deleted.
- **Phase 8**: extend `LayoutTests.swift` with measure/arrange under constraints, flex
  distribution, and text-wrap-participates-in-layout. **Add the missing test that would have
  caught the coordinate bug: lay out a `StackView` at a non-zero origin and hit-test a point
  inside an arranged subview.** No existing test does this, which is why the bug survives.
  `LayoutTests.swift:27` (`verticalStackUsesIntrinsicSizesAndSpacing`) pins the buggy
  placement — stack at `x:10` → first child at `x:10` — and must be rewritten to expect `x:0`.
- **Phase 9**: scroll offset, clipping, wheel routing, and physics settling, headless.
- **Phase 10**: caret/selection/preedit against the existing `TextSystem` behavior tests.
- **Phase 11**: `NucleusCompositorOverlay` builds with a plain `import NucleusUI`;
  `compositor-core/Tests/NucleusCompositorOverlayTests` passes unchanged.

**End-to-end, on hardware.** Run `nucleus-compositor` and exercise the shell overlay: menus
(keyboard nav, right-click, submenus), notifications (stack transitions, close button), and
the hotkey HUD. This is the only path exercising publication → Graphite → Vulkan → scanout
with real input. This is the user-owned validation step; a goal is complete when every
agent-runnable gate passes and only this remains.

## Risks

- **RN's publish path (Phase 6)** — the one place "delete the duplicate" may be an
  architecture change. Trace before committing to the phase.
- **Text-layout handle stability (Phase 5)** — a silent, untested degradation to per-publish
  re-registration for every text view. Add registration-counting coverage.
- **Payload-offset determinism (Phase 5)** — the `==` gate depends on the recorder being
  deterministic and append-only.
- **Scroll physics (Phase 9)** and **IME (Phase 10)** are the two phases whose substance is
  genuinely novel work rather than mechanical restructuring.
- **Zero risk to the overlay** for all drawing phases, verified: `compositor/` and `shell/`
  never reference `ViewLayerContentCommand` or `LayerContentCommandKind`.
