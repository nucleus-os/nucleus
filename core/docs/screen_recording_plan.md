# Native Screen Capture & Recording — Architecture Plan

> **Historical substrate.** Written in the pre-migration Zig terms (`.zig` paths,
> `zig build`, `src/…`). The compositor/render code is now Swift + C++ interop; the
> capture design stands, but read specific paths and build commands as historical —
> see `docs/README.md` for the Zig→Swift mapping.

## Goals

Two goals, supported by one engine:

1. **In-house recording subsystem** — a ScreenCaptureKit-modeled engine in Zig, Vulkan Video hardware encoder, fragmented-MP4 muxer in Zig, and (eventually) RN-rendered picker UI. This is the path Nucleus's own recording feature uses; no external tooling required.
2. **Broad compatibility with the existing Linux screen-capture / streaming ecosystem.** Every tool a user is likely to reach for must work: `grim`, `slurp`, `wf-recorder`, OBS Studio (every common configuration), `kooha`, `gpu-screen-recorder`, `wl-recorder`, plus browser / Electron screencast (Chrome, Firefox, Discord, Zoom, Slack, Teams). Nucleus is not in a position to wait for the ecosystem to migrate; the protocols clients use *today* are the protocols we ship.

Both goals share one capture engine; the protocol surfaces sit as thin adapters over it.

## Context

Nucleus has no native capture infrastructure today. No screencopy protocols are implemented, no encoder is linked, no D-Bus portal integration exists, and the persistent framebuffer (the Vulkan `VkImage` that holds every composited frame) is not accessible to capture consumers. The only readback path is `src/compositor/screenshot_pipeline.zig`, which is single-shot, CPU-bound, and PNG-targeted.

The target is a first-class capture subsystem spanning:

- ScreenCaptureKit-modeled core engine in Zig (`SCShareableContent`, `SCContentFilter`, `SCStreamConfiguration`, `SCStream`, `SCStreamOutput`) that admits future UI, RN bindings, and encoder integrations
- Zero-copy GPU tap from the existing compositor composition pipeline (persistent framebuffer) — capture pays nothing when inactive
- Full Wayland protocol coverage for capture clients:
  - **Modern path:** `ext-image-capture-source-v1` family + `ext-image-copy-capture-v1` (OBS ≥ 31, wf-recorder ≥ 0.4, future tools)
  - **Widely-deployed path:** `wlr-screencopy-unstable-v1` (grim, slurp+grim, current wf-recorder builds, OBS via xdg-desktop-portal-wlr, kooha)
  - **Zero-copy legacy:** `wlr-export-dmabuf-unstable-v1` (OBS GPU-zero-copy configs, gpu-screen-recorder)
- `xdg-desktop-portal` ScreenCast backend + PipeWire producer node — the path Chrome / Firefox / Discord / Zoom / Slack / Electron use
- Window enumeration via `ext-foreign-toplevel-list-v1` (modern) and `wlr-foreign-toplevel-management-v1` (legacy, what current taskbars and screen-share pickers actually call)
- Native Vulkan Video encoder consumer + minimal fragmented-MP4 muxer for the built-in "record to file" path (keyboard trigger acceptable for V1)
- Per-window capture via compositor-managed re-compose so captures are pixel-identical to what the user sees (decorations, shadows, blur, subsurfaces all included)

No user-visible picker UI is required for the initial implementation; architecture must admit one cleanly.

## Design principles

1. **Zig core, adapter layers above it.** One `SCStreamEngine` owns capture state. Every external surface (each Wayland protocol handler, the xdg-desktop-portal D-Bus service, the PipeWire producer node, the internal encoder, the future RN Nitro HybridObject, the future overlay indicator) is a thin adapter that translates in/out of the engine's API. **No parallel capture pipelines.**
2. **Multiple protocols, one engine.** Supporting both the modern `ext-*` family and the widely-deployed `wlr-*` family is not "parallel paths" — both are adapters over the same engine, the same way the Wayland and portal paths coexist. The forbidden shape is two engines; multiple adapters that converge on one engine is the correct shape.
3. **Apple `SC*` naming, exact prefixes** for the core engine types. Consistent with existing `CA*` / `CG*` naming in-tree per `feedback_apple_naming`. New module lives under `src/compositor/capture/`.
4. **Zero-copy is the default.** Captured frames live in DMA-BUF-backed Vulkan textures (`VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT`) exportable directly to PipeWire, Wayland clients (when they request DMA-BUF), and the Vulkan Video encoder (same device, FD never leaves). CPU readback exists as a fallback for SHM clients and debug consumers only.
5. **Single capture tap point in the frame pipeline.** The engine reads from `persistent` once per frame per source. All consumers (every stream, every protocol, PipeWire, encoder) are fed from that one coherent composited view.
6. **Cutting-edge for *our* code; pragmatic for *ecosystem* code.** In-tree implementation choices (Vulkan Video encode over VAAPI; Vulkan-native readback over CPU staging; etc.) follow `feedback_cutting_edge`. The choice of which Wayland protocols to *expose* follows ecosystem reality — wlr protocols are old but ubiquitous, and the cost of carrying their adapters is small compared to the cost of telling users "your tool doesn't work, file a bug upstream."
7. **No compat shims** still applies to *encoder* choices, *transport* choices, and the *core engine itself*. It does not extend to refusing to speak protocols clients are actually written for.
8. **Capture pays nothing when inactive.** Per-output and per-window refcounts gate all capture work; zero extra GPU submissions on the inactive path.

