# Linux Kernel Leverage Map

**Status:** snapshot 2026-04-26. Strategic-leverage framing for late-6.x and 7.0 kernel features that warrant Nucleus investment. This doc evaluates *what's worth building on*, ranked by leverage.

**Scope:** kernel features whose payoff is structural rather than incremental. Skips operational distro changes, toolchain bumps, and userspace protocol churn — see the platform survey for those. Includes some features already covered there when the strategic angle differs from the operational one.

---

## Top-line conclusion

The single highest-leverage kernel investment for Nucleus is **`sched_ext` integration**. Compositor-aware BPF scheduling is the difference between "feels like Linux" and "feels like macOS" perceptual quality, and is uniquely Linux leverage that no other platform offers. Track as the natural follow-on to the DisplayLink / VK_EXT_present_timing refactor (the Vulkan refactor exposes the per-output `predictedPresentNs` / `present_id` / `targetPresentNs` data a scheduler would consume).

Two other items deserve early treatment: **PREEMPT_RT thread policy** for the compositor render thread, and **DRM per-plane color pipeline** (already covered architecturally in the platform survey — re-emphasized here because it's tier-1 leverage, not just a feature flag).

Everything else is tier-2 or sandboxing groundwork.

---

## Tier 1 — Architectural leverage

### `sched_ext` (BPF schedulers)

**What landed:** mainline in 6.12. Lets a userspace process load a BPF program that implements a CPU scheduler. The kernel hands control to BPF for picking the next task. A scheduler can be hot-loaded, swapped, or unloaded without a reboot; the kernel falls back to CFS/EEVDF if the BPF scheduler crashes.

Production schedulers in `~/Developer/scx` (unmodified upstream clone): scx_lavd, scx_rusty, scx_layered, scx_bpfland, scx_flash, and ~10 more. Each is a Rust + BPF crate.

**Why it matters for nucleus:**
- Frame-deadline-aware scheduling. The compositor knows from `DisplayLink.predictedPresentNs(0)` exactly when the next vblank is. A Nucleus-aware scheduler can boost the render thread on the run-up to that deadline and demote afterward, rather than relying on CFS heuristics that don't know what a frame is.
- EDF-style ordering for Reanimated worklets and animation evaluation paths, with explicit demotion for background apps. RN's worklet thread becomes a first-class scheduling citizen.
- BPF scheduler is hot-loadable: ship as a userspace component bundled with the compositor, no kernel module, no patching. Fallback to system default on crash is transparent.
- Per-cgroup policies: app-level isolation gets sharper without sacrificing latency for foreground work.

**Integration shape:**
- Compositor publishes per-thread frame-deadline hints into a BPF map (one entry per scheduled thread, updated on transaction commit / animation start).
- A custom scx-style scheduler reads the map. Variants worth investigating: extend `scx_lavd` (Latency-Aware Virtual Deadline) which already has the right shape, or write a Nucleus-specific scheduler from scratch.
- Userspace control plane: a small Rust binary (the scheduler launcher) that loads/unloads, monitors, and falls back. Lives in the eventual nucleus distro.

**Caveats:**
- Sub-architectural-bet: kernel BPF + Rust userspace is a different surface from the Vulkan/CA refactor. Should be its own initiative, sequenced after DisplayLink data exposure lands.
- `sched_ext` ABI is still evolving. Pin to a specific kernel version range; expect rework on 6.x → 7.x transitions.
- Per-thread hint maps require care around cardinality — a transaction-heavy session can churn map entries faster than naive update patterns handle.

**Action:** track as the next architectural initiative after the present-timing refactor lands. Don't fold in.

---

### PREEMPT_RT mainlining

**What landed:** the final pieces of PREEMPT_RT merged into mainline in 6.12. Full realtime preemption no longer requires an out-of-tree patch set.

**Why it matters for nucleus:**
- Compositor render thread can run at SCHED_FIFO with bounded preemption. A non-RT compositor can be preempted mid-frame by any kernel work (RCU callbacks, IRQ tail processing); RT eliminates the "occasional 8ms hitch from a kworker" class of jitter.
- Pairs with `sched_ext`: BPF schedulers can declare RT-class threads and the kernel honors them.
- No userspace work — config + thread policy. Unusual leverage-to-effort ratio.

**Caveats:**
- Distros ship RT support inconsistently. Ubuntu 26.04 has a separate `linux-image-realtime` flavor; standard kernels are PREEMPT_DYNAMIC with lazy preemption (good baseline, not full RT).
- Misuse — putting too many threads at SCHED_FIFO — starves the system. Restrict to the render thread + DRM submission thread; never RT-class the JS / RN worklet thread.

**Action:** add `pthread_setschedparam(SCHED_FIFO, …)` to the render-server thread bring-up once the thread model is finalized. Document RT kernel as recommended for high-end deployments. Don't hard-require.

---

### DRM per-plane color pipeline

Tier-1 because the architectural leverage is structural, not just a feature toggle: the render-server's API surface should encode the Skia-side-vs-KMS-side split from day one.

---

## Tier 2 — Concrete scoped wins

### `IORING_REGISTER_PBUF_RING` + multishot recv

**What landed:** ring-mapped provided buffers (5.19, refined through 6.x) + multishot recv. Kernel hands a pre-registered buffer slot to userspace on each receive without a per-call buffer setup.

**Why it matters for nucleus:**
- Wayland socket reads are the highest-volume I/O in the compositor on a busy session. Pbuf ring eliminates the per-recv buffer allocation/registration shape.
- Multishot recv reduces SQE submission churn — a single SQE handles many recvmsg completions until the ring drains.
- Integration point: the in-tree pure-Zig Wayland server (`src/wayland/`) keeps the compositor io_uring-shaped, so provided-buffer receive support slots into that Wayland socket read path directly.

**Caveats:**
- Requires careful buffer-group sizing: undersized buffers cause `-ENOBUFS`, oversized waste pinned memory. Tune per-Wayland-client based on observed message rates.
- Works only for recv-shape ops; doesn't help send/page-flip/timer/DRM event paths.

**Action:** wire into the Wayland socket read path next time that path is touched. Not urgent on its own.

---

### `IORING_OP_FUTEX_WAIT` / `FUTEX_WAKE`

**What landed:** 6.7. Async futex operations via io_uring instead of `futex()` syscall.

**Why it matters for nucleus:**
- Cross-thread sync (RN JS thread ↔ compositor, render-server submission ↔ DRM commit) currently uses syscall-shape futex / mutex calls. Folding into the io_uring loop unifies wakeup paths.
- Single completion model: all "things I'm waiting for" become CQEs in one ring. Cancellation, timeout, linking all just work.
- Particularly useful for the eventual scx integration — the BPF scheduler can observe futex-via-uring waits as ring waits, simplifying the policy.

**Caveats:**
- `std.Io.Mutex` and `std.Io.Event` (Zig 0.16 names) are not yet io_uring-backed in Zig std. Adopting requires either a Nucleus-internal primitive or upstream work.
- The compositor's substrate is committed to io_uring (not `std.Io`); an io_uring-backed sync primitive should integrate with the active compositor ring directly when there is a concrete cross-thread path that needs it.

**Action:** open issue. Wire when there's a concrete cross-thread sync path being added or refactored; do not make it a dependency of the pure-Zig Wayland server/client work.

---

### `IORING_OP_SENDMSG_ZC` for fd passing

**What landed:** zero-copy sendmsg. Kernel pins userspace pages instead of copying. Especially relevant for SCM_RIGHTS fd passing on Unix sockets.

**Why it matters for nucleus:**
- The IPC direction memory (`project_ipc_direction.md`) commits to Unix sockets + CGS-shaped wire protocol. Compositor↔client traffic is the volume case; client buffer-handle and syncfd handoffs are the latency case.
- Zero-copy on the message path is a pure throughput win once message rates are high enough to matter (shell widgets and standalone apps posting frequent updates).

**Caveats:**
- Requires the sender's pages to remain stable until completion. Cannot reuse sending buffers in a tight loop without flow-control.
- Marginal gain at low message rates. Don't optimize prematurely.

**Action:** defer until IPC throughput is a measured concern.

---

### Async atomic page flip + tearing flag

**What landed:** 6.8. `DRM_MODE_PAGE_FLIP_ASYNC` works with atomic commits. Lets a frame opt into a tearing page-flip path when minimum latency outweighs tear-freedom.

**Why it matters for nucleus:**
- Game-mode / fullscreen-RN-Reanimated path: an app declares "lowest latency, accept tearing" and the compositor honors it via async atomic commit.
- Slot into the existing DRM scanout state machine; an additional commit flag, no new commit kind.

**Caveats:**
- Mixing tearing and non-tearing planes in a single commit is driver-dependent. AMD handles it cleanly; Nvidia and Intel inconsistent — verify before relying on per-plane tearing.
- VRR + tearing interaction is subtle. Pick one mental model per output and don't mix.

**Action:** add to the DRM scanout backend when a real consumer (game-mode Reanimated app, fullscreen video) lands. Not for the v1 baseline.

---

### AMDGPU userq (user-mode queues)

**What landed:** 6.13+, very recent. User-mode submission to GPU rings, bypassing kernel command-submit overhead. Conceptually similar to Windows GPU scheduler / hardware queues.

**Why it matters for nucleus:**
- Latency floor for compositor-side GPU work. The kernel command-submit path adds non-trivial overhead per submission; userq removes it.
- Composes with `sched_ext`: the BPF scheduler can observe GPU completion events via userq more directly than via DRM_IOCTL.

**Caveats:**
- AMD-only. Vendor fragmentation tax — Nvidia and Intel have nothing equivalent in mainline.
- Stability is fresh-paint; expect ABI churn through 6.x → 7.x.
- The Mesa userspace side (RADV) is still catching up; not all paths are userq-ready.

**Action:** track. Don't invest until ABI stabilizes and Mesa coverage is complete.

---

## Tier 3 — Sandbox primitives

For the standalone-app surface eventually hosting RN apps under nucleus's substrate, modern Linux gives a strong sandbox toolkit if used together. None of these is individually transformative; combined they are the modern Linux sandbox.

### Landlock v6 (6.10+)

Userspace-defined filesystem and network access rules without setuid helpers. Per-app filesystem visibility (read-only access to common paths, write access to per-app data dirs only) and per-app network restrictions (block listening on arbitrary ports, allow only specific outbound connections).

**Action:** part of the eventual app-sandbox layer. Design now, implement when standalone-app hosting lands.

### `mseal` (6.10)

Memory sealing — locks a memory region against subsequent `mprotect` / `munmap` / `mremap`. Combined with W^X discipline, prevents post-launch code injection. Particularly useful for sealing JIT'd RN/Hermes code regions after warm-up.

**Action:** wire into RN's Hermes integration for post-codegen sealing. Small change, real defense-in-depth.

### `pidfd_getfd` / `pidfd_send_signal`

Process-handle-based signaling and fd retrieval, replacing the racy `kill(pid, sig)` model. Cleaner app lifecycle: the compositor holds a pidfd per hosted app and can signal / inspect / clone-fd without TOCTOU windows.

**Action:** use from day one of the standalone-app process model. No reason to use the legacy pid path.

### io_uring cBPF filter (Topic 3 of platform survey)

Per-opcode cBPF filtering of io_uring submissions, with `fork()`/`clone()` inheritance. Closes the seccomp-vs-io_uring gap that previously forced sandboxed apps off io_uring.

Noted here for completeness of the sandbox toolkit.

---

## Skip list (intentionally not pursued)

- **DAMON, Multi-Gen LRU tuning** — server / memory-pressure workload concerns; not relevant to a desktop / compositor process.
- **bcachefs** — orthogonal; storage choice is a distro decision, not a Nucleus framework concern.
- **multipath TCP** — irrelevant; Nucleus has no native network surface.
- **BPF LSM** — overkill vs Landlock for the nucleus app-sandbox use case. Reach for it only if Landlock proves insufficient.
- **Memory tagging extension (MTE) on ARM** — promising for memory-safety but ARM-only and userspace-tooling-immature. Re-evaluate in a future cycle.
- **DRM cgroup memory accounting** — useful for multi-tenant servers; nucleus is single-user.
- **fanotify FAN_PRE_ACCESS** — not a fit for the use cases nucleus has.

---

## Action items derived from this document

Ranked by leverage:

1. **`sched_ext` integration as next architectural initiative.** Sequenced after the DisplayLink / VK_EXT_present_timing refactor exposes per-output deadline data. Investigate extending `scx_lavd` first; fall back to a Nucleus-specific scheduler if needed.
2. **PREEMPT_RT thread policy on the render thread.** Small change, real wins on contended systems. Add when the render-server thread model is finalized.
3. **`mseal` for Hermes JIT regions.** Small change, real defense-in-depth. Implement when the RN-on-Nucleus integration (`react-native-nucleus`) ships in standalone apps.
4. **`pidfd_*` from day one of the standalone-app process model.** No reason to start with legacy pids.
5. **`IORING_OP_FUTEX_WAIT/WAKE` adoption** for cross-thread sync paths as they're added/refactored. Don't retrofit existing code.
6. **`IORING_REGISTER_PBUF_RING` for Wayland socket reads** when that path is next touched.
7. **Async atomic page flip + tearing flag** when a game-mode / fullscreen-low-latency consumer materializes.

Items 1 and 2 are the high-leverage picks. Everything else is incremental.

---

## What this document does not change

- The Vulkan refactor (`compositor-vulkan-refactor.md`) — independent of these features, though `sched_ext` integration is its natural successor.
- The render-server architectural design — `sched_ext` integration consumes data the render-server publishes; doesn't reshape the render-server itself.

---

## Sources

Primary references:

- [sched_ext upstream repository (sched-ext/scx)](https://github.com/sched-ext/scx)
- [sched_ext documentation in mainline](https://www.kernel.org/doc/html/latest/scheduler/sched-ext.html)
- [PREEMPT_RT mainline merge coverage (LWN)](https://lwn.net/Articles/957123/)
- [io_uring futex ops (LWN, 6.7 cycle)](https://lwn.net/Articles/941090/)
- [AMDGPU userq introduction (Phoronix, 6.13 cycle)](https://www.phoronix.com/news/AMDGPU-User-Queues)
- [Landlock v6 (kernel.org docs)](https://www.kernel.org/doc/html/latest/userspace-api/landlock.html)
- [`mseal()` system call (LWN)](https://lwn.net/Articles/954936/)
- [DRM async atomic page flip (Phoronix, 6.8 coverage)](https://www.phoronix.com/news/DRM-Async-Page-Flip-Atomic)

Verify every URL before citing in shipping content; coverage churns and articles get reorganized.
