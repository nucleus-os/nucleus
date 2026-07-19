# Image File Loading

**Invariant: an image is a paint command referencing a refcounted source handle, and
decode is a renderer-side cache keyed by that handle plus the size it is drawn at.**

An image is not layer content. `LayerContent` is `.none`/`.paint`/`.external`/`.snapshot`,
mirrored across three definitions and a wire format; adding an `.image` case would be
four edits to say something `PaintCommand(kind: .image)` already says. Images stay
inside `.paint` layers, and everything below extends the paint path rather than the
layer model.

## What already exists

The pipeline is whole, and this is the correction that resizes this work:

- `ImageStore` (`NucleusRenderModel/RenderImageStore.swift`) refcounts `ImageSource`
  (path + max bounds), dedupes by `"WxH:path"`, and evicts through `onEvict`.
- `SwiftImageRegistrar` implements the `ImageRegistrar` protocol seam; the host bundle
  installs it.
- `FrameDriver.decodedImage(handle:source:)` decodes lazily at rasterization through
  `nucleus.skia.makeEncodedImageFromFile`, caching by handle.
- `PaintRasterizer` draws `.image` commands; `GraphicsContext.draw(_:in:cornerRadius:)`
  emits them; `ImageView` consumes them.
- Skia is built and linked with `libpng`, `libjpeg-turbo`, `libwebp`, `wuffs` (GIF), and
  `skia_enable_svg = true`. `-lsvg` is already on the link line.

**PNG, JPEG, WebP, and BMP decode and draw today.** The gap was never "add a decoder."

## What is actually missing

Four things, and they are independent of each other:

1. ~~**No producer in the shell tier.**~~ *Fixed in phase 2.* The only caller of
   `ImageRegistrar.register` was `ReactImageComponentView`; a `View`-tier consumer could
   not obtain an `ImageHandle` at all.
2. ~~**`maxWidth`/`maxHeight` are dead.**~~ *Fixed in phase 1.* They were stored, and
   deduped on, and then ignored, so a 4K wallpaper and a 22px tray icon decoded
   identically.
3. **SVG is linked but never called.** No `SkSVGDOM` include, no façade.
4. **Decode is synchronous on the render thread.** There is no task queue, no thread
   pool, and no off-main work infrastructure anywhere in `core/swift/Sources`. A
   first-paint wallpaper decode blocks a frame.

## Scope, from the reference

The reference needs PNG, JPEG, WebP, BMP, GIF-still, ICO, SVG at arbitrary target size,
`data:` URI decode, raw-buffer upload with stride and channel order, sRGB-correct
downscale, and threaded decode with main-thread upload.

Three things it needs that are *not* image decode, and do not land here: WebP encode
(thumbnail disk cache), PNG encode (avatar write-back), and an HTTP client (MPRIS
artwork). Artwork resolution produces a local file path; the network layer is a service,
and it belongs beside the other bar services.

**Animated GIF is deferred to first-frame.** It is real — `desktop_sticker_widget` uses
it — but it is one optional widget, the reference ships a first-frame fallback for every
failure mode it has, and its own implementation caps at 512 frames / 96 MiB and uploads
one texture per frame. `DeferredFromEncodedData` already yields frame zero, so the
deferral costs nothing structurally and the widget renders a static sticker until it
lands.

## Phase 1 — honour the decode bounds — **complete**

`makeEncodedImageFromFile` gained `maxWidth`/`maxHeight`, and `FrameDriver.decodedImage`
passes the source's bounds through. The dedupe key is honest now: two handles for one
path at different bounds are two decodes that differ.

A zero bound stays deferred, decoding on first draw exactly as before — nothing is known
about the draw size, so there is nothing to decide. A bounded decode is eager, because
the entire point is never to hold the full-size pixels. Aspect ratio is preserved and an
image already inside the box is never enlarged.

`SkCodec::getScaledDimensions` does the work where the codec can — JPEG scales during the
DCT, which is faster and better than decoding full and resampling. It never returns
smaller than asked, so a resample may still follow.

**Downscaling happens in linear space, by repeated halving.** Two separate defects are
being avoided, and both are visible on exactly the small icons this serves:

- Image bytes are sRGB-encoded, so averaging them directly darkens and muddies the
  result. A black-and-white checkerboard collapses to 128 rather than the correct 188.
- A single large downscale step aliases badly. A linear or cubic filter reads a fixed
  handful of taps regardless of ratio, so shrinking 64× in one step samples a few source
  pixels and discards the rest. Halving until the last step is within 2× means every
  source pixel contributes.

Two findings worth keeping, both of which cost a debugging cycle:

**Skia filters in the source image's colour space and converts to the destination's
afterwards.** A linear destination therefore buys nothing on its own — the averaging has
already happened in sRGB by the time the conversion runs. The source must be converted to
linear first, at full size, as its own step. This is the load-bearing line in
`linearDownscale` and it looks redundant until you know why it is there.