## Type model (`src/compositor/capture/`)

Apple names, mapped 1:1:

| SC type | Role | Nucleus backing |
|---|---|---|
| `SCShareableContent` | Snapshot of available sources | Pulls from `LiveDrmOutputs` + `LiveWindowedOutputs` + `WindowServer.windows()` |
| `SCDisplay` | One capturable output | Holds `*DrmOutput` or `*WindowedOutput` + stable `CGDirectDisplayID` |
| `SCWindow` | One capturable toplevel | Holds `*Window` + stable window id |
| `SCContentFilter` | Which sources to include / exclude | Inclusive (display + window list) or exclusive (display minus N apps) forms |
| `SCStreamConfiguration` | Capture parameters | Pixel format, minimum frame interval, source crop rect, `includes_cursor`, `scale_to_fit`, destination `width`/`height`, destination DMA-BUF modifier preferences |
| `SCStream` | Active session | Filter + config + output; owns double-buffered destination `Texture`s (DMA-BUF-backed), tracks semaphore chain, drives per-output / per-window refcounts |
| `SCStreamOutput` | Delegate/consumer vtable | `onFrame(stream, *SCFrame)`, `onError(stream, err)`, `onStop(stream)` |
| `SCFrame` | Delivered frame | `texture: *Texture`, `presentation_timestamp_ns: u64`, `source_id`, `damage: []Rect`, ref-counted (`retain`/`release`) |

`SCStreamEngine` lives on the render server thread. It owns:
- Set of active `SCStream` values keyed by source
- Per-output "software cursor required" refcount (phase 2 policy)
- Per-output "suppress direct scanout" refcount (ensures persistent is authoritative while capturing)
- Per-window "capture redirect active" refcount (phase 4)
- Per-consumer-type adapter handles (PipeWire nodes, encoder sessions, etc.)

## Frame pipeline integration

### Display capture — single tap in `PresentationRenderer.endFrame`

In `PresentationRenderer.endFrame()` (`src/compositor/PresentationRenderer.zig:302`), after compose submit (line 378) and before present pass open (line 383):

```
compose submit  (persistent layout = .general, contains full composited frame)
      ↓
NEW: engine.captureDisplayForOutput(output_texture, timestamp, damage)
       for each SCStream on this output:
         GPU copy persistent → stream.next_destination_texture
         wait on compose signal, signal stream capture fence
         optional cursor composite (phase 2)
         hand SCFrame to SCStreamOutput
      ↓
present pass   (reads persistent into scanout, transitions to .shader_read_only_optimal)
      ↓
backend.endFrame()
```

Why here:
- Persistent is `.general` and contains the full composited frame (`persistent_post_compose_vk_image_layout`, `ComposePass.zig:105`)
- Skia's compose-submit semaphore is available for the capture copy to wait on
- The present pass only reads persistent, so it runs concurrent with the capture copy on the graphics queue

### Direct-scanout suppression while capturing

Direct scanout (`DrmOutput.zig:1019–1193`) bypasses persistent. When any stream is active on an output, `tryDirectScanout` consults the engine's per-output refcount and returns `.block` (forcing composed scanout) for as long as capture is active. Persistent therefore always reflects the screen. The cost applies only while capture is active.

### Window capture — per-window re-compose

Source-buffer-only window capture (read `wl_surface.current.buffer` directly) is broken in practice: it misses subsurfaces (video overlays, tooltips), compositor decorations, shadows, and blur backdrops, and never includes the cursor. The correct architecture is per-window re-compose, adding a redirected-texture / presentation-texture mechanism to `Window` (`src/compositor/Window.zig`):

1. Engine increments window's capture-redirect refcount on stream start
2. `PresentationRenderer.emitCaTree` detects the refcount, opens a texture pass (`ComposePass.beginTexturePass`, `ComposePass.zig:538`) targeting a per-window IOSurface
3. Window's CA subtree (main surface + subsurfaces + popups + decorations + backdrop blur) renders into that IOSurface
4. Texture pass ends; the IOSurface is composited back into persistent for scanout as usual
5. Engine taps the window's IOSurface directly — it is the capture source

Result: pixel-identical captures regardless of how the window is composed. Works uniformly for xdg-shell, layer-shell, xwayland. Cost: one intermediate texture per captured window per frame, paid only while captured.

### Cursor policy — composite-into-capture (policy B)

Today the cursor is on a DRM hardware cursor plane and never in persistent. Forcing software cursor globally would regress system-wide cursor latency while capturing. The correct long-term policy is to keep the HW cursor untouched and composite the cursor image into the capture destination in the same Skia recorder that performs the capture copy. Per-stream `includes_cursor` flag (default `true`, matching macOS); when multiple streams target the same output with different settings, each already has its own capture copy, so cursor inclusion is just a per-stream flag.

