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
  release points, and records presentation feedback. It is a Phase 1 hardware
  qualification harness, not an Android runtime presentation path.
- The Nucleus Composer3 AIDL HAL forces client composition and submits
  SurfaceFlinger's client-target dma-buf and acquire fence through an authenticated
  instance socket. `nucleus-android-display-host` is the production continuation of
  the Phase 1 surface: it owns the one Android `xdg_toplevel`, commits the real client
  target with Wayland explicit synchronization, and returns an independent Composer
  present fence that signals only when the exact commit receives physical
  `wp_presentation` feedback. Wayland release points remain exclusively responsible
  for client-allocation retirement. No synthetic color workload runs during framework
  boot.
- `NucleusAndroidContainerContract` defines the system-as-root LXC configuration,
  enforced project-owned AppArmor confinement, seccomp policy, subordinate-ID mapping,
  exact device surface, and APEX archive validation.
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

The Phase 1 shared-allocation and qualification paths are complete. Phase 2
source locking, product definition, signing, AVB validation, container configuration,
host-owned APEX mounting, instance-private delegated bpffs creation, token-aware
Android BPF loading, the SELinux-bypassed vold preparation path, the production
host-owned gfxstream socket/ring broker, and the Android 17 AIDL audio HAL are
implemented. Android receives the broker socket but no DRM node; the broker validates
that every graphics client belongs to the instance's subordinate UID range, while the
Composer3 display socket remains restricted to the mapped Android system UID.
Collider loads Android netd's required host xtables modules before creating the
unprivileged network namespace. `vulkan.nucleus` fails closed rather than entering the
ranchu render-node path. The Nucleus Composer3 HAL and production Swift display host
now replace the synthetic presentation workload during framework boot. The
complete signed image, package/APEX signature, APEX-payload, and AVB verification
pipeline passed in `.nucleus/runs/2026-07-25T05-33-29Z-655228`. The remaining
Phase 2 gate is the user-run framework boot:

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
the integrated Nucleus host policy during Phase 6 security hardening.
