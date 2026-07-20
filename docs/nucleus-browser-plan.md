# Nucleus Browser

## Project invariant

Nucleus Browser is a native Chromium browser for Linux/Wayland whose complete
on-screen rendering path is:

```text
Blink and Viz
    → Skia Graphite
    → Dawn Vulkan
    → GBM/DMA-BUF SharedImages
    → explicit GPU fences
    → Ozone Wayland buffer presentation
    → the compositor
```

The browser does not use CEF, CEF OSR, X11/XWayland, Ganesh, OpenGL, ANGLE for
the browser compositor, software compositing, CPU readback, or an in-process GPU
process. Missing Vulkan, DMA-BUF, modifier, explicit-sync, or Wayland
capabilities are startup errors rather than reasons to select a fallback.

This is an ordinary multi-process Chromium browser. The browser process owns the
Wayland connection and `wl_surface` objects. The sandboxed GPU process renders
into shareable buffers and submits their metadata and fences through Chromium's
existing Ozone IPC boundary. A Wayland object is never passed to Dawn or the GPU
process.

## Goal

Ship a functional `nucleus-browser` executable that:

- runs natively on Wayland;
- renders Chromium UI and web content through Graphite/Dawn/Vulkan;
- selects the same physical GPU as the Wayland compositor;
- presents through Chromium's normal browser-process Wayland connection;
- supports accelerated video, WebGL, WebGPU, AAC/H.264, and Widevine;
- retains Chromium's process sandbox and site isolation;
- tracks resize, fractional scale, presentation timing, output changes, and
  buffer release without CPU/GPU queue-idle waits;
- builds from the same pinned Chromium source tree and generic patch foundation
  used by Noctalia's CEF integration, while retaining the standalone browser's
  own allocator and security configuration.

Nucleus Browser is also the on-screen reference client for the patched
Graphite/Dawn/Vulkan Chromium stack. It does not replace Noctalia's embedded CEF
panel and does not share CEF's offscreen buffer protocol.

Visual and product branding is deliberately deferred until after the browser
runtime passes its architectural and functional acceptance gates. Custom
icons, product strings, visual identity, and branding-resource replacement are
low-priority polish. They do not block renderer, Wayland, media, sandbox,
profile, packaging, or performance work.

## Why the browser needs a new presentation path

The current patches are sufficient for CEF's offscreen rendering path:
Graphite/Dawn/Vulkan renders into an exportable DMA-BUF ring, CEF publishes
those buffers, and Noctalia imports them. They are not sufficient for a normal
Chromium window.

Chromium's current Linux `InitializeForDawn()` path supports offscreen output
and an X11 fallback. The Wayland-only case reaches `NOTREACHED()`. The adjacent
source TODO describes creating a Vulkan swapchain, but direct swapchain
presentation is not the correct Linux/Wayland architecture for Chromium:

- the browser process owns the Ozone Wayland connection and `wl_surface`;
- rendering occurs in the sandboxed GPU process;
- Wayland proxies are connection-local and cannot be transferred between those
  processes;
- `--in-process-gpu` would avoid the boundary only by discarding Chromium's
  production process model and sandbox;
- direct WSI would bypass Chromium's overlay, fractional-scale, presentation
  feedback, popup, buffer-release, and compositor-integration machinery.

Chromium already has the correct transport in
`ui/ozone/platform/wayland/gpu/gbm_surfaceless_wayland.*`. It accepts native
pixmaps and GPU fences in the GPU process, sends buffer metadata through
`WaylandBufferManagerGpu`, and lets `WaylandBufferManagerHost` attach and commit
the corresponding `wl_buffer` in the browser process. Its presentation state
machine is currently coupled to EGL and exposed as `gl::Presenter`. Nucleus
Browser completes that existing architecture by extracting a backend-neutral
Wayland presenter and connecting it to Viz's existing
`SkiaOutputDeviceBufferQueue`.

## Final architecture

### Rendering

Viz records the browser frame through Skia Graphite. Graphite uses Dawn's Vulkan
backend on the compositor-selected Vulkan device. The root render pass is a
GBM-backed SharedImage with render-attachment, display-read, scanout, and
overlay usages. Dawn renders directly into that image.

`SkiaOutputDeviceBufferQueue` remains the buffer-queue owner. Its `BeginPaint()`
and `EndPaint()` methods are intentionally unreachable because Viz renders the
root render pass through SharedImages and schedules that pass as the root
overlay. Nucleus Browser does not add a second surface-backed Dawn output
device and does not use `SkiaOutputDeviceDawn` with a direct Wayland
`wgpu::Surface`.

### Presentation

A new `ui::OzonePresenter` interface owns the accelerated, API-neutral Ozone
presentation contract:

```cpp
class OzonePresenter {
 public:
  virtual bool Resize(const gfx::Size& pixel_size,
                      float scale_factor,
                      const gfx::ColorSpace& color_space,
                      bool has_alpha) = 0;

  virtual bool ScheduleOverlayPlane(
      scoped_refptr<gfx::NativePixmap> image,
      std::unique_ptr<gfx::GpuFence> acquire_fence,
      const gfx::OverlayPlaneData& plane) = 0;

  virtual void Present(SwapCompletionCallback completion,
                       PresentationCallback presentation,
                       gfx::FrameData frame_data) = 0;

  virtual bool SupportsViewporter() const = 0;
  virtual bool SupportsPlaneGpuFences() const = 0;
};
```

`SurfaceFactoryOzone::CreateOzonePresenter(widget)` creates the platform
implementation. Wayland returns `WaylandBufferQueuePresenter`, extracted from
`GbmSurfacelessWayland`. Viz's `OutputPresenterOzone` adapts
`ui::OzonePresenter` to the existing `viz::OutputPresenter` contract.

`GbmSurfacelessWayland` becomes a thin legacy GL adapter over the same Wayland
presentation core for unaffected upstream Chromium configurations. Nucleus
Browser never instantiates that adapter. There is one buffer state machine and
one Wayland commit path, not parallel GL and Vulkan implementations.

### Process boundary

```text
GPU process
  Dawn Vulkan writes GBM SharedImage
  → export render-complete sync_file
  → OutputPresenterOzone::ScheduleOverlayPlane
  → WaylandBufferQueuePresenter
  → WaylandBufferManagerGpu::CommitOverlays
             │ Mojo
             ▼
Browser process
  WaylandBufferManagerHost
  → create/reuse wl_buffer from DMA-BUF planes
  → attach explicit acquire fence
  → configure viewport, scale, damage, overlays
  → wl_surface.commit
  → receive submission, release, and wp_presentation feedback
             │ Mojo
             ▼
GPU process
  return release fence to SharedImage access
  → make buffer eligible for Dawn reuse
```

### Buffer lifecycle

Each root or overlay buffer has one explicit lifecycle:

```text
Available
  → Rendering
  → RenderComplete
  → SubmittedToWayland
  → LatchedByCompositor
  → ReleasedByCompositor
  → Available
```

The render-complete fence is owned by the presentation transaction after
`ScheduleOverlayPlane()`. The compositor release fence is returned to the
SharedImage scoped access before the buffer re-enters `Available`. File
descriptors are moved exactly once. Destruction or failure terminates every
pending completion and presentation callback exactly once.

The browser never:

- reuses a buffer before its release fence;
- waits for a GPU fence on the browser or Viz main thread;
- calls `vkQueueWaitIdle`, `vkDeviceWaitIdle`, `wgpuDevicePoll(...WaitAnyOnly)`,
  or a blocking readback in the frame path;
- assumes implicit synchronization;
- infers buffer identity from a DMA-BUF file descriptor number.

### GPU selection

Ozone's Wayland DMA-BUF feedback is authoritative. The compositor's
`main_device` identifies the DRM device used for presentation. Startup maps that
device to a Vulkan physical-device UUID and requires Dawn, native Vulkan,
ANGLE's Vulkan backend, video decode, and DMA-BUF allocation to use the same
adapter.

The existing CEF-specific `cef-vulkan-device-uuid` child-process switch becomes
an internal Chromium-wide GPU-selection value with a backend-neutral name. It
is populated by browser-process Ozone discovery and propagated through
Chromium's normal child command line. It is not a user-selectable compatibility
mode.

ANGLE remains available only where Chromium needs its Vulkan implementation for
WebGL or media interop. It is not the Viz compositor renderer. The browser's
compositor is Graphite/Dawn/Vulkan.

### Hardware video decode

Nucleus Browser reuses the VA-API, SharedImage, and Dawn Vulkan contract already
proven by Noctalia's CEF runtime. This is shared Chromium infrastructure, not a
CEF OSR feature:

```text
compressed web video
  → Chromium VA-API decoder
  → native-pixmap VideoFrame in NV12 or P010
  → OzoneImageBacking
  → Dawn Vulkan SharedTextureMemory DMA-BUF import
  → Graphite composition or Wayland overlay promotion
```

The decoded image and the root presentation image are distinct allocations.
Decoded NV12/P010 images remain multiplanar YUV SharedImages. If Viz promotes a
decoded image, the Ozone presenter transfers that image and its acquire fence
to Wayland directly. If promotion is rejected, Graphite samples the same
decoded image into the BGRA/RGBA root render pass. Rejection of promotion must
not cause CPU readback, software color conversion, an intermediate ARGB video
copy, or a change of decoder.

For NVIDIA, the supported driver is the pinned
`maddythewisp/nvidia-vaapi-driver` fork installed privately rather than over a
distribution-owned module. Its direct backend exports all NV12/P010 plane
descriptors from one packed DMA-BUF allocation, with exact per-plane offsets,
strides, modifiers, and allocation size. Dawn:

- verifies that every plane descriptor refers to that same allocation;
- creates the matching DRM-modifier Vulkan image;
- validates the reported plane layouts against Vulkan's queried layouts;
- imports the allocation once and uses a dedicated allocation when required by
  the external-memory properties;
- supports both 8-bit NV12 and 10-bit P010 sampling.

The browser launcher resolves the private driver's current revision, sets
`LIBVA_DRIVER_NAME=nvidia`, `LIBVA_DRIVERS_PATH`, and `NVD_BACKEND=direct`, and
derives `NVD_DRM_DEVICE` from the compositor-selected render node. A hard-coded
render node or CUDA index is not permitted. The driver's DRM-to-CUDA PCI
matching, Dawn adapter, ANGLE adapter, GBM allocation, and Wayland
`main_device` must identify the same physical GPU.

Decoder completion, Dawn access, overlay access, and compositor release are
one explicit fence chain. A decoded surface cannot return to VA-API while Dawn
or the compositor can still read it. No browser, Viz, media, or GPU main thread
blocks on that chain.

## Source ownership

The final implementation is divided by existing Chromium subsystem ownership.

### Ozone public contract

- `ui/ozone/public/ozone_presenter.h`
- `ui/ozone/public/surface_factory_ozone.h`
- `ui/ozone/public/BUILD.gn`

### Wayland implementation

- `ui/ozone/platform/wayland/gpu/wayland_buffer_queue_presenter.h`
- `ui/ozone/platform/wayland/gpu/wayland_buffer_queue_presenter.cc`
- `ui/ozone/platform/wayland/gpu/gbm_surfaceless_wayland.h`
- `ui/ozone/platform/wayland/gpu/gbm_surfaceless_wayland.cc`
- `ui/ozone/platform/wayland/gpu/wayland_surface_factory.cc`
- `ui/ozone/platform/wayland/gpu/wayland_buffer_manager_gpu.*`
- `ui/ozone/platform/wayland/host/wayland_buffer_manager_host.*`
- `ui/ozone/platform/wayland/mojom/wayland_buffer_manager.mojom`
- `ui/ozone/platform/wayland/gpu/BUILD.gn`

### Viz presentation

- `components/viz/service/display_embedder/output_presenter_ozone.h`
- `components/viz/service/display_embedder/output_presenter_ozone.cc`
- `components/viz/service/display_embedder/skia_output_device_buffer_queue.*`
- `components/viz/service/display_embedder/skia_output_surface_dependency.*`
- `components/viz/service/display_embedder/skia_output_surface_impl_on_gpu.*`
- `components/viz/service/display_embedder/BUILD.gn`

### SharedImage and Dawn

- `gpu/command_buffer/service/shared_image/ozone_image_backing.*`
- `gpu/command_buffer/service/shared_image/dawn_image_representation.*`
- `gpu/command_buffer/service/shared_image/shared_image_factory.*`
- `gpu/command_buffer/service/shared_context_state.*`
- `gpu/command_buffer/service/webgpu_decoder_impl.*`
- `third_party/dawn/src/dawn/native/vulkan/*` only where upstream Dawn lacks
  the required DMA-BUF or sync-file contract

### Media and decoded SharedImages

- `media/mojo/services/gpu_mojo_media_client*.cc`
- `media/gpu/chromeos/video_decoder_pipeline.cc`
- `gpu/command_buffer/service/shared_image/ozone_image_backing.*`
- `gpu/command_buffer/service/shared_image/dawn_image_representation.*`
- `third_party/dawn/src/dawn/native/vulkan/SharedTextureMemoryVk.cpp`
- `third_party/dawn/src/dawn/native/vulkan/PhysicalDeviceVk.cpp`
- the separately versioned `maddythewisp/nvidia-vaapi-driver` fork

### Device selection and Vulkan setup

- `ui/ozone/platform/wayland/host/wayland_zwp_linux_dmabuf.*`
- `gpu/config/gpu_info_collector_linux.*`
- `gpu/config/gpu_preferences.*`
- `gpu/vulkan/vulkan_device_queue.*`
- `gpu/command_buffer/service/dawn_context_provider.*`
- `ui/gl/angle_platform_impl.*` where ANGLE adapter selection is propagated

### Product and packaging

- `chrome/installer/linux/`
- workspace `chromium/` build and packaging scripts

Functional product identity may also require narrow changes in
`chrome/common/chrome_constants.*`, but custom strings and resources under
`chrome/app/` belong to the deferred branding phase rather than the browser
runtime implementation.

Exact file additions can follow upstream source movement at the pinned Chromium
revision, but subsystem ownership and API direction do not change.

## Current implementation status

As of 2026-07-19, the shared substrate and the first browser source slices are
persisted in the workspace:

- `chromium/build.sh` is the single product entry point for CEF, Nucleus
  Browser, or both;
