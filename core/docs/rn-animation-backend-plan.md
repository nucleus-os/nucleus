# RN animation backend plan

**Status: active.**

**Invariant: React Native animations advance from the presentation clock of the surface being rendered. Desktop uses compositor frame callbacks; Android uses Choreographer. Neither platform owns a timer-driven substitute.**

## Phase 1 — Define the clock seam

Add a package-visible animation clock protocol to the RN runtime with monotonic timestamps, cancellation, and one outstanding callback per surface. Keep platform objects outside RN domain models.

Gate: deterministic tests prove coalescing, cancellation, monotonicity, and teardown without wall-clock sleeps.

## Phase 2 — Connect the desktop presentation clock

Have the Wayland client runtime request a frame callback only while Fabric or the animation backend has pending work. Deliver the callback timestamp through the clock seam and stop requesting callbacks when idle.

Gate: an idle RN window produces no animation wakeups; an active animation advances once per compositor callback and survives output refresh-rate changes.

## Phase 3 — Connect Android Choreographer

Route the existing Android frame callback through the same clock seam. Lifecycle stop, surface loss, and host teardown cancel outstanding callbacks before releasing runtime state.

Gate: Android tests prove start/stop and surface replacement do not duplicate or retain callbacks.

## Phase 4 — Bind the RN animation consumers

Connect Fabric-driven animations and Reanimated scheduling to the shared clock. Dispatch JS work through the runtime's owning executor and never call into Hermes from the Wayland, Choreographer, or render thread.

Gate: desktop and Android animation behavior tests use the same fixtures and show no timer fallback.

## Phase 5 — Qualify frame pacing

Record callback arrival, JS scheduling, commit publication, GPU submission, and presentation timestamps. Verify 60 Hz and high-refresh operation, background throttling, resize, output migration, and teardown.

Gate: ordinary animation misses no presentation deadlines under the render benchmark workload and adds no continuously queued frame.
