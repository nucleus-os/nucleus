# Android Render Stack

> Invariant: Android renders through the same Swift Nucleus → Vulkan → Skia stack as every other Nucleus target. The retained layer model, transactions, animation, scene lowering, GPU resource management, frame recording, and Skia rasterization are the identical Swift modules used on Linux; the only Android-specific runtime code is the `VK_KHR_android_surface` swapchain presentation backend and the Kotlin-owned lifecycle/surface. There is no second renderer, no software fallback, and no Android-specific scene or GPU logic. Kotlin owns the Activity/SurfaceView/Choreographer and the public React Native integration; Swift owns everything from the retained tree to `vkQueuePresentKHR`.

This is RN-library / host-embedding work (iOS patterns), not compositor work: the Android host is an embeddable view that renders the Swift Nucleus scene driven by React Native, not a Wayland compositor. It shares the render stack (Nucleus/Vulkan/Skia) but none of the Wayland/DRM/seat/compositor surface.

## Current state

`platform-android/swift/*` (the Swift Android host) owns the lifecycle state machine, surface/frame/input tracking, and the JNI entry points behind the `NucleusAndroidC` façade. Its renderer (`AndroidRenderer.swift`) is a **software smoke**: it locks the `ANativeWindow`, writes a deterministic CPU pattern, and posts. The production Swift render stack (`NucleusRenderer`, `NucleusRenderModel`, `NucleusLayers`, `Vulkan`, `NucleusSkiaGraphite`) is **not** cross-compiled for Android and is not linked into `libnucleus-android.so`. The NDK ships `libvulkan.so` + `vulkan/vulkan_core.h`, so Vulkan is available on device.

The shared render stack is platform-agnostic Vulkan + Skia rendering of the Nucleus retained tree; only the *presentation backend* is platform-specific. On Linux that backend is DRM/KMS scanout over a GBM/Vulkan-imported framebuffer; on Android it is a Vulkan swapchain over an `ANativeWindow`. This plan adds the Android backend and cross-compiles the shared stack — nothing in the shared stack forks.

This work is the natural consumer of the SwiftPM + Swift-SDK + swift-java build direction — now the shipped build; see the **Build System** section of the repo-root `CLAUDE.md`. The phases below land on the SwiftPM Android cross-compile (`swift build --package-path platform-android --swift-sdk …`); the artifact (`libnucleus-android.so` consumed by the Kotlin `nucleus` module) is the same.

## Phase 1 — Vulkan on Android — DONE

Cross-compile `Vulkan` (the `vk.xml`-generated Swift Vulkan bindings) + `VulkanC` (the Clang façade over the Vulkan C API) for the Android target, against the NDK's `vulkan/vulkan_core.h` and `libvulkan.so`. The generated Swift bindings are target-independent; the façade's include path and the link line point at the NDK. The Android host creates a `VkInstance` with the Android surface + Vulkan instance extensions (`VK_KHR_surface`, `VK_KHR_android_surface`), selects a physical device, and creates a device + graphics/present queue.

`Vulkan` + `VulkanC` are exported as products from the root library package (platform-agnostic: vendored Khronos headers + the `vulkan` loader autolink) and consumed by `platform-android` — `swift build --product` builds only that closure, so the root's Linux-only targets stay out of the cross-compile. The shipped `RenderCore` owns the only Vulkan bring-up path. It requires Vulkan 1.4, preflights the complete Android instance/device extension and feature contract, creates the Android surface before physical-device selection, and accepts only a graphics queue family that can present to that surface. There is no weaker capability probe.

### Exit condition

Met. The cross-compile builds Vulkan for Android and `libnucleus-android.so` links `libvulkan.so` (in `NEEDED`); `tools/collider android verify` asserts the loader dependency and JNI exports. The capability-qualified create/teardown path is runtime-verified on device/emulator once available (deferred hardware validation).

## Phase 2 — The Android swapchain presentation backend — DONE

`platform-android/swift/AndroidVulkanPresenter.swift` owns the platform presentation: it creates a `VkSurfaceKHR` from the `ANativeWindow` (`vkCreateAndroidSurfaceKHR`, loaded by name since it is platform-specific and not in the generated dispatch table), builds a `VkSwapchainKHR` (format prefers B8G8R8A8_UNORM/sRGB, FIFO present mode, extent from surface caps or the requested size), and each frame acquires an image, clears it (`vkCmdClearColorImage` between UNDEFINED→TRANSFER_DST→PRESENT_SRC barriers, submitted with acquire/present semaphores + an in-flight fence), and presents — recreating the swapchain on `OUT_OF_DATE`/`SUBOPTIMAL` or a surface-generation change. `AndroidRenderer` drives it from the host's `frame()` (presenter created lazily on the first live-surface frame, torn down on detach); the WSI is reached through the platform-guarded `vulkan_android.h` added to `VulkanC` (no-op on Linux). The software pixel-writing smoke (and its now-dead `nucleus_android_window_lock`/`_unlock_and_post` C helpers) is deleted — no CPU rendering path on Android.

### Exit condition

Met (build-verified). The presenter compiles + links into `libnucleus-android.so` for `aarch64-unknown-linux-android36`; `libvulkan.so` is in `NEEDED`; the swapchain/clear/present dispatch is referenced; the JNI gate stays green. The cleared-image-per-frame + resize/rotation recreation is runtime-verified on device/emulator (deferred hardware validation). The render runtime draws into the acquired image instead of the clear in Phase 3/5.

