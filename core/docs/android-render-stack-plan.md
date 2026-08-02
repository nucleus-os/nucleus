# Android render stack plan

**Status: active.**

**Invariant: Android uses the same retained Nucleus render core and Vulkan Graphite backend as every other platform. Android owns only lifecycle, input, `ANativeWindow`, swapchain presentation, and Choreographer integration.**

## Landed foundation

- The root package cross-compiles the portable render modules and Skia Graphite for Android/arm64.
- `AndroidVulkanPresenter` owns swapchain acquire, render-target handoff, presentation, resize, and surface replacement.
- `AndroidRenderEngine` drives the retained scene through the shared renderer.
- The JNI host and Gradle packaging consume the Swift artifact; no Zig or software-framebuffer path remains.

## Phase 1 — Complete React Native content

Build the RN runtime and native stack for Android, bind Fabric surfaces to the Android render engine, and route Choreographer through the shared RN animation-clock seam. Keep the Android framework wrapper limited to lifecycle and platform handles.

Gate: the signed smoke APK renders a deterministic Fabric scene with text and images through Vulkan Graphite.

## Phase 2 — Close lifecycle and input

Prove background/foreground, surface loss and recreation, rotation, density change, IME, touch, keys, and host teardown. Cancel callbacks before destroying runtime or swapchain state.

Gate: repeated lifecycle transitions produce no duplicate frame source, stale surface access, lost input, or leaked GPU object.

## Phase 3 — Qualify devices

Run reference-frame, pacing, resize, device-loss, and memory-pressure checks on the supported arm64 device matrix. Record CPU/GPU frame timing and confirm the normal frame path contains no CPU framebuffer copy.

Gate: 60 Hz UI stays within budget, idle surfaces stop waking, and validation layers report no lifetime or synchronization errors.