- both products reuse CEF's pinned Chromium checkout, depot_tools, downloaded
  dependencies, PGO profiles, Dawn checkout, and compiler cache;
- CEF and the standalone browser retain separate GN outputs because their
  allocator and process-boundary contracts are intentionally different;
- Chromium-wide patches live in `chromium/patches/common/`, nested Dawn work in
  `chromium/patches/dawn/`, CEF-only behavior in `cef/patches/`, and the
  browser presenter work in `chromium/patches/browser/`;
- switching products reverses the exact previously applied product layer
  before applying the requested layer, so browser development cannot leak
  into a CEF build;
- the browser layer preserves the backend-neutral Wayland presenter, the Ozone
  Viz adapter, and the initial Graphite/Dawn presentable-SharedImage hookup;
- shared Chromium and Dawn patches preserve the working Graphite/Dawn/Vulkan
  VA-API path, packed NV12/P010 import, plane-layout validation, and
  dedicated-allocation handling already accepted in Noctalia's CEF runtime;
- the complete browser patch stack applies to the pinned source, and GN
  generation succeeds in its independent official/PGO/ThinLTO output;
- the focused Ozone, Wayland, and Viz targets compile in that output;
- five Wayland presenter prerequisite/lifecycle tests and four GL-independent
  Viz adapter tests pass. The Viz adapter has a narrow test executable so these
  API-neutral tests do not depend on the full Viz suite's GL bootstrap or
  reintroduce SwiftShader into the native-only browser build.

The niri fork now wires Smithay's existing
`wp_linux_drm_syncobj_manager_v1` implementation into its TTY backend. It
advertises the global only when the primary GPU supports syncobj eventfd,
prefers the explicit acquire-point blocker over implicit DMA-BUF readiness in
both ordinary and mapped-toplevel commit paths, lets Smithay signal the release
point when the buffer is dropped, and invalidates the global and imported
timelines if the primary renderer disappears. The integration compiles against
niri's pinned Smithay fork. Local on-screen acceptance still requires building
that niri revision, restarting the compositor session, and verifying the global
is advertised on the active DRM device.

This remains a hard compositor prerequisite, not a reason to add an
implicit-sync or CPU-waiting fallback to Nucleus Browser. The browser must
continue to fail with a named diagnostic when the protocol is absent.

This is development groundwork, not browser runtime acceptance. The initial
Phase 1 and Phase 2 slices now have compile and focused-test coverage, but their
remaining fence/plane cases and Phases 3–9 still need to complete, integrate,
package, and accept the real on-screen product. The proven CEF distribution
and Noctalia runtime remain authoritative while that work proceeds.

## Sequential implementation

### Phase 0 — Establish the shared Chromium substrate

Put shared Chromium source-build orchestration under `chromium/`, while
retaining `cef/` as the CEF-specific build and packaging component.
`automate-git.py` remains the authoritative provisioner for one pinned
CEF/Chromium checkout. The shared orchestration owns layered patch selection
and two product output directories.

The two output directories are necessary rather than configurable build
profiles. Embedded CEF must retain the allocator settings required at the
`libcef.so`/Noctalia process boundary, while a standalone Chromium browser must
retain Chromium's allocator shim and memory-safety configuration. Combining
those incompatible process contracts into one GN output would make one product
less correct.

Both optimized outputs retain:

```text
is_official_build=true
chrome_pgo_phase=2
use_thin_lto=true
use_lld=true
proprietary_codecs=true
ffmpeg_branding=Chrome
ozone_platform=wayland
ozone_platform_wayland=true
ozone_platform_x11=false
```

The CEF output retains `use_allocator_shim=false` and
`enable_backup_ref_ptr_support=false` because `libcef.so` is embedded in
Noctalia's process. The Nucleus Browser output does not inherit those CEF
overrides: it uses Chromium's official standalone allocator shim,
PartitionAlloc integration, and BackupRefPtr configuration. Both outputs
hard-enable the existing Graphite, Dawn, Vulkan, and DMA-BUF build requirements
and retain ThinLTO. Chromium's and ANGLE's SwiftShader targets are disabled;
native Vulkan is mandatory. Expensive DCHECKs stay out of release artifacts,
while validation-layer support remains buildable for explicit acceptance runs
and is disabled during ordinary runtime.

One build entry point generates and builds both fixed outputs. It does not
offer product profiles or a matrix of feature switches. The outputs share the
source checkout, patch application, depot tools, downloaded dependencies, PGO
profiles, and compiler cache, but not GN object files whose compile-time
contracts differ. CEF packaging and Nucleus Browser packaging consume their
respective outputs.

The private NVIDIA VA-API driver is not another Chromium build product.
Chromium and CEF share its pinned runtime contract and deployment convention,
while the driver remains independently buildable, installable, and
rollbackable under a revisioned private prefix.

Patch ownership is reorganized by subsystem:

1. generic Viz/SharedImage/Graphite/Dawn changes;
2. backend-neutral Ozone Wayland presentation;
3. generic Vulkan device selection;
4. CEF OSR transport and scheduling;
5. independent CEF behavior fixes.

Two patches do not modify the same source region. CEF-named switches and
messages are removed from generic GPU code. CEF's offscreen API remains in the
CEF patch, while the buffer presenter remains entirely generic.

Phase 0 lands with:

- one reproducible command producing optimized CEF and Nucleus Browser
  outputs;
- an independently generated Chromium browser output ready for the focused
  presenter implementation and test phases;
- unchanged CEF distribution contents and Noctalia compatibility;
- no second Chromium checkout and no duplicated dependency downloads.

### Phase 1 — Extract the backend-neutral Wayland presenter

Create `ui::OzonePresenter` and
`SurfaceFactoryOzone::CreateOzonePresenter()`. Extract the frame queues,
overlay scheduling, buffer registration, submission callback routing,
presentation callback routing, surface scale, viewport support, and solid-color
buffer handling from `GbmSurfacelessWayland` into
`WaylandBufferQueuePresenter`.

The extracted class contains no EGL headers, `GLDisplayEGL`, `glFlush`,
`GLFence`, or current-context behavior. Presentation readiness is determined
only by an explicit acquire fence or a scheduling failure.

`GbmSurfacelessWayland` delegates to the extracted presenter and supplies only
the legacy EGL-specific behavior required by existing non-Nucleus builds. This
keeps upstream GL behavior on the shared state machine without making it part
of Nucleus Browser.

The Wayland presenter explicitly defines:

- frame identifiers and wraparound behavior;
- callback order for submission and presentation;
- maximum pending frames;
- failed-plane atomicity;
- surface teardown semantics;
- stale browser-process response handling after GPU-process recovery;
- release-fence ownership;
- compositor disconnect behavior.

Phase 1 lands with behavior tests covering:

- frames submitted in order even when acquire fences retire out of order;
- one completion and one presentation result per `Present()`;
- failed overlay scheduling fails the complete frame;
- resize clears size-dependent solid-color buffers;
- teardown resolves every queued callback;
- stale frame IDs cannot resolve a new surface generation;
- the existing GL Wayland tests pass through the extracted presenter.

### Phase 2 — Add the Ozone Viz presenter

Add `viz::OutputPresenterOzone`. It performs the platform-neutral work currently
embedded in `OutputPresenterGL`:

- advertises top-left origin, surfaceless output, target damage, viewporter,
  alpha, and supported color formats;
- reshapes the `ui::OzonePresenter`;
- converts `OverlayCandidate` and `ScopedOverlayAccess` into a native pixmap,
  acquire fence, and `gfx::OverlayPlaneData`;
- transfers the access fence to Ozone;
- forwards swap completion and presentation feedback to Viz;
- returns compositor release fences through the existing overlay-access
  lifetime.

`SkiaOutputSurfaceDependency` receives a `CreateOzonePresenter()` method instead
of requiring a `gl::Presenter` for every accelerated Linux output. The Wayland
implementation is selected independently of GL initialization.

The existing `OutputPresenterGL` keeps non-Ozone platform responsibilities.
Nucleus Browser's Wayland path instantiates only `OutputPresenterOzone`.

Phase 2 lands with:

- Viz tests using a fake `OzonePresenter`;
- exact acquire- and release-fence ownership tests;
- root-plane, video-overlay, solid-color, alpha, crop, transform, damage,
  rounded-corner, and failure propagation tests;
- no GL context creation when the Ozone presenter is requested.

### Phase 3 — Make Graphite/Dawn SharedImages presentable

Complete the Graphite/Dawn/GBM SharedImage contract required by the buffer
queue. A root render-pass image is allocated with a compositor-supported DRM
format/modifier and all required usages:

```text
DISPLAY_READ
SCANOUT
OVERLAY
RASTER
WEBGPU_READ
WEBGPU_WRITE
```

The exact Chromium usage enum set follows the pinned revision, but it must
express all five behaviors: Graphite rendering, Dawn access, native-pixmap
export, Wayland scanout, and overlay representation.

`OzoneImageBacking` exposes both a Dawn representation and an overlay/native
pixmap representation for the same allocation. Dawn texture state, Vulkan
image layout, queue-family ownership, and external semaphore state are carried
through access begin/end rather than inferred at presentation time.

Modifier selection intersects:

1. compositor DMA-BUF feedback for the target surface;
2. GBM allocation support;
3. Vulkan external-image format properties;
4. Dawn texture-format and usage support;
5. scanout/overlay support.

The root plane initially uses `B8G8R8A8_UNORM`, then
`R8G8B8A8_UNORM`. Both are presented with the correct DRM fourcc, channel order,
premultiplied alpha, and color space. Unsupported combinations fail buffer
allocation clearly.

Phase 3 lands with:

- Graphite/Dawn rendering into a GBM-backed SharedImage;
- native-pixmap export of the identical allocation without a copy;
- correct transparent and opaque pixel output;
- reuse only after a returned release fence;
- no per-frame image allocation in steady state;
- no Skia readback or transfer image;
- zero-copy Dawn import of packed NV12 and P010 VA-API surfaces;
- exact validation of every decoded plane's object identity, offset, stride,
  modifier, and Vulkan subresource layout;
- dedicated external-memory allocation when Vulkan reports it as required;
- decoder-surface reuse only after Graphite or overlay access releases it.

### Phase 4 — Wire the on-screen Graphite/Dawn Wayland path

Replace the Linux/Wayland `NOTREACHED()` in
`SkiaOutputSurfaceImplOnGpu::InitializeForDawn()` with:

```text
CreateOzonePresenter()
  → OutputPresenterOzone
  → SkiaOutputDeviceBufferQueue
```

This is deliberately not the `SkiaOutputDeviceDawn` WSI path. Dawn supplies the
Graphite renderer and SharedImage access; Ozone supplies window presentation.

For Nucleus Browser, initialization requires:

- Graphite selected as Skia's renderer;
- Dawn selected as Graphite's backend;
- Dawn's Vulkan backend selected;
- a Wayland `OzonePresenter`;
- GBM native-pixmap allocation;
- compositor DMA-BUF feedback;
- explicit synchronization.

The X11 fallback, Ganesh paths, GL compositor path, SwiftShader compositor, and
software output device are not compiled into the Nucleus Browser product.
Renderer initialization failure exits with a named diagnostic containing the
failed requirement.

Phase 4 lands with a real Nucleus Browser window that renders:

- opaque Chromium UI;
- transparent content;
- text and images;
- CSS transforms and filters;
- WebGL content through ANGLE/Vulkan;
- WebGPU content through Dawn/Vulkan;
- resize and fractional scaling.

### Phase 5 — Complete explicit synchronization and lifetime

Make the complete producer-to-compositor-to-producer chain explicit.

At the end of Graphite/Dawn write access:

1. Graphite submits the recording.
2. Dawn exports a render-complete sync primitive as a sync-file fence.
3. the SharedImage overlay read access owns that acquire fence.
4. `OutputPresenterOzone` transfers it to the Wayland presenter.
5. the browser-process host attaches it through the supported Wayland explicit
   synchronization protocol before `wl_surface.commit`.
6. the compositor returns a release fence.
7. the GPU-process presenter transfers the release fence back to the
   SharedImage scoped access.
8. the next Dawn write access imports and waits on it on the GPU.

Stage masks and access scopes cover every legal Graphite/Dawn path rather than
assuming fragment-only sampling. Layout and queue-family transitions match on
both sides of each external ownership transfer.

When the compositor supports syncobj timelines, the presenter uses the
timeline protocol. The project does not retain a blocking sync-file fallback;
support for one explicit synchronization protocol is required.

Phase 5 also handles:

- window destruction with frames queued, submitted, or awaiting presentation;
- GPU-process crash and presenter generation reset;
- Dawn device loss;
- Vulkan device loss;
- browser-process Wayland disconnect;
- rejected or invalid release fences;
- buffer-allocation failure after output/modifier changes.

Phase 5 lands with:

- Vulkan synchronization validation clean under continuous animation;
- Dawn validation clean;
- stable DMA-BUF, sync-file FD, SharedImage, and Vulkan allocation counts;
- no buffer reuse before compositor release;
- no stranded swap/presentation callbacks;
- successful GPU-process recovery with a newly generated buffer queue.

### Phase 6 — Complete Wayland presentation behavior

Carry Chromium's full Wayland window semantics through the new presenter:

- configure/ack ordering;
- zero-sized and hidden windows;
- logical size, buffer size, buffer scale, and viewporter destination;
- fractional-scale changes without stale buffers;
- `wl_surface.damage_buffer` using Viz root damage;
- `wp_presentation` timestamps and refresh intervals;
- frame-callback throttling;
- output enter/leave and hotplug;
- minimize, restore, maximize, fullscreen, and interactive resize;
- popups, menus, tooltips, drag icons, and subsurfaces;
- opaque and input regions;
- premultiplied-alpha windows;
- compositor DMA-BUF feedback and modifier changes;
- suspend/resume and compositor restart.

Root-buffer correctness lands before overlay promotion. Video and delegated
overlays then use the same atomic plane transaction and fence ownership as the
root plane. If a candidate cannot be promoted, Viz composites it into the root
Graphite render pass; this is Chromium's normal composition decision, not a
renderer fallback.

Both outcomes retain the hardware-decoded NV12/P010 SharedImage. Overlay
rejection must not convert the frame through CPU memory or a persistent ARGB
intermediate. The compositor-visible result must preserve the decoded frame's
color space, bit depth, crop, transform, and protected-content constraints.

