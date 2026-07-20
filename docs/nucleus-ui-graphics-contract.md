# NucleusUI graphics contract

## Invariant

Every drawing operation records geometry in view-local logical coordinates and
carries one complete local-to-recording affine transform. The renderer composes
that transform with the backing-pixel scale exactly once. Paths, clips,
gradients, images, text, strokes, and rounded rectangles do not use separate
pre-transformed fast paths.

## Coordinate and numeric model

- Logical drawing space is top-left-origin and y-down.
- Public geometry and path state use `Double`.
- Paint payload geometry narrows to `Float` once when a recording is encoded.
- A paint operation containing NaN, infinity, or a finite value outside the
  representable render range is not recorded.
- A rectangle with either nonpositive dimension is empty. Negative dimensions
  are not implicitly standardized.
- Empty fills and image/text draws do nothing. Clipping to an empty path
  produces an empty clip.
- Stroke widths and corner radii are nonnegative. A non-finite width becomes
  zero; a non-finite radius becomes zero.
- Alpha and image saturation are clamped to `0...1`.

## Transforms, paths, and clips

The current affine transform is snapshotted on each paint or clip command,
including identity transforms. The renderer applies the matrix to the complete
operation. Strokes therefore transform as outlines, circular radial gradients
become ellipses under anisotropic scale, and reflection, rotation, skew, and a
collapsed axis keep their geometric meaning.

An arc uses degrees, with zero on the positive x axis and positive sweep in the
y-down clockwise direction. An arc opens a contour at its real start point,
connects an existing contour to that point, and leaves `currentPoint` at its
real end. A sweep whose magnitude is at least 360 degrees is one complete
ellipse in the sweep direction and returns to the authored start.

Clips intersect the current clip and are scoped by `saveGState` and
`restoreGState`. A command-local clip transform changes the clip geometry
without leaking its transform into later commands.

## Color, gradients, and compositing

Colors are finite floating-point RGBA components clamped to `0...1`. Nucleus
does not currently expose ICC profiles, calibrated color spaces, patterns, or
per-recording color-space conversion. Colors are interpreted in the renderer's
working color space.

Gradient locations are finite, clamped to `0...1`, and sorted before encoding.
Stops at the same location preserve input order and form a deterministic hard
transition. A gradient requires at least two stops. Invalid gradient geometry
or stops fall back to the operation's plain color.

The supported blend modes are source-over, source, multiply, screen, plus,
overlay, destination-in, and destination-out. Unsupported Core Graphics blend
modes are not approximated.

## Recording and raster behavior

`GraphicsContext` records whole-view retained command lists. Graphics state
contains fill and stroke color, alpha, antialiasing, blend mode, line width,
line cap, line join, and affine transform. `withGraphicsState` is the preferred
balanced state scope. A recording automatically balances unmatched saves at
its end.

A view may invalidate a finite local rectangle. The immutable command list
remains complete: localized repaint is a renderer optimization, not a partial
drawing callback contract. For a stable backing size and a recording without
runtime effects, the renderer preserves the previous backing outside the
outward-rounded pixel damage and replays the command list under a clip. It
promotes first paint, resizing, nonlocalizable effects, invalid damage, and
changes to transform, clip, shadow, backdrop, or other composite state to full
repaint or full output-footprint damage.

Images support destination rectangles, uniform local corner radii, optional
alpha-mask tinting, and saturation. Text draws a retained shaped layout
resource. Runtime effects accept finite scalar uniforms and are the explicit
escape hatch for custom shaders.

The API does not claim the full Core Graphics surface. It intentionally omits
PDF contexts, patterns, arbitrary color spaces, path boolean operations,
transparency-layer authoring, and other breadth without a current Nucleus
consumer.
