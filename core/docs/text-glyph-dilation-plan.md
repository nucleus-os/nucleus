# Luminance-Based Glyph Dilation Plan

## State invariant

After this plan completes, the text glyph atlas holds, for every cached
glyph instance, an alpha tile whose outline has been dilated by a radius
determined by the foreground luminance bucket the glyph was last drawn
with. Atlas keys include the bucket. At paint time, `text_layout`
commands resolve to a sequence of
`(typeface, glyph_id, font_size, subpixel_x, bucket)` lookups; misses
raster the outline through Skia, dilate via an SkSL pass, and insert.
SkParagraph remains the layout authority and shaping engine.
Rasterization and painting of text runs moves from `paragraph->paint()`
into a Nucleus-owned painter that issues atlas-backed quads.

## Background

macOS CoreGraphics thickens glyph outlines for light-on-dark text. The
amount of thickening varies with foreground luminance: bright text on
dark backgrounds gets noticeably dilated; dark text on light backgrounds
is unchanged. Without this, dark-theme body text looks anemic compared
to native Mac applications.

CoreGraphics quantizes foreground luminance into 5 buckets and applies
a per-bucket stem dilation. The Zed editor reverse-engineered the
bucketing formula in
[zed-industries/zed#54886](https://github.com/zed-industries/zed/pull/54886):
Rec. 709 luminance → `round(4·Y)` → clamp 0..4. The actual dilation
magnitudes live inside libCoreGraphics; Zed delegates them by calling
`CGContextSetShouldSmoothFonts(true)` plus a gray fill color, letting CG
apply the dilation. That trick only works on macOS targets.

Nucleus runs on Linux through Skia Graphite. There is no equivalent
CG-internal dilation to delegate to. The replacement comes from
FreeType's `cff:darkening-parameters` curve, originally tuned by David
Turner against CoreGraphics output. It defines a piecewise-linear
function from point size to total stem-darkening amount in em-units.
We treat that curve as the bucket-4 (full smoothing) magnitude and
linearly scale across buckets 0–4.

## Position

This plan builds on the State 2 changes already landed:

- `MacTextSurfaceProps()` in `src/render_server/skia/skia_render_bridge.cpp`
  passes `SkSurfaceProps(0, kUnknown_SkPixelGeometry, 0.0f, 1.4f)` to
  every `WrapBackendTexture` call site. This gives grayscale AA (no LCD
  fringing) and macOS coverage gamma.
- `skiaTextStyle` in `src/render_server/skia/skia_text_backend.cpp` sets
  `SkFontHinting::kNone`. `skiaParagraphStyle` calls `turnHintingOff()`.
  Glyph outlines are no longer grid-fitted.

State 2 closes the AA-mode and coverage-curve gaps. The remaining
visible gap on dark themes is stroke weight. This plan closes that gap.

## Pre-conditions

Already in tree:

- The State 2 changes listed above.
- `nucleus_canvas_draw_text_layout` in
  `src/render_server/skia/skia_text_backend.cpp` is the single text
  paint site. Compositor calls it through `BackingStore.zig:422`
  against a paragraph handle registered through
  `SubstrateTextRegistry`.
- `TextRun.style.{red,green,blue,alpha}` survives marshaling from
  Swift to the C++ paragraph builder. Color is currently baked into
  SkParagraph at build time via `style.setColor(...)`.
- Skia Graphite is the GPU backend. SkSL effects load through
  `SkRuntimeEffect` in `skia_render_bridge.cpp:1142-1180`.
- The compositor main thread owns the Graphite recorder. Atlas
  inserts and dilation dispatches share that recorder.

## Dilation magnitude source

The reference is FreeType's `cff:darkening-parameters` default:

| Point size | Stem darkening (em-units at 1000em) |
| ---: | ---: |
| ≤ 5pt | 400 |
| 10pt | 275 |
| 16.67pt | 275 |
| ≥ 23.33pt | 225 |

Linearly interpolated between the listed sizes. Clamped at the edges.
This curve was calibrated against CG output and is the standard
approximation outside Apple.

That curve defines bucket-4 (full smoothing) total stem dilation in
em-units. Per-bucket magnitude:

```
dilation_em(point_size, bucket) = (bucket / 4) * stem_darkening(point_size)
```

Bucket 0 is identity. Stem darkening is applied as both-sides outline
dilation, so the SkSL radius in device pixels is:

```
radius_px = dilation_em * point_size * device_scale / 2000
```

(The `/1000` converts em-units to em fraction; the `/2` splits the
total stem dilation across the two outline sides.)

The calibration lives as a constant table in
`src/render_server/text/dilation_table.zig`. If user feedback after
shipping shows specific size bands look wrong, the table edits in one
place — not the shader, not the painter.

## Phase 1: extract foreground luminance and thread it to the painter

Bucketing is the cheapest piece. It has to land before anything else
can key on it.

### 1a. Compute the bucket in `collectRuns`

In `src/render_server/skia/skia_text_backend.cpp`, alongside the
existing color extraction from `nucleus::text::TextRun.style`, add:

```cpp
static uint8_t luminanceBucket(const nucleus::text::TextStyle& s) {
    const float y = 0.2126f * s.red + 0.7152f * s.green + 0.0722f * s.blue;
    const int level = static_cast<int>(std::floor(4.0f * y + 0.5f));
    return static_cast<uint8_t>(std::clamp(level, 0, 4));
}
```

This is the literal Zed formula. Attach the bucket to the per-run
record the paragraph handle stores.

The `nucleus::text::TextRun` C++ bridge record gains a
`uint8_t luminanceBucket` field. Swift call sites in
`swift/Sources/NucleusUI/` do not have to compute the bucket — the C++
side does it during `collectRuns`.

### 1b. Preserve the bucket through `SubstrateTextRegistry`

The registered paragraph handle today carries the SkParagraph plus
enough metadata to paint. Extend its per-run record to carry the
bucket. The bucket is per shaped glyph run, not per glyph — every
glyph in a shaped run shares the same foreground color. SkParagraph's
shaping may split a TextRun into multiple visual runs (font fallback,
bidi). The painter resolves bucket by walking back from visual-run to
source-run via SkParagraph's run-info API (see phase 4a for the
specific API).

