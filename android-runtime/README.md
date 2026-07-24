# Nucleus Android Runtime

This package owns the Android 17 product, container contract, and host-side graphics
path. Collider materializes the pinned AOSP source, builds and release-signs the
standalone system images, validates their provenance and AVB chain, and drives the
bounded container and presentation workflows.

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
- `NucleusAndroidGfxstreamTransport` provides sealed-memfd SPSC command and
  response rings with distinct producer/consumer endpoints, armed eventfd waits,
  and bounded backpressure. This is the process-transport substrate for the
  gfxstream guest and host adapters.
- The pinned guest gfxstream Vulkan ICD and static host renderer communicate only
  through those rings. The host renderer selects the broker GPU by device UUID,
  imports the exact broker dma-buf, and bridges compositor release and guest
  completion through `SYNC_FD` payloads without a CPU fence wait.
- `nucleus-android-gfxstream-workload` runs a deterministic 48-frame, three-buffer,
  two-generation Vulkan workload with resize, reuse, bounded-backpressure, failure,
  disconnect, and teardown coverage.
- `nucleus-android-shared-ring-stress` alternates empty and full states across
  process mappings and emits small-message and default-slot throughput plus
  notification diagnostics.
- `nucleus-android-surface-probe` reads real linux-dmabuf feedback, creates an
  `xdg_toplevel`, imports broker dma-bufs and syncobj timelines, commits acquire and
  release points, and records presentation feedback.
- `NucleusAndroidContainerContract` defines the system-as-root LXC configuration,
  generated AppArmor confinement, seccomp policy, subordinate-ID mapping, exact
  device surface, and APEX archive validation.
- The `nucleus_x86_64-cp2a-userdebug` Android 17 product emits separate immutable
  system, system-ext, product, and vendor images with release-signed APKs, APEXes, and
  AVB metadata.

## Verification

Run all agent-owned tests directly on the host:

```sh
source tools/host-env.sh
swift test --package-path android-runtime
```

The combined gfxstream-to-Wayland qualification is a Collider-owned live hardware
workflow. Run it from a free virtual terminal with an explicitly selected GPU:

```sh
collider qualify android-presentation \
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

Build and verify the signed Android image:

```sh
collider android-runtime image
```

The Phase 1 shared-allocation and combined presentation paths are complete. Phase 2
source locking, product definition, signing, AVB validation, container configuration,
host-owned APEX mounting, instance-private delegated bpffs creation, token-aware
Android BPF loading, and the SELinux-bypassed vold preparation path are implemented.
The current signed image passed the complete AOSP build, package/APEX signature,
APEX-payload, and AVB verification pipeline in
`.nucleus/runs/2026-07-24T19-50-29Z-2403572`. The remaining Phase 2 gate is the
user-run framework boot:

```sh
collider android-runtime framework-boot
```

Collider gives each framework-boot instance a private `/dev/kmsg` transport and
retains its output in `android-kmsg.log`; it never exposes the host kernel log.
After Android `logd` starts, Collider retains every Android log buffer in
`android-logcat.log`. LXC TRACE output, matching host kernel audit events, and
tombstones are retained beside those streams, and failure output includes useful
tails from every nonempty log.

It must reach `sys.boot_completed=1` under the Phase 2 AppArmor, seccomp, capability,
device, and subordinate-user-namespace contract. Enforcing Android SELinux lands with
the integrated Nucleus host policy during Phase 7 security hardening.