## Consumer adapters

The engine produces frames; adapters deliver them. V1 ships **six** adapter types — three Wayland-native (covering both modern and legacy clients), one portal-bridge, one in-process encoder, one debug.

### 1. `ext-image-copy-capture-v1` Wayland adapter (modern)

Thin handler modules in `src/compositor/wayland/`. Each protocol resource holds Wayland state only; all work flows through the engine.

Protocols:
- `ext-image-capture-source-v1` — base source protocol
- `ext-output-image-capture-source-v1` — `wl_output` → capture source
- `ext-foreign-toplevel-image-capture-source-v1` — toplevel → capture source
- `ext-image-copy-capture-v1` — transport (client provides `wl_buffer`, compositor fills it)

Buffer-target delivery path: client-supplied `wl_buffer` (SHM or DMA-BUF) is imported as a transient `Texture`, engine routes the capture copy directly into it.

Consumers: OBS Studio (31+), wf-recorder (0.4+), and the migrating frontier of capture tools.

### 2. `wlr-screencopy-unstable-v1` Wayland adapter (widely deployed)

Same shape as adapter 1 — a thin handler over the engine. Distinct protocol surface, identical engine path.

Protocols:
- `zwlr_screencopy_manager_v1` — `capture_output(frame, overlay_cursor, output)` and `capture_output_region(frame, overlay_cursor, output, x, y, w, h)`
- `zwlr_screencopy_frame_v1` — emits `buffer`, `linux_dmabuf`, `buffer_done`, accepts `copy(buffer)` or `copy_with_damage(buffer)`, emits `flags` + `ready` (or `failed`)

Consumers: `grim`, `slurp` (when piped to `grim`), current builds of `wf-recorder`, `kooha`, `swappy`, OBS via xdg-desktop-portal-wlr, screenshot widgets in third-party shells. This is the protocol that *just works* for most users today.

`with_damage` variant: same engine path; the adapter feeds damage rects from `SCFrame.damage`.

### 3. `wlr-export-dmabuf-unstable-v1` Wayland adapter (zero-copy legacy)

A small adapter (~250 lines) covering the export-dmabuf protocol that GPU-zero-copy OBS configurations and `gpu-screen-recorder` were historically built against. Lower priority than adapters 1/2 — most clients have moved to screencopy + DMA-BUF buffers — but cheap to add and unblocks specific OBS workflows.

Protocols:
- `zwlr_export_dmabuf_manager_v1` — `capture_output(frame, overlay_cursor, output)`
- `zwlr_export_dmabuf_frame_v1` — emits `frame`, `object`, `ready` (or `cancel`)

Implementation: the engine's destination textures are already DMA-BUF-backed; this adapter exports the FD and describes it to the client. No extra GPU work.

### 4. Foreign-toplevel enumeration (window listing)

Window capture (Wayland-native and portal alike) needs a way for clients to discover capturable toplevels. Two protocols carry this:

- `ext-foreign-toplevel-list-v1` — modern enumeration; emits `toplevel`, `app_id`, `title`, `done`, `closed` events. Used by `ext-foreign-toplevel-image-capture-source-v1`.
- `wlr-foreign-toplevel-management-v1` — older enumeration plus management (activate / close / set-fullscreen). Used by every current taskbar (waybar, etc.) *and* by the screen-share window pickers in many tools.

Both land. The management-v1 protocol overlaps with future taskbar concerns; that's fine — same data, different consumers. Window-state hooks already exist in `WindowServer` for the management protocol's lifecycle events.

### 5. `xdg-desktop-portal` ScreenCast backend + PipeWire

This is the path Chrome, Firefox, Discord, Zoom, Slack, Electron, Teams all use.

**Portal service** — Nucleus implements the `org.freedesktop.impl.portal.ScreenCast` backend interface on D-Bus. Service bus name `org.freedesktop.impl.portal.desktop.nucleus`, following the standard backend naming convention (`gnome`, `kde`, `wlr`, etc.). The front-end `xdg-desktop-portal` daemon (provided by the distro) routes `org.freedesktop.portal.ScreenCast` client calls to our backend.

Portal flow:
1. Client calls `CreateSession` → backend creates a session handle + pending `SCContentFilter`
2. Client calls `SelectSources` with types (MONITOR/WINDOW), multiple bit, cursor mode (hidden/embedded/metadata)
3. Backend currently defaults to "first available display, cursor embedded" with no consent dialog (V1 is trusted-local-clients only; consent UI slots in later, alongside the RN capture picker). The session remembers the request for later.
4. Client calls `Start` → backend creates PipeWire producer node, creates `SCStream` targeting the selected source, delivers PipeWire node id in the response
5. Client connects to the PipeWire node id, negotiates format + modifier
6. Each captured frame: `SCStreamOutput` for this session pushes the DMA-BUF FD + metadata into the PipeWire node buffer queue; PipeWire hands it to the client

