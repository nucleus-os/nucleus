# RN Shared Animated Backend — Vsync Source and Choreographer Plan

## State invariant

Across every phase boundary the following must hold:

1. **Exactly one `AnimationChoreographer` per `Scheduler`.** Installed through
   `SchedulerToolbox.animationChoreographer` before `Scheduler` construction.
   The choreographer's lifetime equals or exceeds the `Scheduler`'s.
2. **`onAnimationFrame` runs on the vsync source's thread, not the JS thread.**
   The backend's internal `jsInvoker_` handles JS-thread dispatch when
   needed. The choreographer does not marshal across threads.
3. **Timestamps are monotonic and target-vsync-aligned.** The value passed
   to `onAnimationFrame` represents the next vsync deadline, not the
   post-vsync wall clock. Duplicate or backwards timestamps must be
   filtered before reaching the backend.
4. **`pause()` is zero-cost in the steady state.** When no animations are
   active the vsync source stops scheduling animation ticks; other
   substrate consumers of the same physical vsync signal (compositor
   redraw, presentation feedback) are unaffected.
5. **Only the `AnimationBackend` writes the commit hook.** Other commit
   hooks (Phase 5 Pressable, future scroll integration) coexist by source
   filtering on `ShadowTreeCommitSource`, not by removing the animation
   hook.

## Position

This plan is the authoritative reference for nucleus' implementation of
React Native's shared C++ animated backend on the newer Path 2 contract
(`ReactNativeFeatureFlags::useSharedAnimatedBackend() = true`,
commit-hook-driven). It exists because Path 2 has no off-Meta reference
implementation; iOS, Android, and Fantom are the only references and
they assume platform vsync sources (`CADisplayLink`,
`java.view.Choreographer`) that don't apply to a Wayland compositor or
to standalone apps with Vulkan/Metal Graphite render paths.

Path 1 (the three-lambda `StartOnRenderCallback` /
`DirectManipulationCallback` / `FabricCommitCallback` shape) lands first
through the RN runtime-host interop work's Phase 6a.
This plan's phases land after 6a stabilizes — they collectively
implement Phase 6b of that work and extend it to cover standalone-app
targets.

The plan picks **per-platform native vsync sources** over a portable
abstraction like `VK_KHR_present_wait`. Reason: vsync source fidelity
matters for animation smoothness, native APIs are battle-tested with
known timing characteristics, and present-wait extensions have uneven
driver support (especially on Windows GPU drivers and on MoltenVK's
Metal backend on macOS). The cost of a per-platform source is bounded
to ~100–150 lines per platform we ship.

## Pre-conditions

Already landed:

- Phase 6a has shipped:
  `NucleusTurboModuleProvider` registers the portable C++ NativeModules
  including `AnimatedModule`; Path 1's `StartOnRenderCallback` /
  `FabricCommitCallback` / `DirectManipulationCallback` are wired
  through `NucleusAnimatedDirectManipulation`; the topbar boots through
  real `AppRegistry` and `Animated.*` with `useNativeDriver: true`
  renders smoothly.
- `SchedulerToolbox.animationChoreographer = nullptr` in `FabricRuntime`'s
  ctor (Path 1 leaves this null; Phase 6b populates it).
- The compositor's io_uring loop handles `drmHandleEvent` for buffer
  release; extending it for animation ticks is a small additive change.

Not landed (out of scope here):

