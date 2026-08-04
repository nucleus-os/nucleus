# Nucleus Android Runtime

## Product invariant

Android 17 is an independently signed, architecture-specific downloadable add-on.
The base Nucleus OS never contains Android executables, images, AOSP tools, policy,
private signing material, or an Android capability declaration. It contains only the
generic session supervisor and `android-addon-compatibility.json` for its exact build,
kernel contract, and architecture.

This package owns the Android product, container contract, and host-side graphics
path. Collider materializes the pinned AOSP source, builds and release-signs the
standalone system images, validates their provenance and AVB chain, and produces the
inputs for the independently signed add-on artifact.

An installed artifact has this shape:

```text
<android-add-on-store>/
  generations/<manifest-content-identity>/
    addon-manifest.json
    addon-manifest.json.sig
    image-provenance.json
    images/
    lib/
    libexec/
    share/nucleus/android/
  current -> generations/<manifest-content-identity>
  session-capabilities/android.json

<android-state-root>/
  data/
```

The signed manifest declares every payload file by relative path, size, SHA-256,
executable bit, Android release/build, architecture, exact Nucleus build identity,
and kernel capability identity. Installation verifies the publisher signature,
compatibility, complete payload closure, and the absence of symlinks or undeclared
files before atomically replacing `current`. The capability declaration is derived
locally after verification and always addresses `current`; it is not publisher-owned
input. Deactivation and uninstall retain the disjoint persistent state root.

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
- The current `nucleus_x86_64-cp2a-userdebug` Android 17 product emits separate immutable
  system, system-ext, product, and vendor images with release-signed APKs, APEXes, and
  AVB metadata. The add-on format already rejects architecture mismatches and supports
  `arm64`; publishing an ARM64 artifact additionally requires the corresponding
  `nucleus_arm64` AOSP product rather than translating an x86_64 Android userspace.

## Verification

Run all agent-owned tests directly on the host:

```sh
source tools/host-env.sh
swift test
```

Build and verify the signed Android image inputs:

```sh
collider android-runtime image
```

On the matching Linux release architecture, build the add-on host executables,
assemble their relocated ELF closure with the current signed AOSP generation, and
sign the downloadable directory:

```sh
collider android-runtime package-addon \
  --compatibility /opt/nucleus/current/share/nucleus/android-addon-compatibility.json \
  --aosp-signing-key /secure/android-avb-release-private.pem \
  --addon-signing-key /secure/android-addon-publisher-private.pem \
  --output ./nucleus-android-addon
```

The AOSP AVB private key is used only to derive the public verification key placed in
the artifact and prove that it verifies the assembled image chain. Neither that
private key nor the add-on publisher private key enters the output. `--runtime-root`
and `--aosp-generation` override the release inputs for controlled build environments.

On Nucleus OS, activate a fully assembled artifact only against its matching base
runtime. This uses the installed product manager and does not require a source checkout
or Collider:

```sh
sudo nucleus addon install ./nucleus-android-addon \
  --base-prefix /opt/nucleus/current \
  --store-root /opt/nucleus/addons/android \
  --state-root /var/lib/nucleus/android
```

Production base images pin the add-on publisher trust root at
`share/nucleus/trust/android-addon-publisher.pem`. `--trust-key` is an explicit
development/recovery override; downloaded content never supplies its own trust key.
The release installer receives the public key through
`NUCLEUS_ANDROID_ADDON_TRUST_KEY`, validates it with OpenSSL, and copies it into the
base generation before calculating that generation's add-on compatibility identity.

`sudo nucleus addon deactivate` removes only the capability and active pointer.
`sudo nucleus addon uninstall` also removes all installed immutable generations. Both
retain `/var/lib/nucleus/android`. Collider exposes the same lifecycle under
`collider install android-addon` only for checkout-local development stores.

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
pipeline is enforced by the current Collider image verification workflow.

Run the installed desktop and Android runtime together from a free virtual terminal:

```sh
collider run --android
```

The supervisor starts Android only when `--android` selects the add-on's active Android
session capability. A missing, inactive, or incompatible add-on fails before session
launch. Android remains alive for the session lifetime and stops before the compositor
and shell. Each instance receives a private `/dev/kmsg` transport whose
output is retained in `android-kmsg.log`; the runtime never exposes the host kernel log.
After Android `logd` starts, Collider retains every Android log buffer in
`android-logcat.log`. LXC TRACE output, matching host kernel audit events, and
tombstones are retained beside those streams, and failure output includes useful
tails from every nonempty log.

Bridge publication, Android boot, Launcher3 drawing, and virtual presentation are
diagnostic signals rather than terminal command-success conditions. Process exits,
repeated critical-service crashes, broken graphics synchronization, and container
contract violations remain runtime failures.
