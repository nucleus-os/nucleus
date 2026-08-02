# View pixel alignment plan

**Status: active.**

**Invariant: layout remains in logical coordinates. Pixel alignment occurs once at the window-to-backing boundary using the destination surface scale; individual views do not independently round layout values.**

## Current disposition

`BackingScaleFactor`, `WindowSurfaceTransform`, and the explicit logical,
surface, output, and backing coordinate vocabulary are implemented. The
remaining Phase 1 work is to make edge-rounding policy part of that boundary.
Local alignment still exists in the RN mount consumer through
`pixelAlignedEnclosing`, so Phases 2 through 4 remain active.

## Phase 1 — Define backing-space conversion

Centralize logical-to-backing point, size, and rectangle conversion on the window/surface context. Specify edge rounding, negative coordinates, fractional scale, and transformed geometry.

## Phase 2 — Align raster-sensitive primitives

Use the centralized conversion for one-device-pixel strokes, separators, image sampling bounds, clip edges, and text raster origins. Preserve logical layout and hit testing.

## Phase 3 — Remove local rounding

Audit NucleusUI, shell widgets, RN mounting, and platform presenters. Delete per-view rounding and scale multiplication that duplicates the boundary conversion.

## Phase 4 — Verify

Add image and geometry tests at integer and fractional scales, including animated transforms and output migration. Profile to ensure alignment adds no per-frame allocation or tree walk.
