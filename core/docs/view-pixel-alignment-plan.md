# View Pixel Alignment Plan

## State invariant

Across every phase boundary the following must hold:

1. **Backing space is the only space in which "pixel" is meaningful.**
   Rounding to a pixel happens by converting a point-space rect to the
   owning `Window`'s backing space, rounding edges per a declared policy,
   and converting back. There is no implicit global scale, no
   `singlePixelLength` rounding done in isolation, and no rounding
   performed against a scale other than the target window's.
2. **Backing scale is per-`Window`, not global.** Every alignment call
   resolves the backing scale through the view's owning window. A
   detached view (no window) is a programming error for alignment
   purposes and returns the input rect unchanged; layout that needs
   alignment runs after window attachment.
3. **Layer geometry the renderer composites is whole-device-pixel on
   every visible edge that participates in the alignment rect.** Shadow
   bleed, blur halos, and focus rings live outside the alignment rect via
   `alignmentRectInsets` and are not required to be pixel-aligned. The
   visible rounded-rect edge of an overlay panel is.
4. **Text baseline Y lands on a whole device pixel; baseline X may be
   subpixel.** The render-server text backend enforces this regardless of
   what the view layer passed in. Glyph advance widths and kerning are
   preserved by leaving X fractional.
5. **`view.frame = rect` is a raw setter.** Snapping is opt-in through
   `backingAlignedRect(_:options:)`. Layout helpers that compute frames
   from intrinsic content (`Label.placeBaseline`, `Label.centerVertically`,
   view-centering helpers) snap their result by default; raw assignments
   stay raw. This matches AppKit's contract — `NSView.setFrame:` does not
   snap; `-layout` callers are expected to feed rects through
   `-backingAlignedRect:options:`.
6. **Shadow / decoration insets are declared, not absorbed into the
   visible frame.** `View.alignmentRectInsets` decouples the layout rect
   from the layer's geometric footprint. Aligning the alignment rect
   aligns the visible edge; aligning the raw frame would round the visible
   edge off a pixel whenever a shadow is present.

## Position

This plan is the authoritative reference for nucleus' pixel-alignment
contract across the Nucleus view layer, the render server text backend,
and overlay layout code. It exists because the current implementation
emits layer frames in points with fractional values, the render server
samples those layers with linear filtering at fractional device-pixel
offsets, and the Skia text backend paints glyph paragraphs at whatever Y
the view layer hands it. The visible symptom is faint ~1-device-pixel
horizontal seams between every row of `ShellOverlayHotkeyView`, but the
root cause is structural: no view-layer API exists to align a rect to
backing pixels, no convention enforces snapping at layout time, and the
text backend has no baseline snap of its own.

The plan picks **AppKit's alignment contract translated into Nucleus
module names** over alternatives like silent renderer-side snapping or
SwiftUI-style automatic layout snapping. Reason: AppKit's approach
matches the macOS reference posture this codebase has chosen for
compositor and window-server work; per-window backing scale matches the
mixed-DPI multi-monitor case Nucleus will need anyway; explicit
caller-driven alignment with policy options is more honest than implicit
global snapping, because shadow rects want outward rounding, content
rects want nearest, and text baselines want nearest-Y-only. CALayer
itself does not snap and the compositor should not either; the knowledge
of "what counts as a meaningful boundary" lives at the window/view
layer.

The plan does not snap inside the Zig compositor, the
`src/valence/render/BackingStore.zig` rasterizer, or Graphite. Those
remain agnostic. Snapping is a Swift-side layout contract plus a
text-backend draw-time invariant.

## Pre-conditions

Already in tree:

- `Window` exists at `swift/Sources/NucleusUI/Window.swift` but does
  **not** carry a `backingScaleFactor`. The scale flows around
  `Window` today, plumbed per-event through
  `ShellOverlayFrameInfo.backingScaleFactor`
  (`NucleusCompositorOverlay/ShellOverlay/ShellOverlayTypes.swift:13`)
  and passed to `ShellOverlayHotkeyMetrics` by hand
  (`NucleusCompositorOverlay/ShellOverlay/ShellOverlayHotkeyView.swift:280`).
  Phase 2 makes `Window` the at-rest owner of the scale; the per-frame
  event becomes a writer, not a layout-time source of truth.
