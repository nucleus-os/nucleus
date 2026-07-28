# Screen capture: screenshots + recording with region crop

A capability assessment for a macOS-like screenshot (⌘⇧4 — drag a rectangle, capture it)
and screen recorder (⌘⇧5 — drag a rectangle, record it) feature. Written to return to
later. States what already exists in the tree, what's missing, the two ways to build it,
and concrete next steps.

## Bottom line

- **Region screenshots** — ~80% of the pieces already exist. Missing: an interactive
  region-selection overlay, a PNG-encode facade, and plumbing the rect into the request.
  A tractable, mostly-built-in feature.
- **Region recording** — the *capture* half is solved (and the dmabuf GPU-blit path makes
  it efficient), but there is **no video encoder or muxer anywhere in the tree** — that is
  a genuine greenfield subsystem. Either build/embed an encode+mux pipeline, or lean on
  external tools (which the screencopy work already enables).

## What already exists (building blocks)

### Capture (landed in the M2 screencopy work)
- `RouterRenderDriver.captureImpl` (`NucleusCompositorWaylandRuntime/RouterRenderDriver.swift`)
  — the `zwlr_screencopy` capture: **SHM** (readback + region crop) and **dmabuf** (GPU blit
  with full-output or region source rectangles), including optional cursor overlay.
- `RenderCore.beginCaptureOutputBGRA` (asynchronous readback to host BGRA) and
  `RenderCore.beginCaptureOutputToDmabuf` (asynchronous GPU blit into a client dmabuf),
  via Graphite async readback / `ScanoutSurface.wrap` /
  `OutputAccumulator.present` (`nucleus/swift/Sources/NucleusRenderer/render/`).
- `RouterRenderDriver.captureImpl`
  (`NucleusCompositorWaylandRuntime/RouterRenderDriver.swift`) calls the typed
  `CompositorRenderService` capture methods.
- **Region crop works** in both SHM and dma-buf paths.

### Screenshot request model (shell)

The old in-process `NucleusCompositorShell/ScreenshotService` was deleted.
Screenshot orchestration, selection UI, encoding, saving, and clipboard
publication belong in `NucleusShellKit`. Capture remains the render server's
standard `zwlr_screencopy_manager_v1` mechanism negotiated through the
ordinary Wayland registry.

### UI + input foundation for a region picker

The shell owns transient NucleusUI layer surfaces for feedback, menus, and
notifications. A region picker belongs in the same shell surface graph and
uses ordinary window-client input routing; the compositor never draws or
routes picker UI.

### Triggering, clipboard, external-tool support
- Keybinds: server `GlobalBindingResolver` acceptance followed by a typed
  `NucleusSessionProtocol` publication to the shell (the ⌘⇧4/⌘⇧5 analog).
- Clipboard: `DataDevice` (`NucleusCompositorWaylandRuntime/DataDevice.swift`) — an
  `image/png` data source needs wiring for "copy screenshot to clipboard".
- Layer-shell: `ZwlrLayerSurface` exists — so external selector/capture tools (below) can run.

## What's missing

### For built-in region screenshots (small, tractable)
1. **Interactive region-selection surface** — draw the selection rectangle,
   dimmed backdrop, and live dimensions in `NucleusShellKit`; capture pointer
   drag plus Esc/Enter through `NucleusWindowClient`.
2. **PNG-encode facade** — Skia has `SkPngEncoder`, but it isn't exposed through the Graphite
   bridge (`NucleusSkiaGraphite`). Add an encode-to-PNG-bytes method. (Small.)
3. **Plumb the rect** into `ScreenshotService.request` + the `ScreenshotHost` executor
   (readback → crop → PNG → save/clipboard).

### For built-in region recording (large — greenfield)
1. **Video encoder** — none exists (the only "encoder" in the tree is the DRM *KMS* encoder).
   Need hardware VA-API H.264/HEVC/AV1 encode (or software), fed by the per-frame dmabuf blit.
2. **Container muxer** — mp4/mkv writing (or integrate ffmpeg/gstreamer).
3. **Framerate-paced capture loop** — capture a frame per output vblank / target fps into the
   encoder; handle the recording lifecycle (start/stop/pause).
4. (Optional) **audio** — a separate concern (PipeWire); macOS records audio optionally.

## Two ways to build it

### Path A — external tools (idiomatic Linux; already mostly enabled)
Because the compositor now speaks `wlr-screencopy` **and** `wlr-layer-shell`, the standard
tools should work against it once validated on hardware:
- `slurp` draws the region selector (a layer-shell client), `grim` captures + crops + saves
  the PNG → macOS-like **region screenshots** with **no encoder to build**.
- `wf-recorder` / OBS capture via screencopy and encode with their own ffmpeg/VA-API → **region
  recording**, again with no encoder in our tree.
- **Cost:** essentially free from work already done, *modulo on-hardware screencopy
  validation* (the capture is un-headless-tested). This does not give a macOS-*integrated*
  feel (separate apps), but it's the fastest path to the capability.

### Path B — built-in, macOS-integrated (⌘⇧4/⌘⇧5 in the shell)
The shell owns the region picker, encode, save, and clipboard workflow; the
render server owns only capture validation and pixel production.
- **Screenshots:** feasible now — region overlay + PNG facade + wire the rect. A focused,
  mostly-built-in feature.
- **Recording:** still requires building or embedding the encode/mux pipeline (the real
  project). The capture + dmabuf-blit half is done.

## Prerequisites / risks

- **On-hardware screencopy validation** gates everything (the capture path is GPU code,
  un-headless-testable): confirm an actual capture has correct pixels/colors, that the
  `ScreencopyActivity` composition-force works, and that dmabuf import-as-render-target succeeds
  on the target GPU. See the hardware checklist in `followups.md`.
- The recording encoder is the dominant cost and the main decision: build VA-API in-tree vs.
  embed ffmpeg/gstreamer vs. defer to external tools (Path A).

## Suggested order when we return

1. Validate screencopy on hardware (unblocks both paths; already needed).
2. Path A smoke test: run `grim`/`slurp` and `wf-recorder` against the compositor — get the
   capability working end-to-end with zero new code, and shake out screencopy bugs.
3. If a built-in macOS feel is wanted: build the region-selection overlay + PNG facade + wire
   `ScreenshotService` region → **built-in region screenshots** (Path B, screenshots).
4. Recording built-in: scope the encoder (VA-API vs embed) as its own project; the capture
   loop + dmabuf feed is ready for it.
