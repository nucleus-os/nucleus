# Nucleus Renderer Platform Split

> Invariant: `NucleusRenderer` is platform-agnostic — it owns the Vulkan instance/device, the retained tree, surface/texture registration, frame recording, and Skia (Vulkan Graphite) compositing, and nothing else. Presentation is a `PresentationBackend` behind a protocol; the Linux DRM/KMS scanout and the Android Vulkan swapchain are its two implementors. No render-core source is `#if os(Android)`-forked beyond libc imports — the platform difference lives entirely in which backend is constructed. This is the render-stack plan's Phase 3 ("cross-compile the Nucleus render stack") made concrete: the renderer cannot cross-compile for Android until its Linux DRM/KMS backend is extracted.

This plan covers the renderer split and the Android cross-compile of the render core. Skia on Android (render-stack Phase 4, build half) is already done — `BuildSkiaAndroid` cross-compiles the Vulkan-Graphite archive set and `NucleusSkiaGraphiteBridge` compiles the façade with Android-specific settings. Vulkan on Android (Phase 1) and the Android Vulkan swapchain presenter (Phase 2) are also done; the presenter is the concrete Android `PresentationBackend` the final phase wires in.

## Current state

`swift/Sources/NucleusRenderer` is one SwiftPM target mixing two concerns:

- **Platform-agnostic (stays):** all of `presentation/` (13 files — frame plan, damage, geometry, scene walk; none import DRM), the Vulkan render core (`NucleusVulkanResources`/`NucleusVulkanSupport`/`NucleusVulkanRequirements`, `NucleusTextureProducer`/`Registry`, `NucleusBackdrop`, `NucleusTransition`, `NucleusFrameDriver`, `NucleusOutputBuffer`/`Accumulator`, `NucleusScreenshot`/`SnapshotCapture`), and the agnostic half of `RendererRuntime` (the Vulkan instance/device, `RetainedTreeStore`, `registerSurfaceTexture`/`Shm`/`Snapshot`, `allocSurfaceId`).
- **Linux-only (extract):** `drm/` (13 files, all `import NucleusDrmC`), `render/GbmScanoutBuffer.swift`, `render/NucleusVulkanDmaBuf.swift`, and the DRM half of `render/RendererRuntime.swift` (719 lines) — creation from a `drmDeviceFd`, the `gbm` device, `DrmOutput` per output, scanout slots, KMS flips, `enumerateAndAttachConnectedOutputs`, `handleDrmEvents`, `pause`/`resumeSession`.

`RendererRuntime` is a single `public final class` with the two concerns interleaved; the compositor (`ValenceCompositorRuntime`) drives it through `RenderRuntime` (bring-up, `enumerateOutputs`, `renderOutputs`, DRM event handling, session pause/resume). The Android host has no consumer of the render core yet — it drives the swapchain presenter directly.

The light render-stack modules (`NucleusLayers`, `Nucleus`, `NucleusRenderModel`, `NucleusRenderHost`) are nearly cross-compile-clean; the only portability items are `import Glibc` (the Swift Android SDK provides an `Android` libc module, not `Glibc`) and `Nucleus`'s `Tracy` dependency (tracy — cross-compile to confirm).

## Status

Phases 1–4 are done and verified. `NucleusRenderer` is the platform-agnostic core
behind `PresentationBackend`; the Linux DRM/KMS scanout lives in `NucleusRendererLinux`;
the render core + Skia (Vulkan Graphite) + Vulkan cross-compile and link into
`libnucleus-android.so` for AArch64 (Swift stdlib static; `libvulkan.so`/`libandroid.so`
in `NEEDED`; `tools/nucleus android verify` green). The Linux compositor builds and
runs unchanged. Phase 5 (the Android backend actually recording a Nucleus scene)
remains; its discovered requirements are noted below.

## Phase 1 — The presentation-backend protocol — DONE