- `BackingScaleFactor` at `swift/Sources/NucleusUI/BackingScaleFactor.swift`
  already has `backingPixels(fromPoints:)` /
  `points(fromBackingPixels:)` overloads for `Float`, `Double`,
  `Point`, `Size`, and `Rect`. The Phase 2 conversion methods on
  `Window` are thin forwarders to these. `singlePixelLength` exists;
  its only consumer is `ShellOverlayHotkeyMetrics.hairlineWidth`
  (`ShellOverlayHotkeyView.swift:65`) and retires in Phase 7.
- `EdgeInsets` already exists at
  `swift/Sources/NucleusUI/Geometry.swift:73-87`
  (`top/left/bottom/right: Double`, `.zero`). Phase 4 reuses it as-is;
  no new type is introduced.
- The geometry plane is consistently `Double` from the wire payload through
  the Swift view layer: `nucleon_point` / `nucleon_size` /
  `nucleon_rect` are `f64`
  (`src/nucleon/dynamics/wire.zig`); `Point`, `Size`, `Rect`,
  `EdgeInsets` (`Geometry.swift`), `GeometryRect` / `GeometryPoint` /
  `GeometrySize` (`swift/Sources/NucleusLayers/Geometry.swift`), `TextLayout`'s baseline
  offsets, and `Label.firstBaselineOffsetFromTop` are all `Double`.
  Three pockets are `Float` and need normalization in Phase 1:
  `BackingScaleFactor.value` (the scalar itself), the entire
  `ShellOverlayHotkeyMetrics` struct's geometry fields (`lineH`,
  `pad`, `sepY`, `rowStartY`, baseline offsets — all gratuitously
  cast from `Double`), and `ShellOverlayHotkeyRowView.place(boxWidth:
  baselineY:)`'s parameters. `Float` legitimately remains for the GPU
  / paint-command boundary (`ViewLayerPublisher`'s paint command
  fields, color RGBA channels, `Font.pointSize`); those stay `Float`.
- `View.frame` is a raw setter that journals an FFI layer update
  (`swift/Sources/NucleusUI/View.swift:95-109`). It does no snapping and
  continues to do none. The contract is "helpers snap; the setter is
  raw," matching AppKit.
- `Label.placeBaseline(at:x:width:)` and `Label.centerVertically(in:)`
  set `frame` directly to a layout-derived rect with no rounding
  (`swift/Sources/NucleusUI/Label.swift:74-92`).
- React Native mounting has a pixel-alignment helper at
  `swift/Sources/NucleusReactRuntimeCxx/MountConsumer.swift:451-460`
  (`pixelAlignedEnclosing(_:scale:)`), called from exactly two sites:
  `ReactParagraphComponentView.apply(_:)` at line 395 and
  `.updateEnvironment(_:)` at line 403. Its semantics (origin floor,
  max-edge ceil in backing space) map exactly to
  `BackingAlignmentOptions.alignAllEdgesOutward`. The helper retires
  in Phase 7 alongside the overlay migration; both call sites switch
  to `view.backingAlignedRect(view.frame, options: .alignAllEdgesOutward)`.
- `src/render_server/skia/skia_text_backend.cpp::nucleus_canvas_draw_text_layout`
  draws paragraphs at whatever `(x, y)` the caller passes
  (line 577-582), with no baseline snap.

Out of scope:

- The compositor's Wayland-side surface alignment. Wayland surface
  positions are not part of this contract; this plan only governs
  Nucleus view-tree layout that flows into the render server through
  `ViewLayerContentCommand`.
- Subpixel text X positioning. X stays subpixel by design.
- Per-layer rasterization scale changes. Layer `contentsScale` is
  unchanged.
- RN/Yoga layout output. RN frames flow through the same
  `View.backingAlignedRect` primitive once Phase 7 retires
  `pixelAlignedEnclosing`, but RN's layout engine itself is unchanged.

## Phase 1 — Geometry-plane type normalization (`Float` → `Double`)

The view-layer geometry plane is canonically `Double`: the wire record
fields are `f64`, all `Point` / `Size` / `Rect` / `EdgeInsets` /
`GeometryRect` fields are `Double`, and the text system already returns
`Double` baseline offsets. The remaining `Float` pockets are gratuitous casts
in overlay layout code and one `Float`-typed scalar
(`BackingScaleFactor.value`) that participates in coordinate
arithmetic. Phase 1 closes those before the
`Window.convert*ToBacking` surface lands in Phase 2 so the new
methods are `Double`-typed from the start.