**The decode target must state sRGB rather than inherit it.** An untagged file — most
PNGs, every icon theme — decodes with a null colour space, which Skia reads as "unmanaged"
and skips conversion for, silently defeating the above. Untagged means sRGB, so it is
said explicitly.

`SkImage::scalePixels` is not used, because it does not colour-manage at all: handed an
sRGB source and a linear destination it moves the values across unconverted. Resampling
goes through a raster surface draw instead.

Tests encode their own PNGs (`EncodedImageDecodeTests`) rather than shipping fixtures —
the interesting inputs are pixel patterns chosen to make a resampling defect visible, and
a checked-in binary would hide what it contains. The checkerboard assertion is the one
that would catch a regression to a naive resample.

## Phase 2 — the producer seam — **complete**

`ImageResource` owns one registration for as long as it lives. Registration hands back a
handle at refcount one, so something must own that reference and drop it; making that
something an object whose lifetime *is* the registration's means a view releases by
forgetting. `ImageView.resource` and `sourcePath` both build on it, and assigning over
either drops the previous registration.

Registration is refused without a resource host rather than performed and leaked. The
handle comes from the view's own `backingLayer.context.commitSink`, so a view registers
against the host it will actually draw through.

**`ImageView` registers at its layout size**, deferring until it has one and repeating
when the size it needs changes — the decode bounds are part of a registration's identity,
so a view that grew is a different decode rather than an upscale of the old one.
Re-arranging at the same size is the common case and does not churn the registration.

`contentMode` is `.stretch`/`.contain`/`.cover`, the reference's `FitMode`. The frame stays
authoritative: layout decides how big an image is and the mode decides what happens to the
pixels inside that decision. `cover` clips, because it overflows by construction.

**`imageSize` stays caller-supplied, against the original plan.** The intent was to have an
image know its own size, but nothing on this side of the seam has seen the pixels —
decode happens in the renderer, and registration is deliberately GPU-independent so it
works headless. The alternatives were parsing image headers in the UI tier, which
duplicates what Skia already knows, or blocking on a decode, which defeats the point of
lazy registration. So the aspect-preserving modes fall back to filling the frame when no
size is stated, which is the only honest thing to do without a ratio. The reference
survives this comfortably: it sizes every image from layout and never from file content.
Phase 5 can report a real size back once decode is asynchronous and has somewhere to
report *to*.

**Tint is deferred.** The reference recolours bitmap app icons against the palette with a
CPU desaturate-and-bake, keeping the undecorated source so it can re-bake on a theme
change. `GraphicsContext.draw(image:)` has no tint parameter, so this needs a paint-command
change rather than a view-tier one, and it lands with the raw-buffer work in phase 4 where
pixel-level handling already belongs.

## Phase 3 — SVG

`makeSvgImageFromFile(path, width, height)` in `Graphite.cpp` via `SkSVGDOM`, rasterizing
at the requested size with aspect preserved. Build work is one include path added to the
Linux and Android cxx flags; the library is already linked.

Format detection sniffs the first 256 bytes for `<svg` rather than trusting the
extension, because icon themes ship mislabelled files.

SVG is where decode bounds stop being an optimization and become correctness — a vector
has no natural size, so `maxWidth`/`maxHeight` *are* the size. Phase 1 lands first for
that reason.

## Phase 4 — raw buffers and `data:` URIs

Notifications carry pixels over D-Bus, not paths: width, height, row stride, alpha flag,
and channel order across RGBA/BGRA/ARGB/RGB/BGR. `ImageStore` currently keys on a path,
so a raw source needs a second `ImageSource` kind and a content-hash dedupe key.
`TextureRegistry.uploadShm` is the upload path, and it already takes premultiplied RGBA8888.

`data:` URIs decode to bytes and land in the same raw path.

ICO is hand-rolled here rather than left to Skia, matching the reference: Skia's BMP
codec forces alpha to `0xFF` on 32bpp, so a tray icon decoded through it loses its
transparency.

## Phase 5 — asynchronous decode

The last phase, and the only one that adds infrastructure rather than capability.

Decode moves to a worker off the render thread; completion wakes the frame loop, and
upload stays on the render thread because `TextureRegistry` and `FrameDriver.decodedImages`
are unsynchronized plain classes owned by it. `ImageStore` is `@unchecked Sendable` while
being internally unsynchronized on a single-thread assertion, so registration from a
decode thread is a data race as written and the store gets a real lock as part of this
phase.

Until it lands, a view showing an undecoded image draws nothing for a frame rather than
blocking one. That is the correct interim behaviour and it is also the steady-state
behaviour afterwards.

`GuillotineAllocator`/`TextureAtlas` already exist in `TextureRegistry.swift`, used only
by paint and decoration nodes. Small icons are the case atlasing was built for, and
routing them through it happens alongside this phase.