Define `PresentationBackend` in `NucleusRenderer` and the agnostic types it trades in: an output identity/geometry descriptor, a `RenderTarget` (the Vulkan image the core records into), and the acquire/present/lifecycle operations. The protocol is what `RendererRuntime`'s agnostic core needs from a backend, with no DRM or swapchain types in its signatures:

- `enumerateOutputs(...) -> [OutputDescriptor]` — discover presentable outputs + geometry/scale.
- `acquireTarget(for: OutputDescriptor) -> RenderTarget?` — the image the frame records into this turn.
- `present(_ target: RenderTarget, for: OutputDescriptor)` — scan out / queue-present the recorded image.
- `pauseSession()` / `resumeSession()` and any page-flip / frame-complete callback the loop drains.

The existing `RenderTarget`, output-id, and geometry types are promoted to this boundary (they are already agnostic). The protocol lives beside the render core; the DRM and swapchain backends are not referenced here.

`PresentationBackend` is `@MainActor`, identifies outputs by `UInt64` id, and trades
in `AcquiredFrameTarget` (a C-typed Vulkan image descriptor — no generated `VK.*`
wrapper, so any backend in any module constructs it) plus a `FrameTargetKind` the
core maps to image usage. The core keeps the per-output `RenderTarget` geometry
internally (no geometry types go public): the backend registers geometry via
`RenderCore.attachOutputGeometry` and the loop is `RenderCore.renderReady(backend:)`.

### Exit condition

Met. `NucleusRenderer` compiles with the protocol + agnostic target types; the Linux
compositor builds and runs unchanged.

## Phase 2 — Split RendererRuntime into core + DRM orchestration — DONE

Separate `RendererRuntime`'s 719 lines along the seam: the agnostic **render core** (Vulkan instance/device ownership, `RetainedTreeStore`, surface/texture/shm/snapshot registration, `allocSurfaceId`, frame recording into a `RenderTarget`) stays in `NucleusRenderer`; the DRM-specific orchestration (creation from `drmDeviceFd`, the `gbm` handle, `attachOutput`/`makeScanoutSlot`, `renderOutput`/`renderReadyOutputs` KMS flips, `enumerateAndAttachConnectedOutputs`, `handleDrmEvents`, `pause`/`resumeSession`) becomes a separate type that holds the core and implements the Phase-1 backend operations.

The agnostic core exposes exactly what a backend needs to record a frame into an acquired `RenderTarget` (the Vulkan recording path), with no `gbm`/`Drm*` references. `dmabuf` surface import (`registerSurfaceDmabuf`, `NucleusVulkanDmaBuf`) moves with the Linux side — it is a Linux client-buffer path, not core rendering.

The split landed as `RenderCore` (agnostic: Vulkan instance/device, Graphite
context + frame driver, `RetainedTreeStore`, surface/texture/shm registration,
`recordFrame`, `renderReady`) and `RendererRuntime` (the DRM orchestrator holding a
`RenderCore`, conforming to `PresentationBackend`). The dmabuf *import* stays in the
core (portable Vulkan); only the syncobj explicit-sync wraps the core via an
`onSurfaceReleaseSync` hook the backend installs.

### Exit condition

Met. The render core has no DRM/GBM references; the Linux compositor still builds.

## Phase 3 — Extract NucleusRendererLinux — DONE

Create a `NucleusRendererLinux` SwiftPM target (Linux-only) and move into it: `drm/` (13 files), `render/GbmScanoutBuffer.swift`, `render/NucleusVulkanDmaBuf.swift`, and the DRM orchestration from Phase 2. It depends on `NucleusRenderer` + `NucleusDrmC` + `VulkanC`, carries the `libdrm`/`gbm` cc/link flags currently on `NucleusRenderer`, and implements `PresentationBackend` over KMS/GBM. `NucleusRenderer` loses its `NucleusDrmC` dependency and the `drmGbm*` flags.