Changes in Phase 1:

- `BackingScaleFactor.value: Float` → `Double`
  (`swift/Sources/NucleusUI/BackingScaleFactor.swift:8`). The struct's
  initializers `init(_ value: Float)` and `init(_ value: Double)`
  both remain; the `Float` initializer is the convenience for the one
  current caller that constructs from `Float devicePixelRatio`
  (`ShellOverlayTypes.swift:15`).
- `BackingScaleFactor.backingPixelsPerPoint` returns `Double`. A
  `backingPixelsPerPointFloat` (or `Float(scale.backingPixelsPerPoint)`
  at the call site) covers the lone consumer at
  `MountConsumer.swift:452` until Phase 7 retires that helper.
- The `Float` overloads of `backingPixels(fromPoints: Float) -> Float`
  and `points(fromBackingPixels: Float) -> Float`
  (`BackingScaleFactor.swift:32-34, 40-42`) stay. They serve color and
  paint-command callers that legitimately work in `Float`.
- `ShellOverlayHotkeyMetrics` (`ShellOverlayHotkeyView.swift:39-82`)'s
  geometry fields (`hairlineWidth`, `lineH`, `pad`, `colGap`,
  `keyColW`, `sepY`, `rowStartY`, `rowTextHeight`,
  `rowBaselineOffset`, `titleTextHeight`, `titleBaselineOffset`,
  `footerTextHeight`, `footerBaselineOffset`) become `Double`. Font
  size fields (`fontSize`, `titleSize`, `footerSize`, `statusSize`)
  stay `Float` to match `Font.pointSize: Float`. The
  `Float(rowLayout.intrinsicSize.height)` and sibling casts
  (lines 65, 69-74) delete.
- `ShellOverlayHotkeyRowView.place(boxWidth: Float, baselineY: Float)`
  (`ShellOverlayHotkeyView.swift:136`) → `Double, Double`. Its
  callers in `ShellOverlayHotkeyView.layout()` (lines 335-378) drop
  their `Float(...)` casts.
- Audit `NucleusCompositorOverlay/` for any other `Float`-typed
  geometry locals and convert. The audit is in scope for Phase 1; the
  search target is `: Float` and `-> Float` in coordinate-shaped
  contexts.

After Phase 1, the only `Float` in the layout plane is at the
`ViewLayerPublisher` paint-command boundary and in typography
(`Font.pointSize`, color channels). The
`pixelAlignedEnclosing(_:scale:)` helper at `MountConsumer.swift:451`
still works unchanged (it already operates in `Double` internally);
its retirement in Phase 7 is unaffected by Phase 1.

## Phase 2 — `Window` owns the backing scale; conversion primitives land on it