Phase 6 lands with:

- exact presentation feedback at 60, 120, and variable refresh rates;
- correct fractional scaling without repeated swapchain-style recreation;
- no visual discontinuity during resize or output migration;
- correct menus and transient windows on native Wayland;
- accelerated video overlays where the compositor accepts them;
- lossless rejection of overlay promotion with Graphite root composition;
- stable hardware-decoded video while promotion eligibility changes between
  consecutive frames.

### Phase 7 — Unify GPU and color selection

Replace CEF-specific adapter plumbing with one Chromium-wide selection path
driven by Wayland DMA-BUF feedback.

The selected identity is propagated to:

- Dawn's Vulkan adapter;
- Chromium's native Vulkan device queue;
- ANGLE's Vulkan physical-device selection;
- GBM allocation;
- video decode/encode interop;
- the private NVIDIA VA-API driver's `NVD_DRM_DEVICE` and DRM-to-CUDA PCI
  selection;
- SharedImage import/export validation.

Startup rejects split-GPU configurations that cannot import and present without
a copy. Discrete-GPU preference and enumeration order never override the
compositor-selected device.

Color management then carries:

- SharedImage color space;
- Skia surface color space;
- DRM/Wayland buffer format;
- HDR metadata where both Chromium and the compositor support it;
- correct sRGB transfer behavior;
- premultiplied-alpha semantics.

Phase 7 lands with tests for:

- matching and mismatching Vulkan UUIDs;
- hybrid-GPU systems;
- compositor `main_device` changes;
- BGRA/RGBA channel order;
- sRGB, Display P3, and HDR metadata propagation;
- video decode on the same adapter as presentation;
- failure instead of cross-device decode/import when the selected VA-API,
  CUDA, Dawn, and Wayland devices disagree.

### Phase 8 — Create the functional Nucleus Browser product

Turn the working `chrome` target into the Nucleus Browser product.

The product lands with:

- executable name `nucleus-browser`;
- a stable Wayland desktop ID and functional `.desktop` file;
- a private profile root at `~/.config/nucleus-browser`;
- a private cache root at `~/.cache/nucleus-browser`;
- browser, GPU, renderer, utility, crash handler, and sandbox helper artifacts;
- an installed SUID or user-namespace sandbox configuration;
- portal-native file chooser, notifications, screen capture, and secret-store
  integration;
- AAC, H.264, and MP4 support from the existing proprietary-codec build;
- Widevine discovery and CDM manifest packaging;
- persistent cookies, storage, service workers, HTTP cache, shader cache, and
  Dawn pipeline cache.

On NVIDIA systems, the installed launcher discovers the revisioned private
VA-API module, selects it without replacing the system driver, and passes the
compositor-selected render node through `NVD_DRM_DEVICE`. Missing or invalid
private-driver state produces a named hardware-video diagnostic. The package
records the expected driver revision and deployment instructions but does not
silently install over a distribution-owned `nvidia_drv_video.so`.

Phase 8 may retain legally usable upstream or placeholder visual resources and
generic product strings. It does not spend time replacing icons, polishing
product naming, theming Chromium UI, or completing a visual identity. The
desktop ID and profile paths are established now because portals, application
association, process behavior, and state isolation depend on them; they are
functional identifiers rather than a branding milestone.

Graphite/Dawn/Vulkan/Wayland is the product default in source. Users do not need
launch flags to select it. A single diagnostic page records the active renderer,
adapter UUID, DRM node, buffer formats/modifiers, explicit-sync protocol, and
presentation feedback. It reports facts; it does not negotiate alternate
backends.

Phase 8 lands with:

- independent Nucleus Browser and Noctalia CEF profiles;
- working sign-in persistence;
- browser history, downloads, clipboard, IME, accessibility, password storage,
  audio, media keys, and screen capture;
- a sandboxed multi-process runtime;
- no dependency on `libcef.so` or CEF wrapper APIs.

### Phase 9 — Validate, optimize, and make the browser authoritative

Run the complete acceptance matrix against release and validation builds.

#### Build and ABI

- the optimized build produces both CEF and Nucleus Browser;
- official-build optimization, PGO, V8 builtins PGO, and ThinLTO remain active;
- the browser contains no X11 Ozone platform and no GL/Ganesh compositor path;
- the installed runtime finds all resources, locales, sandbox, codecs, and
  Widevine files through relative product paths.

#### Renderer correctness

- Vulkan and Dawn validation remain clean;
- transparent and opaque pages render with correct premultiplied alpha;
- text, CSS filters, backdrop filters, SVG, canvas, video, WebGL, and WebGPU
  match Chromium reference pixels;
- buffer layout, modifier, plane stride/offset, and ownership are correct;
- GPU-process recovery recreates presentation without restarting the browser.

#### Wayland behavior