The compositor (`ValenceCompositorRuntime` + root/compositor packages) depends on `NucleusRendererLinux` and constructs the DRM backend; `RenderRuntime` bring-up wires the backend into the render core. `NucleusRenderer`'s tests that exercise DRM/GBM (`GbmScanoutBufferTests`, scanout paths) move to `NucleusRendererLinux` tests.

`NucleusRendererLinux` carries the libdrm/gbm flags; the compositor + `NucleusRenderRuntime`
depend on it. `RendererRuntime`/`DrmOutput`/`nucleus_drm_discover` resolve from it.

### Exit condition

Met. The compositor app package builds and links the DRM backend behind the protocol;
`NucleusRenderer` builds with no DRM dependency.

## Phase 4 — Cross-compile NucleusRenderer for Android — DONE

Make the render core cross-compile. Replace `import Glibc` with `#if canImport(Glibc) import Glibc #elseif canImport(Android) import Android #endif` in the affected core files (math + any libc use). Confirm `Nucleus`'s `Tracy`/tracy dependency cross-compiles, or gate tracing behind a no-op on Android. Export the render-core modules (`NucleusRenderer`, `NucleusRenderModel`, `NucleusRenderHost`, `Nucleus`, `NucleusLayers`) as products from the root package; the `platform-android` package consumes them and `NucleusSkiaGraphiteBridge`.

Three build-system facts made this work: (1) the single `NucleusSkiaGraphiteBridge`
target applies Linux or Android C++ settings according to the destination platform.
`NucleusRenderer` imports the same module on both platforms. (2) `NucleusRenderer` switched from the
in-module `EmitVulkan` emit to the committed `Vulkan` module, so the
cross-compile builds no host tool (which `--static-swift-stdlib` could not link) and the
VK binding is shared with the Android host. (3) `--static-swift-stdlib` searches
`swift_static-aarch64`, which lacks the C++-interop static libs; the host target adds a
`-L` into the SDK's `swift-aarch64/android` resource dir so `libswiftCxx.a`/
`libswiftCxxStdlib.a` resolve. `expf`/`cosf`/`sinf` in `NucleusRenderModel` got the
`canImport(Glibc)/Android` guard.

### Exit condition

Met. `swift build --package-path platform-android --swift-sdk swift-release-6.4.x_android
--static-swift-stdlib -c release` links `libnucleus-android.so` (AArch64, ~86 MB, Swift
stdlib static, `libvulkan.so`/`libandroid.so`/`libc++_shared.so` in `NEEDED`, render-core
+ Skia symbols present); `tools/nucleus android verify` green.

## Phase 5 — The Android backend records a frame — DONE (build-verified; pixels device-deferred)

Two requirements surfaced when wiring this and were honored:

- **One Vulkan device.** `RenderCore` owns the Vulkan instance/device/queue +
  Graphite context; the swapchain image Skia records into must belong to that same
  device. `AndroidVulkanPresenter` (which today creates its own instance/device)
  is restructured to be constructed *from* `RenderCore`'s instance/physicalDevice/
  device/queue/graphicsFamily (all already public) + the loaded
  `vkCreateAndroidSurfaceKHR`; it adds only the surface + swapchain. The swapchain
  images are created with `COLOR_ATTACHMENT` usage so Graphite wraps them as render
  targets, format aligned with `AcquiredFrameTarget`/`vulkanFormatForDrm`.
- **WSI semaphore handoff.** The swapchain's acquire semaphore must gate Skia's
  Graphite submit, and the submit must signal the present semaphore that
  `vkQueuePresentKHR` waits on. This requires the Skia Graphite façade
  (`Graphite.cpp`) to accept wait/signal `VkSemaphore`s on the per-frame submit
  (`insertRecording`/`submit` with `BackendSemaphore`s) — the Linux KMS path needs
  none, so the façade does not expose them yet.