`Window` becomes the at-rest owner of backing scale for its view tree.
The scale stops flowing around `Window` per-event and instead lives on
it; per-frame events (today's `ShellOverlayFrameInfo.backingScaleFactor`)
become writers that update the field before invoking layout. This
matches AppKit: `NSWindow.backingScaleFactor` is the canonical source,
not a value redrived per layout pass.

Surface added on `Window` (`swift/Sources/NucleusUI/Window.swift`):

```swift
public private(set) var backingScaleFactor: BackingScaleFactor  // default .one

package func setBackingScaleFactor(_ scale: BackingScaleFactor)

public func convertRectToBacking(_ rect: Rect) -> Rect
public func convertRectFromBacking(_ rect: Rect) -> Rect
public func convertPointToBacking(_ point: Point) -> Point
public func convertPointFromBacking(_ point: Point) -> Point
public func convertSizeToBacking(_ size: Size) -> Size
public func convertSizeFromBacking(_ size: Size) -> Size
```

The conversion methods are thin forwarders to
`BackingScaleFactor.backingPixels(fromPoints:)` /
`points(fromBackingPixels:)` against the window's current
`backingScaleFactor`. Semantics match AppKit one-for-one: multiplying /
dividing by the window's current scale, no rounding. Rounding is the
caller's job and uses Phase 2's API.

`ShellOverlayScene` writes `window.setBackingScaleFactor(...)` from the
frame event before driving layout. `ShellOverlayFrameInfo` keeps its
`backingScaleFactor` accessor as the wire-format value, but stops
being the layout-time source of truth; layout reads
`window.backingScaleFactor`.

Free-function variant on `BackingScaleFactor` for the narrow set of
callers that compute layout values during construction, before view
attachment (e.g. `ShellOverlayHotkeyMetrics.init(backingScaleFactor:)`):

```swift
extension BackingScaleFactor {
    public func align(_ rect: Rect, options: BackingAlignmentOptions) -> Rect
}
```

This is the exception, not the norm. Phase 7 moves
`ShellOverlayHotkeyMetrics` away from it where possible by deferring
the scale-dependent metrics until first layout, at which point a window
is available.

`BackingScaleFactor.singlePixelLength`'s one consumer
(`ShellOverlayHotkeyMetrics.hairlineWidth`) retires in Phase 7 in
favor of `window.convertSizeFromBacking(Size(width: 0, height: 1))`.

## Phase 3 — `backingAlignedRect` on `View`

The alignment primitive lives on `View`, mirroring
`NSView.backingAlignedRect:options:` exactly. The options set is
identical in shape to `NSAlignmentOptions`:

```swift
public struct BackingAlignmentOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    public static let alignMinXInward: Self
    public static let alignMinYInward: Self
    public static let alignMaxXInward: Self
    public static let alignMaxYInward: Self
    public static let alignWidthInward: Self
    public static let alignHeightInward: Self

    public static let alignMinXOutward: Self
    public static let alignMinYOutward: Self
    public static let alignMaxXOutward: Self
    public static let alignMaxYOutward: Self
    public static let alignWidthOutward: Self
    public static let alignHeightOutward: Self

    public static let alignMinXNearest: Self
    public static let alignMinYNearest: Self
    public static let alignMaxXNearest: Self
    public static let alignMaxYNearest: Self
    public static let alignWidthNearest: Self
    public static let alignHeightNearest: Self

    public static let alignRectFlipped: Self

    public static let alignAllEdgesInward: Self  // Min{X,Y}Inward | Max{X,Y}Inward
    public static let alignAllEdgesOutward: Self
    public static let alignAllEdgesNearest: Self
}

extension View {
    public func backingAlignedRect(
        _ rect: Rect,
        options: BackingAlignmentOptions = .alignAllEdgesNearest
    ) -> Rect
}
```

Implementation walks `parentView` chain to the owning `Window`,
converts to backing space, rounds each edge per options (width/height
options take precedence and round the size after origin is placed),
converts back. Returns the input rect unchanged if no window is found
(consistent with invariant #2; layout that depends on alignment runs
post-attachment).

A free-function variant accepting an explicit `BackingScaleFactor` is
also provided so the metrics-construction sites that exist before view
attachment (e.g. `ShellOverlayHotkeyMetrics.init(backingScaleFactor:)`)
can align without a window.

The default option set `.alignAllEdgesNearest` matches AppKit's most
common usage; layout helpers that need different policies (Phase 4)
specify them explicitly.

## Phase 4 — `alignmentRectInsets` on `View`

`View` gains the decoration / layout-rect separation. Surface mirrors
AppKit and reuses the existing `EdgeInsets` from
`swift/Sources/NucleusUI/Geometry.swift:73`:

```swift
extension View {
    public var alignmentRectInsets: EdgeInsets { get set }  // default .zero

    public func alignmentRect(forFrame frame: Rect) -> Rect
    public func frame(forAlignmentRect rect: Rect) -> Rect
}
```

Default `alignmentRectInsets = .zero` keeps existing call sites' frame
== alignment-rect.

The two `*forAlignmentRect` / `*forFrame` helpers compose with Phase 3:
layout code aligns the *alignment* rect, then converts to frame, then
assigns. The composed pattern is what Phase 5 helpers and Phase 7
overlay code use.

`ShellShadow.hotkeyOverlay`'s blur radius lands as the
`alignmentRectInsets` of `ShellOverlayHotkeyView` as part of Phase 7.
Other shadowed views (`ShellShadow.popover`, any future shadowed
overlay) follow the same pattern when they migrate.

## Phase 5 — Snap-by-default in `Label` and `View` layout helpers

The layout helpers that compute frames from intrinsic content snap their
output through `backingAlignedRect` with the right policy per helper.
Raw `view.frame = rect` assignments stay raw — the contract matches
AppKit's "the helpers snap; the setter is raw."

Helpers updated:

- `Label.placeBaseline(at:x:width:)` (`swift/Sources/NucleusUI/Label.swift:74-82`)
  snaps with `[.alignMinYNearest, .alignAllEdgesOutward]`. Y rounds to
  the nearest device pixel to keep the baseline visually anchored; width
  and height round outward so glyph extents are not clipped by the
  layer bound.
- `Label.centerVertically(in:)` (`swift/Sources/NucleusUI/Label.swift:84-92`)
  snaps with the same option set.
- Any sibling helper added later (`View.center(in:)`, content-sizing
  variants) follows the same default. New helpers without a clear
  policy default to `.alignAllEdgesNearest`.

`Label.placeBaseline`'s implementation walks to its owning window once
per call; if not yet attached (initial bring-up), it skips the snap and
returns to fractional positioning. Phase 7's overlay code attaches the
labels before the first layout pass so this fallback path is not hit at
steady state.

## Phase 6 — Baseline-Y snap in the Skia text backend

`src/render_server/skia/skia_text_backend.cpp::nucleus_canvas_draw_text_layout`
snaps the paint Y to whole device pixels before calling
`paragraph->paint(canvas, x, y_snapped)`. The implementation inspects
the canvas's current matrix to recover device scale, rounds Y to
nearest device pixel, leaves X subpixel.

This is the belt to Phase 5's suspenders: even when a caller forgets to
align, text rasterization stays crisp. It also covers the case where a
view-side rect rounded outward leaves the baseline computed from text
metrics fractional within the rounded layer.

The snap is unconditional. There is no per-call opt-out. CoreText's
analogous behavior is the default on modern macOS and the snap matches
that. If a future caller needs fractional baseline Y (none today), a
flag on the `TextLayout` paint command is the place to add it; the
default stays snapped.

This phase modifies the render server but the change is localized to one
function and one file. No compositor-side snapping is added.

## Phase 7 — Apply the contract to overlays

With phases 1–6 landed, `ShellOverlayHotkeyView` and the overlay layer
adopt the contract. Specifically:

- `ShellOverlayHotkeyView.updateFrame(_:)`
  (`NucleusCompositorOverlay/ShellOverlay/ShellOverlayHotkeyView.swift:275-297`)
  runs its computed panel rect through `backingAlignedRect(_:, options:
  .alignAllEdgesNearest)` before assignment.
- `ShellOverlayHotkeyView.alignmentRectInsets` returns the shadow blur
  / spread of `ShellShadow.hotkeyOverlay` so the visible rounded
  rectangle pixel-aligns rather than the shadow-inclusive layer rect.
- `ShellOverlayHotkeyRowView.place(boxWidth:baselineY:)`
  (`NucleusCompositorOverlay/ShellOverlay/ShellOverlayHotkeyView.swift:136-147`)
  snaps `rowFrame` with `.alignAllEdgesNearest`. The per-label snap
  is handled by Phase 5's `Label.placeBaseline` and
  `Label.centerVertically`.
- `ShellOverlayHotkeyView.layout()`
  (`NucleusCompositorOverlay/ShellOverlay/ShellOverlayHotkeyView.swift:299-379`)
  snaps the `separatorView.frame`, the per-row `rowBackgroundViews`
  frames, and the `activeStripeViews` frames. The `separatorView`
  height continues to use the hairline width, but expressed as
  `window.convertSizeFromBacking(Size(width: 0, height: 1)).height`
  rather than the current `BackingScaleFactor.singlePixelLength`.
- `ShellOverlayHotkeyMetrics`'s `hairlineWidth` field is removed; the
  one consumer reads it inline from the window conversion in
  `layout()`. The `0.92` row-height multiplier, `lineH * 0.3` blank
  spacer, and `(lineH - rowTextHeight) * 0.5` centering math stay in
  points; per-row Y snapping at `place(...)` makes them safe.

`swift/Sources/NucleusReactRuntimeCxx/MountConsumer.swift:451-460`'s
private `pixelAlignedEnclosing(_:scale:)` helper retires. Its two
callers, `ReactParagraphComponentView.apply(_:)` (line 395) and
`.updateEnvironment(_:)` (line 403), switch to:

```swift
let aligned = view.backingAlignedRect(view.frame, options: .alignAllEdgesOutward)
if aligned != view.frame {
    view.frame = aligned
}
```

The `.alignAllEdgesOutward` policy reproduces
`pixelAlignedEnclosing`'s exact semantics (origin floor in backing
space, max-edge ceil in backing space) so behavior at every backing
scale is preserved. After the migration, RN mounting reads backing
scale from `view.window.backingScaleFactor` (through
`backingAlignedRect`'s internal walk) rather than
`environment.backingScaleFactor`, and the tree has exactly one
round-to-backing implementation.

The retirement is atomic with the overlay migration in this phase
rather than landing earlier. Doing it earlier would leave the helper
around as the only "uses `environment.backingScaleFactor` instead of
`window.backingScaleFactor`" call site and split the contract across
two implementations during the intermediate state.

## Phase 8 — Audit and migrate remaining overlays

`NucleusCompositorOverlay`'s other surfaces (status bar, any additional mounted
overlay views) are audited once and brought onto the same contract:
panel frames pass through `backingAlignedRect`, shadowed surfaces
declare `alignmentRectInsets`, ad-hoc `singlePixelLength` arithmetic
retires in favor of `Window.convertSizeFromBacking` or
`backingAlignedRect`. After this phase, no `NucleusCompositorOverlay` view
computes a frame without going through the contract, and the only
remaining users of `BackingScaleFactor` raw multiplication are inside
`Window`'s conversion methods.