- Standalone nucleus app substrates. CLAUDE.md describes them
  ("standalone desktop apps … React Native Fabric platform using RN
  shared C++ core and a Zig rendering backend powered by Skia
  Graphite"), but no app target exists in tree yet. Per-platform
  standalone vsync sources land alongside the first standalone target
  on each platform.

## Contract reference

The `AnimationChoreographer` ABI is small but precise. Key references:

- `packages/react-native/ReactCommon/react/renderer/animationbackend/AnimationChoreographer.h:15-42`
  — three virtuals (`resume`, `pause`, `now`) plus
  `setAnimationBackend(std::weak_ptr<UIManagerAnimationBackend>)` and
  `onAnimationFrame(AnimationTimestamp)`.
- `AnimationTimestamp = std::chrono::duration<double, std::milli>`
  (UIManagerAnimationBackend.h:20). DOMHighResTimeStamp-compatible.
- `now()` default returns `HighResTimeStamp::now().toChronoSteadyClockTimePoint().time_since_epoch()`
  (steady_clock-based, monotonic).
- `setAnimationBackend(weak_ptr)` — backend hands the choreographer a
  weak ref; expired weak lock fails silently inside `onAnimationFrame`
  (line 35). Backend must outlive any in-flight tick.
- Backend's `onAnimationFrame(timestamp)`
  (AnimationBackend.cpp:102-117) acquires a mutex, copies the callback
  set, releases the mutex, calls each callback to collect
  `AnimationMutations`, then applies them via either
  `synchronouslyUpdateProps` (non-layout, sub-frame) or
  `shadowTree.commit(.mountSynchronously = true)` (layout, one-frame
  commit). The whole call runs on the choreographer's thread.

Reference implementations (read alongside this plan):

- iOS: `React/Fabric/RCTScheduler.mm:141-185` — `RCTAnimationChoreographer`
  wraps `CADisplayLink`, uses `targetTimestamp` (predictive,
  next-vsync). Runs on `NSRunLoop mainRunLoop`. Pause flips the
  DisplayLink's `paused` flag.
- Android: `ReactAndroid/src/main/java/com/facebook/react/fabric/AnimationBackendChoreographer.kt:22-89`
  — wraps `ReactChoreographer.NATIVE_ANIMATED_MODULE`, converts
  `frameTimeNanos` (post-vsync) to ms, explicitly skips duplicate
  frames with `currentFrameTimeMs > lastFrameTimeMs`. Runs on the
  render thread.
- Fantom: `private/react-native-fantom/tester/src/TesterAnimationChoreographer.{h,cpp}`
  — minimal gate-only stub with injectable clock. Closest reference
  for an out-of-tree platform.

Backend wiring (Scheduler.cpp:60-66):

```cpp
auto animationBackend = std::make_shared<AnimationBackend>(
    schedulerToolbox.animationChoreographer, uiManager);
schedulerToolbox.animationChoreographer->setAnimationBackend(animationBackend);
```

The platform owns the choreographer (`shared_ptr`); the Scheduler
constructs the backend; backend holds `shared_ptr` to the
choreographer; choreographer holds `weak_ptr` to the backend.
`AnimationBackendCommitHook` (registered in the backend's ctor) filters
commits by source (`React`, `AnimationEndSync`) to avoid recursion
during animation-driven commits.

## Architecture

One abstract vsync source trait plus one choreographer wrapper that's
identical across consumers.

### `NucleusVsyncSource` trait

Public header `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/VsyncSource.hpp`:

```cpp
namespace nucleus::react {

using AnimationTimestamp = facebook::react::AnimationTimestamp;

class NucleusVsyncSource {
 public:
  virtual ~NucleusVsyncSource() = default;

  // Begin delivering per-vsync ticks to `onTick`. The timestamp is the
  // *target* vsync deadline (next frame), not the post-vsync wall
  // clock — matches iOS CADisplayLink.targetTimestamp semantics.
  // Implementations dedupe; callers receive strictly-monotonic
  // timestamps.
  virtual void resume(std::function<void(AnimationTimestamp)> onTick) = 0;

  // Stop delivering ticks. Must be safe to call when already paused.
  virtual void pause() = 0;

  // Monotonic clock matching the timestamps delivered to `onTick`.
  virtual AnimationTimestamp now() const = 0;
};

} // namespace nucleus::react
```

### `NucleusAnimationChoreographer` wrapper

Internal `swift/Sources/NucleusReactRuntime/cxx/NucleusAnimationChoreographer.{hpp,cpp}`:

```cpp
class NucleusAnimationChoreographer final
    : public facebook::react::AnimationChoreographer {
 public:
  explicit NucleusAnimationChoreographer(
      std::shared_ptr<NucleusVsyncSource> vsync);

  void resume() override;
  void pause() override;
  AnimationTimestamp now() const override;

 private:
  std::shared_ptr<NucleusVsyncSource> vsync_;
  AnimationTimestamp lastTick_{};
  bool active_{false};
};
```

The wrapper owns three concerns:

1. **Dedup.** Skips `onAnimationFrame` calls where the timestamp is not
   strictly greater than the previous one. Matches Android's
   `currentFrameTimeMs > lastFrameTimeMs` guard.
2. **Idempotent resume/pause.** Tracks `active_` to avoid double-resume
   or double-pause against the source.
3. **Source-of-`now()` consistency.** Delegates `now()` to the source so
   the backend's frame-clock and our tick-clock match.

The wrapper is ~80 lines; every platform consumer reuses it unchanged.

### Construction order

In `FabricRuntime`'s ctor (`ReactRuntimeHost.cpp`):

1. Construct the platform `NucleusVsyncSource`.
2. Construct `NucleusAnimationChoreographer(vsyncSource)`.
3. Populate `SchedulerToolbox.animationChoreographer = choreographer`.
4. Construct `Scheduler` — it constructs the `AnimationBackend`
   internally and wires the commit hook.

## Phase 1 — Vsync source trait + compositor implementation

### Goal

Land the `NucleusVsyncSource` trait, the `NucleusAnimationChoreographer`
wrapper, and the compositor's `KmsPageFlipVsyncSource`. Flip
`useSharedAnimatedBackend = true` for the compositor's RN runtime.
Delete the Phase 6a Path 1 wiring.

### Work

#### Trait + wrapper

Add the headers/sources described in the Architecture section. The
wrapper is fully reusable across consumers; only the source changes per
platform.

#### `KmsPageFlipVsyncSource`

Compositor consumer. Hooks into the existing io_uring loop +
`drmHandleEvent` page-flip completion path.

`swift/Sources/NucleusReactRuntime/cxx/KmsPageFlipVsyncSource.{hpp,cpp}`:

- Holds the `onTick` callback handed in via `resume`.
- Asks the Zig compositor side (through a small extern C entry —
  `nucleus_animation_vsync_arm` / `nucleus_animation_vsync_disarm`) to
  schedule the next animation tick.
- On the Zig side, the existing `drmHandleEvent` page-flip handler in
  `src/compositor/main.zig` fires a registered C callback (the C++
  source's tick entry) when a page flip completes, passing the post-
  vsync timestamp. The source converts that to the *next* vsync
  deadline by adding one mode refresh period and delivers the result.
- On `pause`, the Zig side stops re-arming the per-tick scheduling but
  leaves the page-flip handler installed (other compositor consumers
  depend on it).

`now()` reads the same monotonic clock the page-flip handler uses
(`CLOCK_MONOTONIC` via `clock_gettime`), normalized to
`AnimationTimestamp` (ms-as-double from a fixed epoch captured at
startup so subsequent values fit comfortably in `double` precision).

#### Wiring into `FabricRuntime`

The Phase 6a `FabricRuntime` ctor passes
`SchedulerToolbox.animationChoreographer = nullptr`. Phase 1 of this
plan constructs the source + choreographer and populates the toolbox
slot before `Scheduler` construction.

#### Feature flag override

Set `ReactNativeFeatureFlags::useSharedAnimatedBackend = true` in the
runtime's feature-flag overrides (alongside `cxxNativeAnimatedEnabled`,
which Phase 6a already verified is on).

#### Delete Path 1 wiring

After Path 2 is validated against the topbar's existing animations:

- Delete `swift/Sources/NucleusReactRuntime/cxx/NucleusAnimatedDirectManipulation.{hpp,cpp}`.
- In `NucleusTurboModuleProvider`, remove the three-lambda
  construction of `NativeAnimatedNodesManager`. With `useSharedAnimatedBackend = true`,
  the manager retrieves the backend through the Scheduler instead.
- Remove the `MergedValueDispatcher` and
  `AnimatedMountingOverrideDelegate` plumbing if any leaked into our
  codebase from the reference wiring.

### Files touched

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/VsyncSource.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/NucleusAnimationChoreographer.{hpp,cpp}`
- New: `swift/Sources/NucleusReactRuntime/cxx/KmsPageFlipVsyncSource.{hpp,cpp}`
- New: `src/compositor/animation_vsync_source.zig` — Zig hook into the
  existing drmEventContext + io_uring scheduling.
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (populate `SchedulerToolbox.animationChoreographer`).
- Modified: `swift/Sources/NucleusReactRuntime/cxx/NucleusTurboModuleProvider.{hpp,cpp}`
  (`AnimatedModule` construction switches to Path 2 shape).
- Modified: `ReactNativeFeatureFlags` overrides (set
  `useSharedAnimatedBackend = true`).
- Deleted: `swift/Sources/NucleusReactRuntime/cxx/NucleusAnimatedDirectManipulation.{hpp,cpp}`.

### Verification

- Animation benchmark bundle (new: `bundles/dev/animated-latency/index.jsx`)
  drives `Animated.timing` against `transform` / `opacity` plus
  `width` / `height` with `useNativeDriver: true`. Non-layout
  animations stay sub-frame; layout-affecting animations stay within
  one-frame budget under Tracy capture.
- The topbar's clock and any existing animations render identically to
  Path 1 (no visible regressions).
- `grep -r MergedValueDispatcher swift/` returns nothing.
- `MountConsumer` receives committed shadow trees where animated
  values are already in `newChildShadowView.props`, not as separate
  Update mutations from a side-channel.

### Exit criteria

`useSharedAnimatedBackend = true` is the compositor runtime default.
Path 1 wiring is fully deleted from the runtime-host library.
Animation behavior matches or exceeds Path 1 across the benchmark
suite. The compositor's drmHandleEvent path delivers animation ticks
without disturbing buffer release or other page-flip consumers.

## Phase 2 — First standalone vsync source (Linux Wayland)

### Goal

Implement `WaylandFrameVsyncSource` for standalone Linux nucleus apps
that target Wayland. Lands alongside the first standalone app target
that requires animations.

### Work

`swift/Sources/NucleusReactRuntime/cxx/WaylandFrameVsyncSource.{hpp,cpp}`:

- On `resume`, requests a `wl_surface.frame()` callback against the
  app's primary surface. When the callback fires, computes the next
  vsync deadline (using `wp_presentation_feedback` for accurate
  per-frame timing) and delivers the timestamp to `onTick`. Re-requests
  the next frame callback inside the tick handler.
- On `pause`, stops re-requesting. The current outstanding callback
  fires once more if pending; the source ignores it.
- `now()` reads `CLOCK_MONOTONIC` matching Wayland's presentation
  timestamps.

Threading: the Wayland event thread runs on the app's main thread (or
a dedicated event-loop thread depending on substrate design). The
choreographer fires `onAnimationFrame` on that thread. The
`AnimationBackend` internally dispatches JS-thread work via
`jsInvoker`, so we don't marshal here.

### Files touched

- New: `swift/Sources/NucleusReactRuntime/cxx/WaylandFrameVsyncSource.{hpp,cpp}`
- Modified: standalone app's substrate to construct the source and pass
  it to the runtime host's `FabricRuntime` ctor at startup.

### Verification

- Standalone app renders an `Animated.timing` cycle smoothly at the
  display's refresh rate (60Hz / 144Hz depending on monitor).
- `wp_presentation_feedback` timestamps match the timestamps the
  choreographer passes to `onAnimationFrame` (within one frame).
- Pause stops animation work when no animations are active; resume
  reacquires within one frame.

### Exit criteria

Standalone Linux Wayland nucleus apps drive animations through Path 2
with the same backend code as the compositor — only the source differs.

## Phase 3 — macOS standalone vsync source

### Goal

Implement `CoreVideoVsyncSource` for standalone nucleus apps on macOS.
Lands alongside the first macOS standalone target.

### Work

`swift/Sources/NucleusReactRuntime/cxx/CoreVideoVsyncSource.{hpp,cpp}`:

- Wraps `CVDisplayLink` (per-display, fires on a dedicated CV thread).
  Choice rationale: `CVDisplayLink` decouples animation timing from
  the main thread, matching nucleus' standalone threading model where
  JS runs on `com.nucleus.js` separate from main. `CADisplayLink` is
  main-thread-bound and would tie animation cadence to main-thread
  work, which doesn't match.
- On `resume`, registers a callback via `CVDisplayLinkSetOutputCallback`
  and starts the display link. The callback delivers
  `inOutputTime->videoTime` converted to `AnimationTimestamp` (target
  vsync).
- On `pause`, stops the display link (`CVDisplayLinkStop`) but keeps
  the handle around for cheap resume.
- `now()` uses `CVGetCurrentHostTime()` normalized through the
  display's host-time-to-seconds conversion.

Threading: the CVDisplayLink callback fires on a dedicated thread.
`onAnimationFrame` runs there; `AnimationBackend`'s `jsInvoker`
handles JS-thread marshalling. Backend's `ShadowTree::commit` runs on
the CV thread — verify this is safe (Android's precedent says
non-JS-thread commit is supported, but confirm on macOS during
implementation).

### Files touched

- New: `swift/Sources/NucleusReactRuntime/cxx/CoreVideoVsyncSource.{hpp,cpp}`
- Modified: macOS standalone substrate to construct the source.

### Verification

Same shape as Phase 2 — smooth `Animated.timing` cycles at the
display's refresh rate; pause/resume behavior matches; no main-thread
hitches during heavy animations.

### Exit criteria

Standalone macOS nucleus apps drive animations through Path 2.

## Phase 4 — Windows standalone vsync source

### Goal

Implement `DxgiWaitForVBlankVsyncSource` for standalone nucleus apps on
Windows. Lands alongside the first Windows standalone target.

### Work

`swift/Sources/NucleusReactRuntime/cxx/DxgiWaitForVBlankVsyncSource.{hpp,cpp}`:

- Spawns a dedicated vsync thread that loops on
  `IDXGIOutput::WaitForVBlank`. On each vsync, posts an
  `AnimationTimestamp` (estimated next deadline from
  `IDXGISwapChain1::GetFrameStatistics`) to the active `onTick`
  callback. The thread exits cleanly on `pause` (the next
  `WaitForVBlank` is the last; the thread joins).
- On `resume`, starts a fresh vsync thread bound to the primary output
  for the active swap chain.
- `pause` signals the thread to exit and waits for join. Resume after
  pause spawns a new thread — there's no cheap-resume path for
  `WaitForVBlank` the way DisplayLink offers.
- `now()` uses `QueryPerformanceCounter` normalized to ms.

Threading: the vsync thread is dedicated. `onAnimationFrame` runs
there; `AnimationBackend`'s `jsInvoker` handles JS-thread marshalling.

### Files touched

- New: `swift/Sources/NucleusReactRuntime/cxx/DxgiWaitForVBlankVsyncSource.{hpp,cpp}`
- Modified: Windows standalone substrate to construct the source.

### Verification

Same shape as Phase 2 / 3. Special attention to thread-spawn cost on
resume — measure resume latency; if it exceeds one frame, consider
keeping the thread alive and gating with a condition variable instead
of joining.

### Exit criteria

Standalone Windows nucleus apps drive animations through Path 2.

## Threading model

The choreographer fires `onAnimationFrame` on whatever thread the
vsync source delivers ticks on. The `AnimationBackend` accepts this
and uses its internal `jsInvoker` for any JS-thread work
(`asyncFlushSurfaces`, end-of-animation notifications). We do not
marshal in our code.

Per consumer:

| Consumer | Vsync thread | JS thread | Marshalling |
| --- | --- | --- | --- |
| Compositor | main (io_uring loop) | main (same) | None — direct call |
| Standalone Wayland | Wayland event thread (main) | `com.nucleus.js` | Backend internal via jsInvoker |
| Standalone macOS | CVDisplayLink thread | `com.nucleus.js` | Backend internal via jsInvoker |
| Standalone Windows | dedicated vsync thread | `com.nucleus.js` | Backend internal via jsInvoker |

The compositor is the simplest case — main = JS = vsync thread, all in
one io_uring-driven loop. Standalone consumers all have the same
shape: vsync on a non-JS thread, backend dispatches as needed.

## Timestamp semantics

The choreographer delivers **target-vsync timestamps** — the time the
next frame is expected to present, not the post-vsync wall clock. This
matches iOS's `CADisplayLink.targetTimestamp` and gives animations a
small lookahead so interpolation lands aligned with the displayed
frame.

Per-source conversion to target vsync:

- **KMS page flip:** add one mode refresh period to the post-flip
  timestamp (mode period available from
  `drmModeModeInfo.vrefresh`-derived nanoseconds).
- **Wayland presentation feedback:** use `wp_presentation_feedback`'s
  predicted-next-presentation timestamp directly when available;
  otherwise fall back to "last presentation + refresh interval"
  estimated from the feedback's `refresh_nsec`.
- **CVDisplayLink:** `inOutputTime->videoTime` is already the target
  output time. Convert to `AnimationTimestamp` via the host-time-to-
  seconds ratio.
- **DXGI WaitForVBlank:** the vsync we just woke on is the start of
  the next frame interval. Add `IDXGISwapChain1::GetFrameStatistics`'s
  derived refresh interval to estimate the target.

All sources normalize to `std::chrono::duration<double, std::milli>`
from a fixed epoch captured at the source's first observation, so
subsequent ticks fit comfortably in `double` precision and never lose
millisecond resolution.

## Risks

**No off-Meta Path 2 reference.** Implementing
`AnimationChoreographer` correctly requires inferring the threading
and unit conventions from the iOS / Android / Fantom references.
Mitigation: Phase 6a (Path 1) ships first and stays deletable until
Phase 1 here validates against the topbar's existing animations.
Catch regressions early through the benchmark bundle.

**`ShadowTree::commit` on non-JS threads.** For standalone consumers
the backend calls `ShadowTree.commit` on the vsync thread (not the
JS thread). iOS does this on main (which is also JS thread on iOS);
Android does it on the render thread (not JS thread). Android's path
is the precedent we lean on for standalone macOS / Windows. Verify
during implementation that no internal commit path assumes
JS-thread-only invariants.

**Hook ordering and re-entrancy.** `AnimationBackendCommitHook` runs
on every ShadowTree commit. If Phase 5's Pressable work or future
scroll integration registers additional commit hooks, ordering
between them and the animation hook must be predictable. Mitigation:
keep diagnostic logging of commit sources during early Phase 1
sessions; document any ordering assumptions before adding the second
hook.

**Pause/resume re-entrancy.** The reference `AnimationChoreographer`
contract doesn't specify atomic resume/pause across threads. Our
wrapper handles idempotency via `active_`, but if the backend ever
calls them concurrently (e.g., one animation starts on the JS thread
while another finishes on the vsync thread), the wrapper needs to
serialize. Add a small mutex around `resume`/`pause` if profiling
shows contention; ship without it initially.

**DXGI WaitForVBlank thread-spawn cost.** The Windows source spawns
a new thread on each `resume`. If animations start/stop frequently
(common in interactive UIs), the spawn cost may exceed one frame.
Mitigation in Phase 4: measure first; if measurable, switch to a
condition-variable-gated permanent thread that parks during pause.

**Flag churn upstream.** `useSharedAnimatedBackend` was added
~2025-08 and is default-off. Meta may iterate the backend API before
flipping the default. Mitigation: pin the RN submodule revision
before Phase 1 lands; hold submodule bumps until Phase 1
re-validates.

**MoltenVK / Vulkan present-wait skipped.** We considered
`VK_KHR_present_wait` as a portable alternative to per-platform
sources. Skipped because MoltenVK's support on macOS is partial and
Windows GPU drivers' implementations vary. Per-platform sources are
~100–150 lines each; the maintenance cost is bounded and the timing
fidelity is better.

## Reference patterns

- `packages/react-native/ReactCommon/react/renderer/animationbackend/AnimationChoreographer.h:15-42`
  — abstract contract.
- `packages/react-native/ReactCommon/react/renderer/animationbackend/AnimationBackend.{h,cpp}`
  — backend implementation; `onAnimationFrame` body at lines 102-117.
- `packages/react-native/ReactCommon/react/renderer/animationbackend/AnimationBackendCommitHook.{h,cpp}`
  — commit hook that injects animated prop snapshots.
- `packages/react-native/React/Fabric/RCTScheduler.mm:141-185` — iOS
  `RCTAnimationChoreographer` over `CADisplayLink`.
- `packages/react-native/ReactAndroid/src/main/java/com/facebook/react/fabric/AnimationBackendChoreographer.kt:22-89`
  — Android over `java.view.Choreographer`.
- `private/react-native-fantom/tester/src/TesterAnimationChoreographer.{h,cpp}`
  — minimal gate-only stub, closest off-platform reference.
- `packages/react-native/ReactCommon/react/renderer/scheduler/Scheduler.cpp:60-66`
  — backend construction + choreographer registration sequence.
- `packages/react-native/ReactCommon/react/timing/primitives.h:206-209,327-333`
  — `HighResTimeStamp` and steady_clock conversion.
