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

Four things, independent of each other. All four are now closed.

1. ~~**No producer in the shell tier.**~~ *Fixed in phase 2.* The only caller of
   `ImageRegistrar.register` was `ReactImageComponentView`; a `View`-tier consumer could
   not obtain an `ImageHandle` at all.
2. ~~**`maxWidth`/`maxHeight` are dead.**~~ *Fixed in phase 1.* They were stored, and
   deduped on, and then ignored, so a 4K wallpaper and a 22px tray icon decoded
   identically.
3. ~~**SVG is linked but never called.**~~ *Fixed in phase 3.*
4. ~~**Decode is synchronous on the render thread.**~~ *Fixed in phase 5.* There was no
   task queue, no thread pool, and no off-main work infrastructure anywhere in
   `core/swift/Sources`, so a first-paint wallpaper decode blocked a frame.

## Scope, from the reference

The reference needs PNG, JPEG, WebP, BMP, GIF-still, ICO, SVG at arbitrary target size,
`data:` URI decode, raw-buffer upload with stride and channel order, sRGB-correct
downscale, and threaded decode. All of it is in place.

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

## Phase 3 — SVG — **complete**

Rasterization happens behind the *same* entry point as every other image file, rather
than a second façade. A caller does not know or care whether a path is vector — the
resolver hands back whatever the icon theme had — so dispatch belongs where the bytes
are, not in every caller. `FrameDriver` needed no change at all.

Detection is by content: the first 256 bytes are searched for `<svg`. Extensions lie
often enough that a name-based decision renders a blank icon for no visible reason. The
window is searched rather than prefix-tested, because an XML declaration, doctype, or
exporter comment routinely precedes the root element. Matching is case-sensitive, since
XML is — `<SVG>` is not a valid root, and claiming it is would only produce a
parse failure one step later.

Build work turned out to be *zero*: `-I skiaRoot` already covers `modules/svg/include`,
and `-lsvg` was already linked. No new include paths.

Sizing has three cases. Absolute root dimensions give an intrinsic size, and bounds fit
that aspect ratio inside the box exactly as they would for a bitmap. Relative units
("100%") resolve against whatever viewport they are handed, so the bounds are the whole
answer. A document with neither gets `kDefaultSvgRasterSize` — a vector has no natural
size, and something must be chosen.

**The load-bearing detail, found by a failing test:** a document sized in absolute units
has a *fixed* viewport, and `setContainerSize` cannot move it. Scaling the canvas is the
only thing that scales the drawing. Setting the container size alone renders at 1:1 and
crops to the surface — which looks perfectly correct for any art that fills its own
viewport, and silently wrong for everything else. The first version had this bug and the
red-square fixture passed anyway; only an off-centre shape exposed it.

A fontconfig `SkFontMgr` is wired in for `<text>` nodes. Without one Skia renders SVG text
as nothing, silently. Most icons are pure shapes, but a logo or a wallpaper is exactly
where text appears, and fontconfig was already linked. This is the only `SkFontMgr` in the
render tier — text elsewhere goes through the separate text backend.

Rasters are cleared transparent, not opaque: an icon is a shape over whatever is behind it.

## Phase 4 — raw buffers, `data:` URIs, and tint — **complete**

`ImageSource` grew from a path into an `ImageContent` of three cases — `.file`,
`.encoded`, `.raw` — because a `data:` URI and a D-Bus pixel buffer are neither files nor
each other. Dedupe keys off content: a path directly, and an FNV-1a hash otherwise, since
raw pixels have no name and a notification re-sending an unchanged icon on every update
would otherwise register a fresh decode each time.

`PixelChannelOrder` lives in `NucleusAppHostProtocols`, not the render tier: both sides of
the seam speak it, and putting it in the renderer would force every producer to depend on
the renderer merely to name a byte order.

Two details in `RawPixelBuffer` are worth stating because getting either wrong fails
quietly rather than loudly. **Stride is separate from width** — senders pad rows, and
assuming `width * bytesPerPixel` skews every row after the first into a diagonal smear.
And the last row is allowed to omit its padding, because senders routinely truncate there
and rejecting them would reject valid buffers. **Premultiplication rounds** rather than
truncating; truncating loses half a level on every channel of every pixel, which reads as
a uniform darkening of anything semi-transparent. The D-Bus spec sends straight alpha and
the GPU wants premultiplied, so the conversion is not optional.