**PipeWire integration** — Nucleus connects to the user's PipeWire daemon as a client (`pw_context_connect`), creates producer nodes (`pw_stream` in direction=output) advertising `video/x-raw` with DMA-BUF memtype. Each frame: `pw_stream_dequeue_buffer`, fill DMA-BUF descriptor from the `SCFrame`'s exported FD, `pw_stream_queue_buffer`. PipeWire handles client-side buffer lifecycle.

Zero-copy end-to-end: `SCFrame.texture` (Vulkan + DMA-BUF) → FD exported once at stream start → PipeWire describes it via `SPA_DATA_DmaBuf` → client imports directly into its own GPU (Chrome/Firefox GPU process uses DMA-BUF directly; Electron follows Chrome's path).

**D-Bus transport** — Nucleus already pumps a shell D-Bus connection (`server.pumpShellDbus()`, main loop). The portal backend registers additional objects on the session bus. Library: sd-bus (already linked via `dbus_bridge.zig`).

**PipeWire dependency** — `pipewire` + `libspa-0.2` added to the dev shell. The C headers are bound through a SwiftPM `.systemLibrary` C target (`pkgConfig: "libpipewire-0.3"`) with a module map that pulls in `<pipewire/pipewire.h>` — the same shape as the existing `NucleusCompositorDrmC` / `NucleusCompositorSystemdC` C façades in `compositor-core/Package.swift`. If PipeWire's headers need pre-processing before Swift's clang importer can consume them cleanly, a small first-party C shim target wraps them instead.

**Format negotiation** — PipeWire's format-fixation callback fires once per stream. The backend advertises BGRA8888 + linear / DMA-BUF modifier list from the Vulkan runtime, converges on one, allocates `SCStream` destination textures to match. Single-format (BGRA) is sufficient for all current portal clients (Chrome/Firefox/Electron convert to YUV internally from whatever the compositor provides).

**Cursor mode** — portal distinguishes HIDDEN / EMBEDDED / METADATA. EMBEDDED maps to `SCStreamConfiguration.includes_cursor = true` (cursor drawn into the pixels). METADATA requires a sidecar metadata plane and is deferred — V1 advertises HIDDEN + EMBEDDED only.

### 6. Vulkan Video encoder + fMP4 muxer (internal recording)

Native recording path — no external tooling needed. Keyboard-triggered in V1 (no UI), writes to a fixed filename under `$XDG_VIDEOS_DIR`.

**Encoder** — `VK_KHR_video_encode_queue` + `VK_KHR_video_encode_h264` (and `h265` where supported). Hardware encode on the same Vulkan device that runs the compositor — no FD roundtrip, no queue transfer across devices. The encode queue takes an NV12 or P010 input texture; the engine exposes a BGRA → NV12 compute shader pass that runs on the graphics queue and signals the encode queue's wait semaphore.

**Muxer** — Minimal fragmented-MP4 writer in pure Zig. Fragmented MP4 allows streaming (write a `moof`/`mdat` pair per GOP, `mvex` + empty `mdat` seed at file start) and crash-safe recording (partial files play up to the last flushed fragment). Scope is intentionally narrow: H.264/H.265 video only, one track, no audio (audio is phase 11). No `ffmpeg` / `libavformat` dependency.

**Hardware support** — Vulkan Video encode support varies by driver: Nvidia proprietary is full, Mesa RADV (AMD) and Anv (Intel) coverage has been advancing through Mesa releases. The three vendors Nucleus already runs on are all in scope. Per `feedback_cutting_edge` we accept current-driver patchiness as the right long-term bet. A VAAPI fallback path is explicitly **not** added — if a driver lacks Vulkan Video encode, recording is unavailable on that host until the driver catches up. This avoids a legacy parallel path.

**Trigger** — Keyboard shortcut (handled alongside existing hotkey infrastructure). Start creates `SCStream` on the focused display with default config, wires it to the encoder `SCStreamOutput`, opens the output MP4. Second press stops, flushes, closes.

### 7. Internal test consumer (CPU readback)

A debug `SCStreamOutput` that blits persistent into a host-coherent staging buffer (reusing `screenshot_pipeline` patterns), drops the pixels, logs delivery count + format + timestamp. Used for engine validation throughout phase 1.

## Audio capture (phase 13, last)

Screen-sharing in Discord/Zoom/Chrome expects audio. Sketch for completeness; implementation is intentionally last because it shares no GPU pipeline with video:

- **Desktop audio** — PipeWire monitor source on the user's output sink; Nucleus' portal backend requests a monitor node and forwards its node id alongside the video node in the portal `Start` reply (portal spec allows both)
- **Microphone** — Standard PipeWire capture source; same portal reply mechanism
- **Encoder pairing** — When internal recording is active, audio frames route through Opus or AAC encode (in-tree Zig Opus encoder, or add the host libopus development package) and muxed alongside video in the fMP4 writer

**Cross-cutting consumer:** the `AudioAdapter` infrastructure built here is reused by the future live-captions feature per `docs/compositor-accessibility-direction.md`. Live captions consumes the same PipeWire monitor-source / microphone capture paths and feeds frames to a speech-to-text pipeline (whisper.cpp) instead of an encoder. Build `AudioAdapter` with that second consumer in mind: don't bake encoder-specific assumptions into the capture path; keep the `SCAudioFrame` shape generic enough that a non-encoder consumer can subscribe without refactoring.

## What multiple protocols share, what they don't

All seven Wayland-side capture protocols (the three ext-* sources, ext-image-copy-capture, the three wlr-* protocols, foreign-toplevel-list, foreign-toplevel-management) share:

- The **same `SCStream`** instances (one stream per (source, client-buffer-pool); the protocol surface determines how buffers are supplied)
- The **same capture tap** in `PresentationRenderer.endFrame`
- The **same DMA-BUF-backed destination textures**
- The **same per-output / per-window refcounts**
- The **same direct-scanout suppression**
- The **same cursor compositing policy**

What differs between adapters: how the client provides buffers, what events the protocol emits, what the lifecycle handshake looks like. That's it. Each adapter is < 500 lines, mostly request-handler dispatch.

## Intentionally skipped

After the rewrite, the skip list is much smaller:

- **VAAPI encoder** — supplanted by Vulkan Video; adding VAAPI would be the legacy parallel path `feedback_no_compat_shims` rejects
- **libavformat / ffmpeg** — heavy dep that buys us less than a 300-line fMP4 writer
- **GStreamer pipelines** — not used by any of the target clients on the screencast path

Notably **not** skipped (changed from the prior version of this plan):
- `wlr-screencopy-unstable-v1` — ecosystem reality dictates inclusion
- `wlr-export-dmabuf-unstable-v1` — cheap adapter, real OBS configs use it
- `wlr-foreign-toplevel-management-v1` — current shells and screen-share pickers depend on it; the older protocol is also broader (it adds activate / close)

## io_uring integration

- **Compositor-synchronous consumers** (Wayland protocol adapters, internal debug consumer) need no new fd; they run in the existing render-server / wayland-server thread cadence
- **PipeWire** — `pw_loop` exposes an epoll fd via `pw_loop_get_fd`. Register as a new `UringTag` variant `.pipewire`, multi-shot poll, dispatch via `pw_loop_iterate`
- **D-Bus portal backend** — sd-bus exposes a pollable fd (`sd_bus_get_fd`). Register as `UringTag.portal`, multi-shot, dispatch pending messages each wake
- **Encoder output** — Vulkan encode completion is signaled via semaphore → fence → eventfd (same pattern as `screenshot_pipeline`'s eventfd signaling). Register as `UringTag.encoder`

Threading model: engine + frame production on render server thread; PipeWire buffer queueing on render thread too (PipeWire is thread-safe for `pw_stream_queue_buffer`); D-Bus portal dispatch on main compositor thread (request-response handoff to engine via lock-free mailbox); encoder on its own thread waiting on Vulkan fences (mirrors screenshot pipeline).

## Future UI slots (designed in, not built in V1)

- **Recording indicator overlay** — `ShellServices` exposes `anyCaptureActive` signal; native Zig + Skia overlay (same pipeline as notifications per `project_render_server_zig`) renders an indicator in the menu-bar region
- **Portal consent dialog** — Native Zig Skia overlay showing source picker + consent before the portal backend responds to `SelectSources`. V1 uses silent default; the plan leaves a single callback point (`engine.requestPortalConsent(session, cb)`) for the dialog to slot in
- **RN capture picker** — Nitro HybridObject wrapping `SCShareableContent` + `SCStream`. Shape mirrors macOS `SCContentSharingPicker`. Slots in when RN-compositor integration lands
- **In-compositor recording trigger** — Keyboard-first V1; future menu-bar button or dock icon controlling the same internal recording `SCStream`

## Phased implementation

Strictly sequential — each phase lands and is verified in isolation before the next starts, per `feedback_isolate_arch_bets`.

### Phase 1 — Engine skeleton + display capture + debug consumer

- Create `src/compositor/capture/` with `SCShareableContent.zig`, `SCContentFilter.zig`, `SCStreamConfiguration.zig`, `SCStream.zig`, `SCStreamOutput.zig`, `SCFrame.zig`, `SCStreamEngine.zig`
- Wire `SCDisplay` descriptors to `DrmOutput` / `WindowedOutput` lifecycle (add/remove on hotplug)
- Add `engine.captureDisplayForOutput()` call in `PresentationRenderer.endFrame()` between compose submit (line 378) and present pass open (line 383)
- Extend `VulkanCompositorBackend` with `captureToStreamTarget(stream_texture, timestamp, cursor_overlay: ?CursorDesc)` — GPU copy from persistent into a caller-provided DMA-BUF-backed `Texture`, waiting on compose signal and signaling per-capture fence. Cursor param is a no-op in phase 1; wired in phase 2.
- Destination `Texture` allocation: extend `VulkanCompositorBackend` to allocate with `VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT` and export FD on request
- Add per-output "suppress direct scanout" refcount; `tryDirectScanout` (`DrmOutput.zig:1019`) returns `.block` when > 0
- Instantiate engine alongside existing shell services in `src/compositor/main.zig`
- Ship with one consumer: in-tree `DebugCaptureOutput` that blits frames to CPU staging and logs delivery — validates end-to-end with no protocol work
- Verification: attach `DebugCaptureOutput` to primary output at compositor start; confirm frames arrive at output refresh rate; confirm no regressions in non-capturing frames (direct scanout path still active when zero streams)

### Phase 2 — Cursor compositing (policy B)

- Extend the capture copy submission with an optional cursor overlay draw in the same Skia recorder performing the copy
- Cursor image + position sourced from existing `DrmOutput.cursor_buf` state
- Per-stream `includes_cursor` flag default `true`
- Verification: capture with/without cursor; HW cursor plane stays active on display; cursor present/absent in captured pixels as expected

### Phase 3 — `wlr-screencopy-unstable-v1` adapter (display)

The widely-deployed adapter lands first because it unblocks the largest set of tools (grim, slurp+grim, current wf-recorder, kooha) with the smallest additional work — the engine already does everything; this adapter is just request handling + buffer import.

- Vendor `wlr-screencopy-unstable-v1.xml` into `third-party/protocols/` (not in upstream wayland-protocols)
- Add it to the `NucleusCompositorGenerateWaylandC` plugin's protocol list and regenerate the committed Wayland C bindings
- `src/compositor/wayland/wlr_screencopy.zig` — manager + frame objects; SHM and DMA-BUF buffer import; drives `SCStream` via engine
- Register globals in `WaylandServer.initProtocolGlobals()`
- Verification: `grim primary.png` produces a correct screenshot; `wf-recorder -o primary.mp4` records primary output; SHM and DMA-BUF paths both work

### Phase 4 — `ext-image-copy-capture-v1` adapter (display)

The modern adapter, landing alongside the legacy one so newer client builds get the standardized path.

- Add `ext-image-capture-source-v1`, `ext-output-image-capture-source-v1`, `ext-image-copy-capture-v1` to the `NucleusCompositorGenerateWaylandC` plugin's protocol list and regenerate (window-side protocols to phase 7)
- `src/compositor/wayland/image_capture_source.zig` — base capture source
- `src/compositor/wayland/output_image_capture_source.zig` — `wl_output` → source
- `src/compositor/wayland/image_copy_capture.zig` — manager + session + frame objects; negotiates buffer formats, imports client buffers (SHM + DMA-BUF), drives `SCStream` via engine
- Register globals in `WaylandServer.initProtocolGlobals()`
- Verification: a current OBS Studio build configured for "ext-image-copy-capture" records primary output; pixels match screen; DMA-BUF and SHM paths both work

### Phase 5 — `wlr-export-dmabuf-unstable-v1` adapter

Small follow-up adapter for GPU-zero-copy OBS configurations and `gpu-screen-recorder`.

- Vendor `wlr-export-dmabuf-unstable-v1.xml` into `third-party/protocols/`
- Add it to the `NucleusCompositorGenerateWaylandC` plugin's protocol list and regenerate the Wayland C bindings
- `src/compositor/wayland/wlr_export_dmabuf.zig` — manager + frame objects; exports `SCStream` destination texture's DMA-BUF FD per frame
- Verification: OBS configured for "Wayland (DMA-BUF)" capture source records primary output zero-copy; `gpu-screen-recorder -w screen` records correctly

### Phase 6 — Per-window capture redirect

- Add `capture_refcount: u32` and `capture_target_iosurface: ?*IOSurface` to `Window`
- Engine increments refcount on stream start targeting a window
- `PresentationRenderer.emitCaTree` branches when refcount > 0: open texture pass → render window subtree → close pass → composite back into persistent for scanout
- `SCWindow` streams tap the window's `capture_target_iosurface` directly, frame-synced with the window's compose cycle
- Verification: internal test consumer on a window produces pixels including all subsurfaces, decorations, shadows; same window's display-level capture shows same content

### Phase 7 — Window enumeration + window-capture protocols

Both foreign-toplevel-list variants land, plus the window-capture sides of phases 3/4.

- `src/compositor/wayland/ext_foreign_toplevel_list.zig` — modern enumeration
- `src/compositor/wayland/wlr_foreign_toplevel_management.zig` — legacy enumeration + management (activate / close / set-fullscreen / set-maximized)
- `src/compositor/wayland/ext_foreign_toplevel_image_capture_source.zig` — toplevel handle → ext-capture source
- Extend `wlr_screencopy.zig` with `capture_toplevel(frame, overlay_cursor, toplevel)` once `wlr-screencopy-unstable-v1` toplevel variants are exposed (the protocol supports it via the manager's later version)
- Verification: waybar enumerates toplevels via foreign-toplevel-management; OBS window-source picker enumerates toplevels via foreign-toplevel-list; capturing an individual window in either path produces correct pixels including subsurfaces

### Phase 8 — PipeWire producer node infrastructure

- Add `pipewire` + `libspa-0.2` to the documented host prerequisites
- Add the PipeWire `.systemLibrary` C target + module map to `compositor-core/Package.swift` (per the **PipeWire dependency** note above), or a small C shim target if the headers need pre-processing
- `src/compositor/capture/PipeWireAdapter.zig` — owns `pw_thread_loop` or threaded `pw_loop` connected to the user's PipeWire daemon; creates/destroys producer nodes (`pw_stream`) on `SCStream` start/stop
- `src/compositor/capture/SCStreamOutputPipeWire.zig` — implements `SCStreamOutput` by pushing DMA-BUF descriptors into the producer node's buffer queue
- Format negotiation callback wires PipeWire's chosen format back into `SCStream` destination texture allocation
- io_uring integration: new `UringTag.pipewire`, multi-shot poll on `pw_loop_get_fd`, dispatches `pw_loop_iterate`
- Verification: a test program using raw `pw_stream` API connects to the node, receives DMA-BUF buffers, maps them into a local OpenGL/Vulkan context; pixels match what's on screen

### Phase 9 — xdg-desktop-portal ScreenCast backend

- `src/compositor/capture/PortalBackend.zig` — registers `org.freedesktop.impl.portal.desktop.nucleus` on session bus
- Implements `org.freedesktop.portal.impl.ScreenCast` interface (CreateSession, SelectSources, Start, Version, AvailableSourceTypes, AvailableCursorModes)
- Each session: holds selected filter, cursor mode, creates PipeWire producer node on Start, routes node id back to frontend
- Internal `SCStream` lifecycle driven by portal session lifecycle (close session → stop stream)
- io_uring integration: new `UringTag.portal`, multi-shot poll on sd-bus fd, dispatches message pump
- Default consent = auto-approve (trusted local clients only in V1); `engine.requestPortalConsent` callback slot left for future UI
- Ship `org.freedesktop.impl.portal.desktop.nucleus.service` + `nucleus.portal` config file alongside the compositor binary (install path: `$out/share/xdg-desktop-portal/` per spec)
- Verification: start Chrome / Firefox / a test WebRTC app; `getDisplayMedia()` returns a stream; video plays showing Nucleus desktop content; `libpw-monitor` confirms DMA-BUF transport

### Phase 10 — Multi-stream coalescing

- Engine allocates a shared per-source intermediate `Texture` when stream count on that source > 1
- Per-stream destination textures populated from the intermediate via scale/crop draws
- Verification: two concurrent capture clients on same output; GPU trace shows one `persistent → intermediate` copy per frame plus one `intermediate → destination` per stream, not two full copies

### Phase 11 — Recording indicator overlay

- `ShellServices` gains `anyCaptureActive() bool` + change event
- Native Zig + Skia overlay reflecting the signal, positioned in menu-bar region
- Internal `SCStreamOutput` (no pixels, activity-signal only) registered globally to keep indicator fed
- Verification: starting any stream (any Wayland adapter, portal, internal) lights the indicator; stopping all streams clears it

### Phase 12 — Vulkan Video encoder + fMP4 muxer + keyboard-triggered recording

- `src/compositor/capture/VideoEncoder.zig` — owns Vulkan Video encode queue, H.264 encode pipeline (+ H.265 if available), semaphore chain from graphics to encode queue
- `src/compositor/capture/ColorConvert.zig` — BGRA → NV12 compute shader pass (graphics queue), runs between capture copy and encode submit
- `src/compositor/capture/Fmp4Muxer.zig` — minimal fragmented-MP4 writer in Zig (ftyp + moov-mvex seed, per-GOP moof+mdat fragments, no audio in this phase)
- `src/compositor/capture/SCStreamOutputEncoder.zig` — implements `SCStreamOutput` by submitting frames to encoder, feeding bitstream into muxer
- Wire keyboard shortcut (hotkey infrastructure) to start/stop recording on focused display; output path `$XDG_VIDEOS_DIR/nucleus-<timestamp>.mp4`
- Verification: press shortcut, record 30 seconds, press again; resulting file plays in mpv / VLC / browser; frame timestamps are monotonic; file remains playable if compositor is killed mid-recording (fragmented format)

### Phase 13 — Audio (microphone + desktop audio)

- Portal backend extends `Start` response with PipeWire audio node ids alongside video
- `src/compositor/capture/AudioAdapter.zig` — creates PipeWire capture streams against user's default source (microphone) or monitor of default sink (desktop audio)
- `SCStream` grows optional audio companion: frames are CMSampleBuffer-style `SCAudioFrame` with `presentation_timestamp_ns`
- Encoder gains Opus (preferred; host libopus development package) or AAC; muxer gains audio track + mdhd/tkhd/stsd audio boxes
- Verification: Discord/Zoom screen-share includes desktop audio; internal recording writes audio track that plays in VLC

### Phase 14 and beyond (future, outside this plan)

- Portal consent dialog (native Zig overlay) — the `engine.requestPortalConsent` callback is populated
- RN capture picker via Nitro HybridObject
- `SCStreamOutputType` enum for when audio is routed through the SC api (currently `AudioAdapter` sits beside, not inside, `SCStream`)
- `ext-image-copy-capture-v1` damage extension once stabilized
- `wp-color-management-v1` integration once HDR capture is needed

## Critical files to be modified / added

### Touched by phase 1
- `src/compositor/capture/` (new directory): all `SC*` types
- `src/compositor/PresentationRenderer.zig:302` — capture tap in `endFrame`
- `src/render_server/VulkanCompositorBackend.zig` — add `captureToStreamTarget` + DMA-BUF-exportable texture allocation
- `src/compositor/drm/output.zig:1019` — per-output capture refcount gate in `tryDirectScanout`
- `src/compositor/WindowServer.zig` — surface engine instance; source lifecycle on output/window add/remove
- `src/compositor/main.zig` — instantiate engine

### Touched by later phases
- `src/compositor/wayland/wlr_screencopy.zig` (phase 3)
- `src/compositor/wayland/image_capture_source.zig`, `output_image_capture_source.zig`, `image_copy_capture.zig` (phase 4)
- `src/compositor/wayland/wlr_export_dmabuf.zig` (phase 5)
- `src/compositor/Window.zig` — capture redirect fields (phase 6)
- `src/compositor/wayland/ext_foreign_toplevel_list.zig`, `wlr_foreign_toplevel_management.zig`, `ext_foreign_toplevel_image_capture_source.zig` (phase 7)
- `src/compositor/capture/PipeWireAdapter.zig`, `SCStreamOutputPipeWire.zig` (phase 8)
- `src/compositor/capture/PortalBackend.zig` (phase 9)
- `src/compositor/capture/VideoEncoder.zig`, `ColorConvert.zig`, `Fmp4Muxer.zig`, `SCStreamOutputEncoder.zig` (phase 12)
- `src/compositor/capture/AudioAdapter.zig` + muxer audio extension (phase 13)
- `NucleusCompositorGenerateWaylandC` plugin protocol list — protocol XML additions (regenerate the committed bindings), protocol version bumps as each phase lands; the PipeWire `.systemLibrary` C target added to `compositor-core/Package.swift`
- `src/compositor/WaylandServer.zig` — register new globals as each phase lands
- `src/compositor/main.zig` — `UringTag` variants `.pipewire`, `.portal`, `.encoder` added as phases 8/9/12 land
- Host prerequisites — add `pipewire`, `libspa-0.2` (phase 8), `libopus` (phase 13)
- `third-party/protocols/` — vendor `wlr-screencopy-unstable-v1.xml` (phase 3), `wlr-export-dmabuf-unstable-v1.xml` (phase 5), `wlr-foreign-toplevel-management-unstable-v1.xml` (phase 7)

### Reused verbatim (reference patterns)
- `src/compositor/screenshot_pipeline.zig` — worker-thread + eventfd pattern for CPU-readback and encoder consumers
- `src/compositor/wayland/dmabuf.zig` — format discovery + buffer import
- `src/compositor/wayland/cursor_shape.zig` — shortest protocol template for `image_capture_source`
- `src/render_server/ComposePass.zig:538` — `beginTexturePass` / `endTexturePass` for per-window re-compose
- `src/compositor/main.zig` `UringTag` enum — registration + multi-shot poll pattern
- `src/compositor/wayland/idle.zig` — multi-protocol module sharing one state, used as the shape for protocol modules that pair (e.g. the two foreign-toplevel variants)

## Verification

Per-phase acceptance criteria as listed above. System-level end-to-end after phase 9:

1. `swift build` — clean compile
2. `grim primary.png` produces a correct screenshot of the primary output (phase 3 path)
3. `wf-recorder -o primary.mp4` records primary output and the file plays correctly (phase 3 or 4 path, depending on wf-recorder version)
4. Launch a current OBS Studio build; configure a "Screen Capture (PipeWire)" or "Screen Capture (ext-image-copy-capture)" source; verify capture works on both paths
5. Launch a GPU-Screen-Recorder build; configure for `screen` capture; verify wlr-export-dmabuf path works (phase 5)
6. Launch Firefox inside Nucleus; go to `chrome://webrtc-internals`; start a `getDisplayMedia()` share; verify Firefox receives frames via PipeWire and preview plays (portal path — phase 9)
7. Launch Chrome and run the same WebRTC test; verify portal+PipeWire path also works for Chrome
8. Capture with no active streams: measure per-frame GPU cost relative to baseline — target zero overhead
9. Start a fullscreen direct-scanout-candidate app (mpv with fullscreen video); start recording; verify capture shows the video (direct scanout correctly suppressed while capturing)
10. Hotplug a monitor mid-capture; confirm corresponding `SCDisplay` removed, streams on it receive stop signal
11. Kill a captured window's client process mid-capture; confirm `SCWindow` removed, stream signals stop
12. After phase 12: keyboard shortcut records a 30-second MP4; file plays in VLC; file remains playable if compositor is killed mid-recording
13. After phase 13: Zoom/Discord screen-share with "share audio" option delivers audio to remote party