`NucleusCompositorShell` services that compute view frames directly (if any
exist; the audit confirms or denies) follow the same migration.

## Phase 9 — Verification

The artifact reproduces today as horizontal seams between rows of the
keybindings overlay. Verification after Phase 7 is:

- The seams visible in the current screenshot are absent at every backing
  scale the test harness covers (1.0, 1.25, 1.5, 1.75, 2.0).
- The seams remain absent under fractional-position overlay placement.
  Force the panel origin to several fractional point offsets and confirm
  no rows produce a visible alpha band.
- The title hairline separator remains exactly one device pixel tall at
  every scale.
- Glyph descenders are not clipped at the bottom of any label's layer at
  any scale (visible inspection of "g", "p", "y" in the row text).
- No regression in the React Native mounted UIs at any backing scale,
  confirming the `pixelAlignedEnclosing` → `backingAlignedRect`
  migration in Phase 7.

A unit-test surface for the alignment primitive itself lands alongside
Phase 3: `backingAlignedRect` round-trips known inputs at known scales
to known outputs. Per CLAUDE.md, tests assert runtime behavior — input
rect / scale / options → expected rect — not source-code shape.

Visual verification of the overlay seams is user-owned runtime
validation, listed explicitly in the Phase 7 completion report.

## Decisions