- native windows, popups, menus, tooltips, drag-and-drop, clipboard, IME, and
  accessibility work without XWayland;
- multiple monitors, fractional scaling, output hotplug, fullscreen,
  interactive resize, suspend/resume, and compositor restart work;
- presentation feedback supplies the actual monitor cadence;
- 120 Hz animation is continuous without timer-based frame generation.

#### Media and web platform

- Apple Music signs in, navigates, animates, and plays AAC continuously;
- Widevine playback succeeds;
- H.264, HEVC, VP9, and AV1 exercise every profile supported by the installed
  VA-API driver, including encrypted variants where the CDM permits them;
- both NV12 and P010 decoded outputs import and render correctly;
- WebGL reports ANGLE Vulkan on the selected adapter;
- WebGPU reports Dawn Vulkan on the same adapter;
- hardware video decode shares resources without a CPU copy;
- forced overlay rejection preserves hardware decode and uses Graphite root
  composition without an ARGB staging frame;
- accepted overlay promotion returns its compositor release fence before the
  decode surface is reused;
- decoder, SharedImage, Dawn, and presenter teardown release all frames and
  file descriptors exactly once.

#### Performance and stability

- the root frame is rendered directly into the presented DMA-BUF;
- steady-state presentation performs no full-frame copy;
- no frame-path CPU fence wait is present;
- no per-frame image, device-memory, or pipeline allocation is present;
- frame pacing follows Wayland presentation and frame callbacks;
- browser/GPU CPU time, GPU time, queue-to-visible latency, memory, FD count,
  and shader-cache behavior remain stable during long animated sessions;
- VA-API decode remains active, GPU video-engine utilization is observable,
  and CPU usage does not regress to software decode during navigation,
  fullscreen changes, overlay eligibility changes, or stream switches;
- continuous animated Apple Music artwork does not flash, tear, stall, or
  change color.

After these gates pass, Nucleus Browser becomes the authoritative on-screen
Graphite/Dawn/Vulkan Chromium client. The direct-Dawn-Wayland-WSI experiment,
in-process-GPU probes, runtime renderer-selection flags, redundant diagnostics,
and any temporary software paths are removed.

### Phase 10 — Apply final branding and product polish

This phase is deferred and low priority. Begin it only after Phase 9 establishes
the browser as the authoritative, accepted on-screen Chromium client.

The phase may then add:

- final application display name and user-facing product strings;
- Nucleus icons at every required Chromium and Linux desktop size;
- Chromium-license- and trademark-compliant branding resources;
- final About/version presentation;
- optional UI color, theme, and visual-identity polish;
- packaging artwork and other non-functional presentation assets.

Branding must not change the established executable name, desktop ID, profile
roots, sandbox layout, renderer selection, or runtime behavior. Branding
review is not part of the rendering, Wayland, media, synchronization,
performance, or browser-authority acceptance gates.

## Patch-stack result

The final patch stack has three architectural layers:

1. **Chromium-wide Graphite/Dawn/Vulkan and SharedImage support.** This contains
   DMA-BUF formats/modifiers, external memory, explicit layout/ownership state,
   Dawn representations, adapter selection, and color handling.
2. **Chromium-wide Ozone Wayland presentation.** This contains the
   backend-neutral presenter, Viz adapter, buffer queue, explicit fences, and
   the on-screen `InitializeForDawn()` path.
3. **CEF-only OSR integration.** This contains exportable offscreen buffers,
   CEF callbacks, external BeginFrame scheduling, device scale, and OSR input
   behavior.

Generic source files contain no “CEF” or “Noctalia” terminology. The CEF patch
does not own generic Ozone presentation code. The browser does not compile CEF
OSR classes. Patch files are consolidated so neighboring edits in a source file
belong to one patch.

## Explicit non-goals

- Presenting a browser window through a CEF view.
- Embedding Nucleus Browser inside Noctalia.
- Passing a `wl_surface` to the GPU process or Dawn.
- Using `wgpu::SurfaceSourceWaylandSurface` for Chromium's production window.
- Running Chromium with `--in-process-gpu`.
- Supporting X11 or XWayland.
- Retaining GL, Ganesh, SwiftShader, or software-compositor fallbacks.
- Adding a second VMA allocator or Volk.
- Replacing Chromium's browser UI with Swift or React Native.
- Building an auto-updater before the browser runtime is accepted.
- Sharing a profile directory with Noctalia's CEF instance.

## Final acceptance

The project is complete when `nucleus-browser` starts on native Wayland without
renderer-selection flags, chooses the compositor-presenting Vulkan device,
renders every Chromium and web-content surface through
Graphite/Dawn/Vulkan-backed DMA-BUFs, presents them through the browser-process
Ozone Wayland connection with explicit synchronization, and passes the release,
validation, media, multi-monitor, 120 Hz, and long-running Apple Music gates
without X11, GL, Ganesh, CEF OSR, CPU copies, or renderer fallbacks.