`AndroidVulkanPresenter` then conforms to `PresentationBackend`: `presentableOutputIDs`
returns the single surface output, `isReadyToPresent` gates on the in-flight fence,
`acquireTarget` acquires the next swapchain image and returns it as an
`AcquiredFrameTarget(kind: .swapchainColor)`, `present` does `vkQueuePresentKHR`
(recreating on `OUT_OF_DATE`/`SUBOPTIMAL`). `AndroidRenderer` drives
`renderCore.renderReady(backend: presenter)` from the host's `frame()`; attaching
an output forces one Graphite frame, including for an empty initial scene.

Landed: the Skia Graphite façade gained `GraphiteContext::submitForPresent` (wait/
signal `BackendSemaphore`s + a `MutableTextureStates::MakeVulkan(PRESENT_SRC, family)`
target-state transition, `SyncToCpu::kNo`), plumbed through `NucleusFrameDriver.PresentSubmit`
← `RenderCore.recordFrame` (built from `AcquiredFrameTarget`'s `kind`/semaphores).
`VkRequirements` is `#if os(Android)`-aware (instance += surface/android-surface,
device = swapchain + portable set, no dmabuf/DRM-modifier). `RenderCore` exposes
`instanceHandle`/`graphicsQueue`; `AndroidVulkanPresenter` is built from the core's
device (one device for Skia + the swapchain). `AndroidRenderEngine` (a `@MainActor`
class) owns core + presenter; `AndroidRenderer` drives it via `MainActor.assumeIsolated`.
The shared presenter owns two bounded frame slots (per-slot acquire semaphore +
submission-completion fence), per-image present semaphores/fences, nonblocking
acquisition, and generational swapchain retirement. It requires
`VK_KHR_swapchain_maintenance1`, uses presentation fences instead of queue/device
idle waits, and releases an acquired image directly when Graphite submission fails.

### Exit condition

Build half met: `libnucleus-android.so` links the render core + Skia + the swapchain
backend; `swift build --package-path platform-android --swift-sdk swift-release-6.4.x_android
--static-swift-stdlib -c release` succeeds and `tools/nucleus android verify` is green.
The Linux compositor still builds (the shared `Graphite.cpp` change compiles against
host Skia; the DRM path passes no semaphores). Rendered pixels + frame pacing + resize/
rotation are runtime-verified on device/emulator (deferred hardware validation), as is
the JNI-thread ↔ main-actor binding.

Make the Phase-2 `AndroidVulkanPresenter` implement `PresentationBackend`: `enumerateOutputs` from the surface geometry, `acquireTarget` wrapping the acquired swapchain image as a `RenderTarget`, `present` doing the queue-present. The Android host constructs the render core + the swapchain backend and, each frame, records the retained tree into the acquired image (Skia Vulkan Graphite) instead of the bare clear from Phase 2. Empty scenes use that same Graphite path.

### Exit condition

`libnucleus-android.so` links the render core + Skia + the swapchain backend; the host's frame path records a Nucleus scene into the acquired swapchain image and presents. Build-verified by the cross-compile + `readelf` (the render-core/Skia symbols present, `libvulkan.so` in `NEEDED`); the rendered pixels + frame pacing + resize are runtime-verified on device/emulator (deferred hardware validation).

## Verification

- Each phase keeps `swift build` (root) + the compositor app package green before the next begins — the Linux compositor is the regression guard for Phases 1–3.
- Android phases are build-verified by the cross-compile + `tools/nucleus android verify` (extended as needed); runtime verification (actual pixels, pacing, resize/rotation) is on a device/emulator via `android/smoke-app`, deferred with the rest of the render-stack plan's hardware validation.

## Exit condition

`NucleusRenderer` is platform-agnostic behind `PresentationBackend`; the Linux DRM/KMS scanout lives in `NucleusRendererLinux` and the Android Vulkan swapchain in the `platform-android` presenter; the render core cross-compiles for Android and records a Nucleus scene into a swapchain image — with no `#if os(Android)` forks in the render core beyond libc imports, and the Linux compositor unchanged.