Settled during pre-conditions review, not open:

- **`Window` ownership of backing scale.** `Window` becomes the at-rest
  owner. Conversion primitives land directly on `Window` in
  `swift/Sources/NucleusUI/Window.swift`, not in a separate extension
  file. `ShellOverlayScene` writes the scale on each frame event
  before invoking layout; `ShellOverlayFrameInfo.backingScaleFactor`
  remains as the wire-format accessor but stops being read by layout
  code.
- **`EdgeInsets`.** The existing `EdgeInsets` at
  `swift/Sources/NucleusUI/Geometry.swift:73` is reused as-is for
  `alignmentRectInsets`. No new type.
- **`Float` / `Double` normalization.** In scope. The geometry plane
  is `Double` end-to-end after Phase 1; the residual `Float` pockets
  (`BackingScaleFactor.value`, `ShellOverlayHotkeyMetrics`'s
  coordinate fields, `ShellOverlayHotkeyRowView.place`'s parameters)
  convert in Phase 1. `Float` stays for typography (`Font.pointSize`),
  color channels, and the GPU paint-command boundary.
- **`pixelAlignedEnclosing` retire timing.** Atomic with the overlay
  migration in Phase 7. The semantics map cleanly to
  `.alignAllEdgesOutward`, so the migration is a mechanical
  call-site swap with no behavior change at any backing scale.
