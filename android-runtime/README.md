# Nucleus Android Runtime

This package owns the host-side Phase 1 graphics proof for the Android runtime. It
is intentionally standalone while the repository's top-level build command is being
migrated. It does not add an Android image, LXC runtime, or product HALs yet.

## Implemented contract

- `NucleusAndroidGraphicsContract` defines the versioned broker messages, opaque
  buffer identities, dma-buf plane metadata, descriptor roles, and strict validation.
- `NucleusAndroidIPC` provides authenticated Unix `SOCK_SEQPACKET` transport with
  `SO_PEERCRED` checks and ordered `SCM_RIGHTS` descriptor transfer.
- Broker accept/session readiness, Wayland runtime dispatch, broker replies, and
  syncobj release notifications all run through `NucleusLinuxReactor`. The only
  blocking Wayland operation is the library's explicitly setup-only registry
  bootstrap roundtrip.
- `NucleusAndroidGraphicsPlatform` matches Wayland `main_device` to a DRM render node
  and Vulkan physical device, rejects CPU Vulkan devices, intersects explicit DRM
  modifiers, allocates a three-buffer GBM ring, imports each exact dma-buf as a Vulkan
  image, and renders directly into it.
- The broker converts Vulkan `SYNC_FD` semaphore payloads into a shared acquire
  syncobj timeline. Every buffer owns a separate release timeline because compositor
  release order is not globally ordered. Release reuse is exposed through
  `drmSyncobjEventfd`; runtime code never performs a CPU fence wait.
- `NucleusAndroidGfxstreamTransport` provides sealed-memfd, lock-free SPSC command
  and response rings with eventfd wakeups and bounded backpressure. This is the
  process-transport substrate for the gfxstream guest and host adapters.
- The pinned guest gfxstream Vulkan ICD and static host renderer communicate only
  through those rings. The host renderer selects the broker GPU by device UUID,
  imports the exact broker dma-buf, and bridges compositor release and guest
  completion through `SYNC_FD` payloads without a CPU fence wait.
- `nucleus-android-gfxstream-workload` runs a deterministic 48-frame, three-buffer,
  two-generation Vulkan workload with resize, reuse, bounded-backpressure, failure,
  disconnect, and teardown coverage.
- `nucleus-android-surface-probe` reads real linux-dmabuf feedback, creates an
  `xdg_toplevel`, imports broker dma-bufs and syncobj timelines, commits acquire and
  release points, and records presentation feedback.

## Verification

Run all agent-owned tests directly on the host:

```sh
source tools/host-env.sh
swift test --package-path android-runtime
```

Produce a machine-readable qualification record for every DRM render node:

```sh
source tools/host-env.sh
android-runtime/scripts/qualify-phase1-graphics
```

The command runs the complete Swift test suite, builds the live workload, exercises
every local render node, validates the result and lifecycle JSON, and emits a support
archive under `android-runtime/.build/phase1-qualification/`. It fails if device
selection, exact dma-buf import, explicit synchronization, bounded backpressure,
lifecycle coverage, or any unsupported-capability check fails.

The combined gfxstream-to-Wayland qualification is a Collider-owned live hardware
workflow. Run it from a free virtual terminal with an explicitly selected GPU:

```sh
tools/collider qualify android-presentation \
  --drm-device /dev/dri/renderD129
```

Collider verifies that the selected GPU has a connected KMS output, builds and starts
a bounded private Nucleus session, launches the one-shot broker and persistent
gfxstream worker after compositor readiness, presents the broker's exact allocations
through the surface probe, validates every guest and Wayland lifecycle stage, shuts
the session down, and produces a support archive under
`.nucleus/qualifications/android-presentation/`. The 600 paced frames cycle through
the three distinctive buffer colors for an optional visual sanity check. Presentation
feedback and the recorded device and synchronization lifecycle determine the
machine-readable result.

## Remaining Phase 1 integration

The shared-allocation path is implemented: one broker-owned allocation is rendered
through gfxstream, committed by the surface probe, acknowledged by presentation
feedback, released by the compositor, and reused by gfxstream. The headless portion
passes on both local GPUs. The patched gfxstream and Mesa inputs are clean immutable
fork revisions, and the staged build validates them. Only the combined presentation
command against the live compositor remains.

The combined run needs one user action: invoke the Collider qualification from a free
virtual terminal. A monitor must be connected to the selected GPU because the same
physical device owns Vulkan rendering, GBM allocation, and KMS presentation. The RTX
4090 and RTX 4070 Ti in this workstation are the complete Phase 1 hardware matrix.
AMD, Intel, and hybrid-system qualification belongs to the later support phase.
