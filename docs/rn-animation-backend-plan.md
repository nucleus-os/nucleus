# RN animation backend plan

**Status: complete.**

**Invariant: React Native animations advance from the presentation clock of the surface being rendered. Desktop uses compositor frame callbacks; Android uses Choreographer. Neither platform owns a timer-driven substitute.**

## Phase 1 — Define the clock seam — complete

Use React Native's `AnimationChoreographer` as the runtime animation-clock contract. `NucleusAnimationFrameClock` coalesces the shared native animation backend and JavaScript `requestAnimationFrame` onto one outstanding one-shot presentation request per React runtime. Its package-visible Swift facade installs the platform request/cancel closures and delivers monotonic nanosecond timestamps without carrying platform objects into RN domain models. Ordinary `setTimeout` and `setInterval` work remains owned by `NucleusPlatformTimerRegistry`; the animation clock replaces React Native 0.87's timer-backed `requestAnimationFrame` globals.

Gate: deterministic tests prove coalescing, cancellation, timestamp delivery, monotonic clamping, rearming, and teardown without wall-clock sleeps. `collider test runtime` passes on Linux/arm64.

## Phase 2 — Connect the desktop presentation clock — complete

`NucleusPresentationFrameSource` is the cross-platform application-host contract for one-shot frame demand. `NucleusDesktopWindow` implements it with `wl_surface.frame`: a request installs and commits one callback, cancellation or window closure destroys the client proxy, and completion releases the callback before invoking the runtime so rearming is safe. The Wayland millisecond timestamp is anchored to `CLOCK_MONOTONIC`, advanced by protocol deltas across `UInt32` wraparound, and never allowed to regress. `Host.setPresentationFrameSource(_:)` binds that source to the runtime-wide animation clock; failed requests remain unarmed and a replacement source can satisfy the retained demand.

Gate: deterministic tests prove source-driven delivery, cancellation, failed-source replacement, monotonic anchoring, wraparound, and regression handling. The runtime coalescing tests prove idle state leaves no callback armed and active demand rearms exactly once per delivery. `collider test runtime` passes on Linux/arm64.

## Phase 3 — Connect Android Choreographer — complete

`NucleusPresentationFrameRelay` is the lifecycle-controlled implementation for platforms whose framework owns the native callback object. `AndroidHostCore` starts it with the host, marks surface attachment and replacement, delivers the existing Choreographer nanosecond timestamp through it before each runtime frame, and synchronously cancels retained demand on stop, surface loss, and teardown. The Android framework layer owns one `AndroidFrameLoop`; eligibility changes remove its retained `Choreographer.FrameCallback` before native runtime or surface teardown, and repeated start or replacement notifications cannot post duplicates. The relay remains in the platform-contract module so the React Native integration composes it without making `core/` depend on RN.

Gate: deterministic Swift tests prove relay start/stop, one-shot timestamp delivery, and surface replacement cancellation. Kotlin unit tests prove eligibility coalescing, one callback per frame, cancellation, and replacement without duplicate posts. `collider test runtime` and `collider test android` pass; the Android test entrypoint now runs the Gradle project verification and its local unit tests rather than stopping at ELF/JNI inspection.

## Phase 4 — Bind the RN animation consumers — complete

The root RN workspace pins a coordinated React Native 0.87-compatible Reanimated and Worklets nightly pair. Collider runs the official RN code generator, builds both native libraries into the RN SDK, and exposes their generated and C++ headers to the root package. The React runtime publishes the Worklets and Reanimated TurboModules, enables React Native's shared animation backend, registers Reanimated's Fabric component descriptor, and routes both libraries' native frame requests through `NucleusAnimationFrameClock`. The Worklets JS package remains responsible for installing its generated unpackers before starting the UI runtime. Its UI scheduler dispatches through the runtime-owned JS executor; Wayland, Choreographer, and render threads only deliver timestamps.

Gate: the Fabric runtime test proves both native module contracts are present, while the shared presentation-clock fixtures prove desktop and Android delivery, coalescing, cancellation, teardown, and timestamp behavior without a timer fallback. `collider test runtime` and `collider test android` pass.