## Phase 3 — Cross-compile the Nucleus render stack for Android — DONE

> Detailed plan: `docs/nucleon-renderer-platform-split.md` (all phases done, build-verified). The Linux DRM/KMS backend was extracted into `NucleusRendererLinux` behind the `PresentationBackend` protocol; `NucleusRenderer` (the platform-agnostic core) + `NucleusRenderModel` + Skia (Vulkan Graphite) + Vulkan cross-compile and link into `libnucleus-android.so` for AArch64; and `AndroidVulkanPresenter` conforms to `PresentationBackend` over a swapchain on the render core's device, with the Skia façade gaining WSI-semaphore + PRESENT_SRC handoff (`submitForPresent`). The host's `frame()` records the retained Nucleus scene into the acquired swapchain image. Rendered pixels + pacing + resize are runtime-validated on device (deferred).

Cross-compile the shared Swift render modules — `NucleusLayers`, `Nucleus`, `NucleusRenderModel`, `NucleusRenderHost`, `NucleusRenderer` — for Android. These own the retained tree, transactions, animation ticking, scene lowering, damage, frame planning, GPU resource management, and Vulkan frame recording; they are platform-agnostic and must compile for Android unchanged. The host-bundle conformers (context-id allocation, display-link source, IOSurface bind/lifecycle) are provided to the render runtime on Android as they are on Linux (Swift-native, via the same install path). Render targets are the swapchain images from Phase 2 rather than KMS framebuffers.

### Exit condition

The render runtime compiles + links for Android and records a Vulkan frame into a Phase-2 swapchain image. No render-stack source is `#if os(Android)`-forked beyond the presentation-backend selection.

## Phase 4 — Skia Graphite on Android — build done (brought forward)

Pulled ahead of Phase 3 because `NucleusRenderer` hard-depends on the Skia façade and cannot cross-compile without it. The Collider core recipe drives Skia's GN/Ninja cross-targeting the NDK (arm64, `ndk_api=24`) into `.skia-build/android-arm64` — the same native **Vulkan Graphite** backend as the host (`ContextFactory::MakeVulkan`), with Android's platform font manager instead of fontconfig. The single `NucleusSkiaGraphiteBridge` target compiles `Graphite.cpp` against that shared Vulkan-only contract when cross-compiling.

### Exit condition

Build half met: Skia cross-compiles to the AArch64 archive set, and the façade `Graphite.cpp` compiles for Android (native Vulkan Graphite path, `makeVulkanGetProc` over `VkInstance`/`VkDevice`). Rasterizing into Vulkan-backed textures that the render runtime samples is exercised once `NucleusRenderer` cross-compiles (Phase 3) and on device (deferred hardware validation).

## Phase 5 — Drive the render runtime from the Android host

Wire the host's `frame()` (Choreographer-driven through `nativeFrame`) to the Swift render runtime: each frame ticks animations, resolves the retained-tree scene, records the Vulkan frame against the acquired swapchain image, and presents. Surface lifecycle (`surfaceCreated`/`Changed`/`Destroyed`) drives the presenter's swapchain create/recreate/destroy; the `ANativeWindow` from the Kotlin `SurfaceView` is the render target. Input/IME state feeds the same Swift interaction model the scene uses. The host's diagnostic/smoke surface remains for validation but the live path is the production renderer.

### Exit condition

The Android host renders the live Nucleus scene through the shared Swift render stack to the device surface every frame, with correct resize/rotation/teardown. No Android-specific scene, animation, or GPU logic exists.

## Phase 6 — React Native content on Android

Drive the Nucleus retained tree from React Native on Android (the RN-library embedding): the RN host mounts the React tree into the Swift Nucleus model the renderer consumes — the same model path used elsewhere — so RN content renders through the shared stack. Kotlin owns the public RN integration surface; Swift owns the mount→scene→render path. swift-java (jextract, JNI mode; see `docs/android-swift-java-migration.md`) provides the type-safe Kotlin↔Swift calls, replacing the manual JNI host surface.

### Exit condition

A React Native view embedded via the Kotlin `nucleus` module renders its content through the Swift Nucleus/Vulkan/Skia stack on device, with no Android-specific renderer and no hand-written JNI.

## Verification

- Each phase keeps the cross-compile green (`nucleus-android` / `swift build` for the Android SDK) before the next begins.
- Build verification is the cross-compile + readelf (the right libraries in `NEEDED`, the expected symbols present), as today.
- Runtime verification (the actual pixels, frame pacing, resize/rotation, RN content) is on an Android device or emulator and is deferred with the rest of the plan's hardware validation; the smoke-app (`android/smoke-app`) is the harness.
- Skia (Phase 4) and the swapchain backend (Phase 2) are validated against reference frames once a device is in the loop.

## Exit condition

Android renders the live Nucleus scene — including React Native content — through the identical Swift Nucleus → Vulkan → Skia stack used on Linux, presenting via a `VK_KHR_android_surface` swapchain over the Kotlin-owned `ANativeWindow`. The software smoke renderer is gone; there is no second renderer, no Android-forked render logic, and no hand-written JNI. The only Android-specific runtime code is the swapchain presentation backend.