Raw pixels go to `makeRasterImageRGBA` rather than `TextureRegistry.uploadShm`. The plan
named the upload path, but the decode seam wants an image and that façade already
produces one directly; routing through the registry would allocate a texture handle
nothing asked for.

**ICO is *not* hand-rolled, against the plan.** The reference hand-rolls a decoder because
Skia's BMP codec forces alpha to `0xFF` on 32bpp. A probe against Skia's ICO path here
showed per-pixel alpha surviving exactly — `[0, 64, 255, 128]` in, the same out. So the
decoder is unnecessary, and what landed instead is a test that will notice if that ever
stops being true. This is the second time this plan assumed the reference's workaround was
also ours; it was worth thirty seconds to check.

**Tint** completes the piece deferred from phase 2. It needed no new plumbing: the paint
command already carried `color` and `saturation`, and saturation already lowered to a
colour filter that applies to images. A tint is one flag bit plus a `kSrcIn` blend filter
composed *after* the saturation matrix, so desaturate-then-tint reads in that order — which
is exactly the reference's app-icon bake, expressed as a filter rather than a CPU pass over
the pixels. `ImageView.tint` is a `ColorSpec`, so a tinted icon follows a retheme like
everything else.

No `viewDidChangeEffectiveAppearance` override was needed for that: the base class already
repaints on an appearance change, and the override I first wrote only restated it.

## Phase 5 — asynchronous decode — **complete**

The only phase that adds infrastructure rather than capability. `ImageDecodeQueue` is the
first background thread in the render core, and it is deliberately bare: a worker, a
mutex, and a condition variable. The work is one long CPU job per item with no ordering
between items, which is the shape that wants a queue rather than a scheduler — and there
was no existing threading infrastructure to reuse, because there was none at all.

**Decode happens on the worker; nothing else does.** `TextureRegistry` and the driver's
decoded-image cache are unsynchronized and owned by the render thread, so the worker only
ever produces an immutable image. Completions are adopted at the top of `renderFrame`,
which is the single point the cache is written — that is what keeps leaving it
unsynchronized correct rather than merely lucky.

A `DecodedImageResult` carries the Skia image itself, not a pixel array. A raster
`SkImage` is immutable once made and its refcount is atomic, so passing one between
threads is sound; the alternative costs two full-resolution copies of every wallpaper, one
to read the pixels out and one to rebuild the image.

**`ImageStore` did not need a lock, against the plan.** The store is read on the render
thread and the resulting `ImageSource` — a `Sendable` value — is copied into the request at
submit time. The worker never touches the store. The plan assumed a shared-store design
that the actual seam does not have.

Three behaviours that keep this from being subtly wrong:

- **A pending handle is refused re-submission.** A decode in flight draws nothing, so the
  caller asks again on every subsequent frame; without this the queue fills with
  duplicates of the same work.
- **Eviction cancels, and cancellation drops the result on arrival.** A decode already
  running cannot be stopped. Dropping matters more than stopping: the handle may be
  re-registered against a different source, and delivering the stale image would draw the
  wrong picture.
- **Completion notifies.** Nothing else schedules a frame when a decode lands — the scene
  did not change, the image simply arrived — so without the callback the result waits for
  an unrelated repaint. The compositor wires this to its frame request.

Shutdown joins the workers rather than only signalling them, because they decode against a
Graphite context that must outlive them. If a thread cannot be spawned at all, `submit`
refuses and the caller decodes inline, which is exactly the behaviour that existed before
this phase.

Atlasing small icons through the existing `GuillotineAllocator`/`TextureAtlas` did **not**
land here. It is a memory optimization with no correctness content, it is unmeasured, and
bundling it into the phase that introduces threading would have made both harder to reason
about. It stays available for when there is a measurement to justify it.

## What remains

Nothing in this plan. The image pipeline handles files, in-memory blobs, and raw buffers;
decodes PNG, JPEG, WebP, BMP, ICO, GIF-still and SVG; honours bounds with sRGB-correct
downscaling; tints and desaturates; and decodes off the render thread.

Two deliberate deferrals stand, both recorded above with their reasoning: **animated GIF**
renders its first frame, and **image atlasing** awaits a measurement. Neither blocks the
port.
