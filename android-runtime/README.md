# Nucleus Android Runtime

This package owns the Android 17 product, container contract, and host-side graphics
path. Collider materializes the pinned AOSP source, builds and release-signs the
standalone system images, validates their provenance and AVB chain, and installs the
runtime as an optional long-lived session capability.

## Implemented contract

- `NucleusAndroidGraphicsContract` defines the versioned broker messages, opaque
  buffer identities, dma-buf plane metadata, descriptor roles, and strict validation.
- `NucleusAndroidIPC` provides authenticated Unix `SOCK_SEQPACKET` transport with
  `SO_PEERCRED` checks and ordered `SCM_RIGHTS` descriptor transfer.
- Broker accept and connection lifecycle, Wayland runtime dispatch, broker replies, and
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
- The full Android desktop is Android's primary Composer display. Composer3
  exports each client target from the first boot-animation frame onward, so
  boot animation, lock screen, wallpaper, System UI, and Launcher3 inhabit the
  same ordinary `xdg_toplevel`. Application presentations use framework
  `VirtualDisplay` instances backed by opaque RGBX `AImageReader` surfaces.
  Both sources export Nucleus gralloc dma-bufs, allocation lifetime
  descriptors, and acquire fences into the same display-host presentation
  pipeline. `nucleus-android-display-host` commits them with Wayland explicit
  synchronization.
  Every imported buffer owns a separate release timeline. The host immediately
  returns a real pending native fence; one shared asynchronous reactor signals
  that fence only after the compositor retires the exact buffer, without
  blocking frame production or releasing the buffer early. Toplevel configure
  events publish primary Composer mode changes for the desktop and resize an
  application reader surface and virtual display in place. The host maps window
  coordinates into the current Android display space, forwards native seat
  events to Android input, and applies Android pointer-icon intent through
  `wp_cursor_shape_manager_v1` while the compositor retains sole ownership of
  the visible cursor.
- `NucleusAndroidContainerContract` defines the system-as-root LXC configuration,
  enforced project-owned AppArmor confinement, seccomp policy, subordinate-ID mapping,
  exact device surface, and APEX archive validation.
- `NucleusAndroidRuntimeCore` owns the complete runtime unit. Its privileged
  container launcher watches the user-side owner with `pidfd`, stops LXC if that
  owner disappears, and reconciles legacy orphan containers and their mount
  trees before launch. The private uinput node is owned by mapped Android
  `system`, and the Android bridge proves the device path by creating its native
  virtual mouse and keyboard during the versioned runtime handshake.
- The `nucleus_x86_64-cp2a-userdebug` Android 17 product emits separate immutable
  system, system-ext, product, and vendor images with release-signed APKs, APEXes, and
  AVB metadata.

## Verification

Run all agent-owned tests directly on the host:

```sh
source tools/host-env.sh
swift test --package-path android-runtime
```

Build and verify the signed Android image:

```sh
collider android-runtime image
```

The shared-allocation path is integrated into the production display host. Phase 2
source locking, product definition, signing, AVB validation, container configuration,
host-owned APEX mounting, instance-private delegated bpffs creation, token-aware
Android BPF loading, the SELinux-bypassed vold preparation path, the production
host-owned gfxstream socket/ring broker, and the Android 17 AIDL audio HAL are
implemented. Android receives the broker socket but no DRM node; the broker validates
that every graphics client belongs to the instance's subordinate UID range, while the
Composer3 topology socket remains restricted to the mapped Android system UID.
Collider loads Android netd's required host xtables modules before creating the
unprivileged network namespace. `vulkan.nucleus` fails closed rather than entering the
ranchu render-node path. The Nucleus Composer3 HAL and production Swift display host
own Android presentation during the session. The
complete signed image, package/APEX signature, APEX-payload, and AVB verification
pipeline passed in `.nucleus/runs/2026-07-25T05-33-29Z-655228`.

Run the installed desktop and Android runtime together from a free virtual terminal:

```sh
collider run --android
```

The supervisor starts Android only when `--android` selects the installed Android
session capability. Android remains alive for the session lifetime and stops before
the compositor and shell. Each instance receives a private `/dev/kmsg` transport whose
output is retained in `android-kmsg.log`; the runtime never exposes the host kernel log.
After Android `logd` starts, Collider retains every Android log buffer in
`android-logcat.log`. LXC TRACE output, matching host kernel audit events, and
tombstones are retained beside those streams, and failure output includes useful
tails from every nonempty log.

Bridge publication, Android boot, Launcher3 drawing, and virtual presentation are
diagnostic signals rather than terminal command-success conditions. Process exits,
repeated critical-service crashes, broken graphics synchronization, and container
contract violations remain runtime failures.