### 1c. Preserve the original color on the handle

Today `paragraph->paint()` consumes the color set via
`style.setColor()`. The new painter needs the original color (for
non-text artifacts like underlines, strikethroughs, selection
backgrounds) plus the bucket. Both live on the per-run record.

Keep `style.setColor()` on the SkParagraph TextStyle so SkParagraph's
decoration painting still works through the legacy `paint()` call (see
phase 4a's fallback for decorations). The new painter ignores
SkParagraph's glyph-paint output entirely.

### 1d. Validation

After this phase, the bucket exists at the painter boundary but no
painter consumes it. The legacy `paragraph->paint()` still runs.
`swift build` and `swift test` both
pass. No visual change.

## Phase 2: own a glyph atlas

Atlas is the second piece because everything downstream needs it to
exist.

### 2a. New module `src/render_server/text/glyph_atlas.zig`

Skyline-packed dynamic atlas, two pages:

- A8 alpha page for monochrome glyphs (the dilation target).
- RGBA premultiplied page for color glyphs (emoji, COLR/CPAL). No
  dilation applied; these route around the SkSL pass.

Vulkan-side allocation uses the same allocator pattern as
`src/render_server/texture/texture_atlas.zig`. Backing storage is a
single per-page `VkImage` resized on overflow. Eviction is LRU on
glyph entries.

Key tuple:

```zig
const GlyphKey = packed struct {
    typeface_id: u64,
    glyph_id: u32,
    font_size_q: u16,        // point size * 16
    subpixel_variant: u8,    // 0..3 (matches Skia default)
    bucket: u8,              // 0..4
    color: u8,               // 0 = mono page, 1 = color page
};
```

`font_size_q` quantizes point size to 1/16 px steps; finer quantization
wastes atlas, coarser distorts metrics.

Entry record: `{ page, uv_rect, glyph_bounds_px, advance_px,
last_use_frame }`. Atlas hands out entries by reference; the painter
holds them for the duration of a paint pass.

### 2b. C++ raster shim `src/render_server/text/glyph_raster.cpp`

Single entry: `nucleus_text_raster_glyph(typeface_handle, glyph_id,
font_size_q, subpixel_x, out_bitmap)`. Internally:

1. Builds an `SkFont` from the typeface and quantized size, with
   `setHinting(SkFontHinting::kNone)` and
   `setEdging(SkFont::Edging::kAntiAlias)` (mirroring the surface-level
   decision from State 2).
2. Calls `SkFont::getPath(glyph_id, &path)` and `SkFont::getWidths` for
   the advance.
3. Allocates a tight A8 bitmap sized to the path bounds plus one pixel
   margin per side (dilation may grow into the margin).
4. Fills the path into an `SkSurface::MakeRasterDirect` wrapping the
   bitmap, with `SkSurfaceProps(0, kUnknown_SkPixelGeometry, 0.0f,
   1.4f)`.
5. Returns the bitmap, advance, and origin offset.

Wired from Swift via the existing C-ABI / C++-interop pattern in
`skia_render_bridge.cpp`. The shim file compiles into the same SwiftPM
C++ target as `skia_render_bridge.cpp` (added to that target's source
list), not registered in any `build.zig`.

### 2c. Atlas insert path in Zig

On miss:

1. Call `nucleus_text_raster_glyph` for the raw A8 bitmap.
2. Allocate atlas space on the appropriate page.
3. Schedule a buffer-to-image upload through the Graphite recorder.
4. Dispatch the dilation pass (phase 3) before the entry is marked
   ready.
5. Mark entry ready; record `last_use_frame`.

Inserts and dilation happen on the main thread alongside the io_uring
loop, on the same Graphite recorder used for the frame paint, so they
share submit ordering with the rest of the frame.

### 2d. Validation

The atlas module exists and round-trips a monochrome glyph end to end
through a unit test in `src/render_server/text/test_glyph_atlas.zig`:
raster glyph 'A' at 12pt → insert → look up by key → blit to scratch
surface → compare against directly-rasterized bitmap. No dilation yet.
No production caller. Build green, atlas inert in the live pipeline.

## Phase 3: SkSL dilation pass and atlas integration

### 3a. `src/render_server/shaders/vulkan_stage/glyph_dilate.sksl`

Sub-pixel-capable A8 morphology. Two-pass separable max-filter with
linear falloff:

```glsl
uniform shader src;
uniform float radius;  // fractional pixels, 0 = identity

half4 main(float2 coord) {
    half acc = 0.0h;
    int taps = int(ceil(radius)) + 1;
    for (int i = -taps; i <= taps; ++i) {
        float weight = max(0.0, 1.0 - abs(float(i)) / max(radius, 0.0001));
        half s = src.eval(coord + float2(float(i), 0)).a;
        acc = max(acc, s * half(weight));
    }
    return half4(acc);
}
```

The pass is applied twice: horizontal pass writes to a scratch tile,
vertical pass writes to the atlas page at the final UV. Implement as
two explicit render passes rather than `SkImageFilters::Compose` — this
keeps memory bounded, avoids Skia rebuilding filter chains per glyph,
and lets the scratch tile be a per-frame ring buffer rather than a
fresh allocation per glyph.

Shader is loaded once at render-server init through the same mechanism
as the vibrancy and blur shaders.

### 3b. Dilation dispatch on atlas insert

After step 2c uploads the raw A8 tile, the atlas insert path:

1. Looks up dilation radius via `dilation_table.zig` keyed on
   `(font_size_q, bucket)`.
2. If radius is zero (bucket 0), marks the entry ready, done.
3. Otherwise: allocates a scratch tile the same size as the source,
   runs the H pass writing to scratch, runs the V pass writing into
   the atlas page at the final UV, marks ready.

Scratch tiles come from a per-frame ring buffer of small images, not
fresh allocations per glyph.

### 3c. Color glyph bypass

`SkFont::getPath` returns false for color/bitmap glyphs (emoji, CBDT,
COLR, sbix). On false return, the raster shim instead calls
`SkFont::getBounds` and draws the glyph via `SkCanvas::drawGlyphs` into
an RGBA tile, marks the atlas entry as color, and skips dilation.
Bucket is fixed at 0 for color entries (atlas key still includes it for
tuple uniformity, but only bucket-0 entries exist on the color page).

### 3d. Validation

Unit test in `test_glyph_atlas.zig` extends to assert:

- Bucket-0 entry pixels equal raw raster.
- Bucket-4 entry pixels show measurable thicker strokes than bucket-0
  for the same glyph (sum-of-alpha increases monotonically with
  bucket).

No production caller yet. Build green.

## Phase 4: custom paragraph painter

This is where the new path replaces `paragraph->paint()`.

### 4a. Painter implementation

New C++ class `NucleusGlyphPainter` in
`src/render_server/text/glyph_painter.cpp`. Walks an SkParagraph and
emits atlas-backed quads for each glyph.

Two possible API surfaces, in preference order:

1. `skia::textlayout::ParagraphPainter` — Skia's abstract paint-target
   interface for paragraphs. Override `drawTextBlob` /
   `drawGlyphRunList` to route glyphs through the atlas; let default
   implementations handle non-glyph paint (shadows, decorations,
   selection backgrounds).
2. Lower-level visitor: `Paragraph::visit(...)` plus `getRunInfo()` /
   `getActualTextRange()`. Walk runs manually, reconstruct paint
   state. Use this if `ParagraphPainter` is incomplete or absent in
   the vendored Skia version.

Confirm which is available in `third-party/skia/modules/skparagraph/`
during phase 4a implementation. Worst case is forking the skparagraph
module to expose what's needed — allowed per the modify-owned-forks
rule in `CLAUDE.md`.

For each visual run:

1. Resolves the source TextRun (and therefore bucket) via the run's
   text range against the registered paragraph metadata from phase 1.
2. For each glyph in the run, computes `subpixel_variant` from glyph
   position fractional part (4 variants, matches Skia default).
3. Looks up the atlas entry. On miss, triggers insert + dilation
   (phases 2-3).
4. Emits a colored quad: vertex positions from glyph bounds + run
   baseline, UVs from atlas entry, color from the original
   `TextRun.style` color (atlas tile is alpha-only; color multiplies
   in the fragment shader).

Decoration runs (underline, strikethrough), selection-background runs,
and any text shadows are not glyph-based and stay on the SkParagraph
paint path. The painter calls `paragraph->paint()` first into a
recording canvas (intercepting glyph runs), or paints decorations
through a parallel pass — exact mechanism depends on which API
surface phase 4a settles on.

### 4b. Replace the paint call

`nucleus_canvas_draw_text_layout` in `skia_text_backend.cpp` switches
from:

```cpp
paragraph->paint(static_cast<SkCanvas*>(canvas), x, y);
```

to:

```cpp
nucleus::text::NucleusGlyphPainter painter(atlas);
painter.paint(paragraph, static_cast<SkCanvas*>(canvas), x, y);
```

The painter takes the per-paragraph metadata (registered in phase 1) by
handle, not as a separate argument. The atlas is a singleton owned by
the render server, accessed through a C ABI getter the same way
`skia_render_bridge.cpp` exposes other render-server state.

### 4c. Validation

End-to-end visual check: render a fixed test scene
(`tools/text_render_check/`, new) containing white-on-black body text
at multiple point sizes, dump the output to PNG, compare against macOS
reference screenshots that already exist online (Safari, TextEdit,
Xcode source listings). Body text stroke weight should noticeably
increase from State 2 baseline. No regression on dark-on-light
(bucket 0 stays identity).

Performance check: render a 1080p frame containing ~500 unique glyph
instances across 3–4 fonts and sizes. First frame populates the atlas;
second frame should be entirely atlas hits with cost dominated by the
quad-draw pass, not raster or dilation. Confirm via the existing
render-server tracing hooks.

## Phase 5: cleanup

After phase 4 ships and the visual check holds:

- Delete the legacy `paragraph->paint()` call site from
  `nucleus_canvas_draw_text_layout` if the painter takes over
  decoration painting too. If the painter still uses
  `paragraph->paint()` internally for decorations, leave it.
- Remove `style.setColor()` from `skiaTextStyle` only if SkParagraph
  decorations no longer read it. Underlines may still need it; verify
  before removing.
- Remove any temporary instrumentation added during validation.

## Risks and unknowns

**SkParagraph painter API surface.** The cleanest implementation
depends on `skia::textlayout::ParagraphPainter` being complete enough
to override glyph painting without breaking decorations and shadows.
If the vendored Skia exposes only the lower-level visitor API, the
painter has to walk runs and reconstruct paint state. Worst case is
forking the skparagraph module — allowed per the modify-owned-forks
rule. Confirm in phase 4a before committing to the painter shape.

**Subpixel positioning interaction with State 2.** State 2 did not
change subpixel-x quantization. SkParagraph today positions glyphs at
fractional pixel x. Owning the atlas means owning the subpixel-variant
decision: 4 variants × 5 buckets per glyph-size = 20 tiles worst case
per glyph. Realistic working set is small (body text concentrates in
1–2 sizes per font), but eviction policy must avoid thrashing during
scrolling.

**Atlas growth on long-lived shells.** A topbar that runs for a week
with frequent text changes can accumulate. LRU eviction keyed on
`last_use_frame` handles this; calibrate the page size empirically
during phase 2.

**FreeType curve fidelity.** The FreeType stem-darkening curve is
"approximately CG-shaped" but not CG-exact. Sizes outside the
calibrated range (very large headings at 48pt+, very small captions at
6pt-) may look off. The dilation table in
`src/render_server/text/dilation_table.zig` is the single edit point —
adjust there based on user feedback, not in shader logic.

**Per-bucket atlas tile counts.** A glyph drawn at multiple foreground
luminances generates multiple cached tiles. For shells that mix
light-on-dark and dark-on-light text in the same UI (likely), the upper
bound is 5× the otherwise-needed cache size. Unavoidable given the
architecture — Zed accepts the same multiplier.

**Decoration painting consistency.** Underlines drawn through
SkParagraph at the original color are not dilated. CoreGraphics
dilates underline strokes too. Phase 4 paints decorations through the
legacy path for simplicity; if visual mismatch is noticeable, a
follow-up dilates the underline stroke geometry directly before
stroking.

**Threading.** All atlas inserts and dilation dispatches share the
main thread's Graphite recorder. If a future change moves
rasterization to a worker, the atlas needs a second recorder plus
cross-recorder image handoff; not in scope here but worth noting
before any threading refactor.

**Validation without macOS hardware.** Visual comparison in phase 4c
relies on screenshots of native Mac applications that already exist
online or in design references. This is sufficient for the "dark-mode
body text no longer looks anemic" goal but not for pixel-exact
parity. Pixel-exact parity is a non-goal of this plan.

## Validation checkpoints

**After phase 1:**

- `swift build` succeeds with no new warnings.
- `swift test` passes.
- `swift test -Xswiftc -cxx-interoperability-mode=default`
  (the core render/UI package tests) passes.
- Inspection: the per-run metadata on the paragraph handle includes
  `luminanceBucket`. No call site reads it yet.
- Legacy `paragraph->paint()` still produces identical pixels to
  pre-phase-1 output.

**After phase 2:**

- All phase 1 checks still hold.
- `test_glyph_atlas.zig` exists and passes: raster → insert → look up
  → blit round-trips identically.
- No live caller uses the atlas. Production paint path unchanged.

**After phase 3:**

- All phase 2 checks still hold.
- `test_glyph_atlas.zig` asserts bucket-4 entries have higher
  sum-of-alpha than bucket-0 for the same glyph.
- Dilation shader loads at render-server init without error.

**After phase 4:**

- All phase 3 checks still hold.
- `tools/text_render_check/` renders a test scene; output PNG shows
  visibly thicker strokes for white-on-black body text than for
  dark-on-light body text.
- Compositor runs through the topbar bundle without crash or visible
  glyph corruption.
- Frame timing on the test scene shows atlas hits dominate after the
  first frame.

**After phase 5:**

- No remaining call to `paragraph->paint()` for glyph painting (only
  for decorations if still needed).
- Build green; all tests pass.

## Reference patterns

- `src/render_server/texture/texture_atlas.zig` — allocator and
  eviction precedent for the new glyph atlas.
- `src/render_server/shaders/vulkan_stage/*.sksl` and
  `skia_render_bridge.cpp:1142-1180` — SkRuntimeEffect load pattern
  for the dilation shader.
- `src/render_server/skia/skia_render_bridge.cpp` — C ABI pattern for
  exposing render-server C++ state to Zig.
- `src/render_server/skia/skia_text_backend.cpp` — paragraph build and
  paint site that this plan extends.
- Zed PR #54886 — Rec. 709 bucketing formula. The bucketing code in
  phase 1a is the literal Zed formula.
- FreeType `cff:darkening-parameters` documentation — source of the
  magnitude curve in `dilation_table.zig`.
