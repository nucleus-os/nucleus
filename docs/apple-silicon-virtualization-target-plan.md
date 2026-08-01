# Apple Silicon Virtualization Target Plan

Status: active.

## Invariant

Nucleus supports two runtime targets from one source graph, one product
inventory, and one set of architectural seams:

- **Linux amd64 bare metal.** The compositor owns real DRM/KMS hardware, real
  libinput devices, and a real Vulkan driver. The gfxstream host runs as a Linux
  process beside the compositor on the same kernel.
- **Apple silicon virtualization.** The identical compositor, shell, and Android
  runtime run as `linux/arm64` inside a `Virtualization.framework` VM on
  macOS/arm64. The compositor owns a paravirtual DRM/KMS device. The gfxstream
  host runs on macOS as the VM's virtio-gpu device implementation and renders
  through MoltenVK to Metal.

Neither target is a degraded fallback of the other. The difference between them
is expressed as two declared values and nothing else:

- **Scanout capability tier.** The DRM presenter negotiates what the output
  device can actually do — direct client scanout, hardware cursor plane, format
  modifiers, explicit out-fences, adaptive sync, leases — and composes
  accordingly. It does not branch on which kind of machine it is running on.
- **gfxstream host placement.** The gfxstream host is one role with one
  implementation. `local` placement runs it in a Linux process reached over a
  shared ring; `paravirtual` placement runs it on macOS reached across the
  virtio-gpu transport. Both placements export the same color buffers as guest
  dma-bufs with the same fence semantics, so the compositor's import path is
  identical.

Exactly one gfxstream host serves a running system. The Android runtime and the
compositor are always clients of the same host, the same resource namespace, and
the same fence timeline. Nested gfxstream translation is a defect, not a
configuration.

The macOS host process owns the VM, the virtio-gpu device model, the gfxstream
host, and Metal presentation. It owns no window management, no scene, no input
policy, and no compositor state. The guest remains the complete Nucleus system;
macOS is a display and device substrate.

No wall-clock estimates appear in this plan. Scope is expressed as targets,
files, structural moves, and verification gates.

## Preconditions

This plan lands on top of the destination model established by
[Manifest Portability and Swift SDK Plan](manifest-portability-and-swift-sdk-plan.md).
Phase 1 below begins after that plan's Phase 4 publishes immutable Swift SDK
generations and Collider selects every runtime build with an explicit
`--swift-sdk` and `--triple`. Adding destinations before that point would
multiply the environment-derived manifest state that plan exists to delete.

Two external behaviors are assumed resolved and are not re-derived here:

- A Wayland compositor using DRM atomic modesetting, GBM allocation, and dma-buf
  import comes up on a `VZCustomVirtioDevice` virtio-gpu device backed by a
  gfxstream context.
- A color buffer allocated by the macOS-side gfxstream host is importable inside
  the guest as a dma-buf carrying a usable fence.

Phase 5 and Phase 8 are the phases that would invalidate if either assumption
proves false, and each states the specific gate that proves it.

## Current State

The existing architecture already supplies the seams this target needs.

`PresentationBackend`
([`core/swift/Sources/NucleusRenderer/render/PresentationBackend.swift`](../core/swift/Sources/NucleusRenderer/render/PresentationBackend.swift))
is the render core's platform boundary. It trades only in `VkImage`,
dimensions, format, layout, usage flags, and semaphores, and it already carries
two implementations: DRM/KMS scanout in `NucleusCompositorRendererLinux` and a
Vulkan swapchain on Android. The `FrameTargetKind` enumeration, the
`tryDirectScanout` hook, and the `defersGpuResourceRetirement` contract are the
places the virtualization target attaches.

The gfxstream boundary is already a C ABI carrying opaque handles and scalars.
[`NucleusAndroidGfxstreamHostC.h`](../android-runtime/Sources/NucleusAndroidGfxstreamHostC/include/NucleusAndroidGfxstreamHostC.h)
exports color buffers as `nucleus_android_gfxstream_host_dmabuf` — a DRM format,
a DRM modifier, a plane offset and stride, a dma-buf fd, and paired
release/acquire `sync_file` callbacks. That struct is the placement-independent
contract; only its producer changes between placements.

Collider already models runner platform, execution platform, artifact target,
and execution backend as independent coordinates
([`collider/engine/Sources/ColliderCore/PlatformContract.swift`](../collider/engine/Sources/ColliderCore/PlatformContract.swift)),
already carries an Apple `container` OCI backend
([`collider/engine/Sources/ColliderRuntime/OCIExecutor.swift`](../collider/engine/Sources/ColliderRuntime/OCIExecutor.swift)),
and already builds both halves of gfxstream — the host backend static library
and the guest Mesa gfxstream Vulkan ICD — from the pinned `third-party/gfxstream`
and `third-party/mesa` submodules
([`collider/Sources/AndroidRuntimeColliderRecipe/AndroidRuntimeColliderRecipe.swift`](../collider/Sources/AndroidRuntimeColliderRecipe/AndroidRuntimeColliderRecipe.swift)).

The Android runtime already declares its kernel contract exactly.
[`AndroidRuntimeHostRequirements.swift`](../android-runtime/Sources/NucleusAndroidRuntimeCore/AndroidRuntimeHostRequirements.swift)
and
[`AndroidRuntimeKernelRequirements.swift`](../android-runtime/Sources/NucleusAndroidRuntimeCore/AndroidRuntimeKernelRequirements.swift)
require binderfs, EROFS, the BPF filesystem, unified cgroup v2, enabled
AppArmor, subordinate UID and GID ranges, the LXC tool set, a readable kernel
configuration, and a loadable-module set covering the legacy xtables ABI that
Android `netd` uses. That requirement list is the guest kernel configuration
specification; it does not need to be invented.

Four properties of the current state are the actual work.

- Every runtime destination is amd64. `ArtifactTarget.linuxX86_64` and
  `ExecutionPlatform.linuxAMD64OCI` are the only Linux values, the OCI executor
  and `collider doctor` gate on `(.linux, .x86_64)`, the Swift platform recipe
  hardcodes `linux-amd64`, `x86_64-unknown-linux-gnu`, and `linux-x86_64`, and
  the AOSP graph builds `nucleus_x86_64`.
- The Nucleus runtime graph has no macOS artifact target. Collider is the only
  first-party product Xcode builds natively.
- The DRM presenter requires the full modern KMS surface unconditionally.
  Direct client scanout, hardware cursor planes, `VK_EXT_image_drm_format_modifier`
  negotiation, syncobj timelines, and DRM leases are treated as present.
- The gfxstream host has exactly one placement, and it is implicit. The Android
  runtime, its broker, and its shared-ring transport assume the host is a
  sibling Linux process on the same kernel.

## Phase 1 — Admit the New Destinations

`ColliderCore` gains `ArtifactTarget.linuxARM64`, `ArtifactTarget.macOSARM64`,
and `ExecutionPlatform.linuxARM64OCI`. Every existing `(.linux, .x86_64)`
decision becomes a decision over the declared coordinate rather than a match
against the single supported value:
[`OCIExecutor.swift`](../collider/engine/Sources/ColliderRuntime/OCIExecutor.swift)
platform validation and its `amd64`/`arm64` OCI platform string mapping,
[`Doctor.swift`](../collider/Sources/ColliderCommands/Doctor.swift) runner
capability reporting, and the architecture and multiarch constants in
[`CommandSupport.swift`](../collider/Sources/ColliderCommands/CommandSupport.swift)
and
[`VulkanTestLanes.swift`](../collider/Sources/ColliderCommands/VulkanTestLanes.swift).

The Swift platform recipe stops encoding one Linux architecture.
[`SwiftPlatformColliderRecipe.swift`](../collider/Sources/SwiftPlatformColliderRecipe/SwiftPlatformColliderRecipe.swift)
derives its package suffix, host target triple, host tag, staging library paths,
and retained SDK entry set from the requested destination.
[`Toolchain.swift`](../collider/Sources/ColliderCommands/Toolchain.swift)
derives `platformID` and the build-workspace path the same way, so
`linux-amd64` and `linux-arm64` generations coexist in the platform-generation
cache without colliding.

macOS/arm64 becomes a genuine runtime artifact target rather than only a runner
platform. This is a deliberate amendment to the manifest portability plan's
statement that no Nucleus runtime product has a host destination: Xcode 27
builds the macOS host product natively, and that build is the second native
exception alongside Collider's own bootstrap.

Verification: `collider doctor` reports the expanded destination inventory, task
identities differ across the three Linux and macOS coordinates for the same
product, and requesting an unprovisioned destination fails during planning
rather than during compilation.

## Phase 2 — Build the Existing Linux Graph for arm64

A pinned `linux/arm64` OCI builder image joins the existing `linux/amd64` one.
The Swift 6.4 platform generation, Foundation, the render native SDK, the React
Native native SDK, and the Mesa and gfxstream artifacts build for
`aarch64-unknown-linux-gnu` through Apple `container` on the M2 Ultra, natively
rather than through Rosetta.

Nothing in the runtime source graph is expected to change. Anything that does —
an alignment assumption, an atomics width assumption, a Vulkan structure layout
assumption, a hardcoded page size — is corrected in place for both destinations
rather than conditionally compiled. The 16 KiB maximum-page-size linker contract
already declared for Android arm64 is the model for the guest page-size
question.

The complete Linux product closure is built and tested for arm64 in the pinned
container: compositor, shell, window client, config service, session and IPC
tiers, Android runtime host, and every test target. Vulkan-dependent lanes run
against the staged Mesa lavapipe ICD, which gives real arm64 Vulkan coverage
with no GPU and no VM.

Verification: the arm64 product closure builds from clean scratch, the exported
symbol inventory matches the amd64 inventory modulo architecture-specific
symbols, and the headless, lavapipe, sanitizer, and unit lanes pass on
`linux/arm64`.

## Phase 3 — Own the Guest Kernel

The VM's kernel becomes a first-party Collider component with a pinned source
submodule, a checked-in configuration, and a lock file, in the same shape as the
Swift toolchain and AOSP graphs. Apple's `containerization` kernel is not used;
it ships no loadable modules, no AppArmor, and no Android support.

The configuration is derived mechanically from the contract the Android runtime
already declares, not authored by inspection. Every entry in
[`androidRuntimeRequiredKernelModules`](../android-runtime/Sources/NucleusAndroidRuntimeCore/AndroidRuntimeKernelRequirements.swift)
must be a loadable module. Binderfs, EROFS, the BPF filesystem, unified cgroup
v2, namespaces, seccomp filtering, overlayfs, loop devices, and AppArmor as an
enabled LSM must be present because
[`AndroidRuntimeHostRequirements.swift`](../android-runtime/Sources/NucleusAndroidRuntimeCore/AndroidRuntimeHostRequirements.swift)
probes for them. `/proc/config.gz` must be readable because the same file reads
it. The virtualization target adds virtio-gpu with its DRM driver, the virtio
transport devices the VM exposes, and io_uring for the Linux host reactor.

The build produces the kernel image, the module set, and the configuration blob
as one addressed artifact. `collider doctor` gains a lane that validates a
built kernel against the runtime requirement list directly, so a configuration
regression is caught at build time rather than at Android bring-up.

Verification: the kernel builds reproducibly for arm64 from the pinned source,
the doctor lane passes against the requirement list, and the AppArmor profile at
[`android-runtime/container/lxc-nucleus-android.apparmor`](../android-runtime/container/lxc-nucleus-android.apparmor)
loads under `apparmor_parser` on a booted instance of it.

## Phase 4 — Boot the Guest from the macOS Host Product

`NucleusMacHost` enters the package graph as a macOS/arm64 product: a
`nucleus-mac-host` executable over a `NucleusMacHostRuntime` library. It owns
the `VZVirtualMachineConfiguration`, the boot loader pointing at the Phase 3
kernel, the root and data storage, the console, networking, and the vsock
channel that carries the host-to-guest control protocol.

The control protocol reuses the existing session and IPC contract tiers rather
than introducing a new one. `NucleusSessionProtocol` is already a supported
external product and is already pure Swift with no C++ interop, so it compiles
for macOS unchanged and is the correct carrier for lifecycle, output topology,
and configuration exchange across the VM boundary.

No graphics device exists yet in this phase. The guest boots, mounts its
filesystems, and runs the Android runtime host-requirements doctor to completion
inside the VM. That is the gate that proves the kernel, the userspace layout,
and the LXC prerequisites before any GPU work begins.

Verification: the VM boots the Phase 3 kernel and the Phase 2 arm64 userspace,
the host-requirements resolution succeeds inside the guest with no failures, and
the vsock control channel completes a session handshake with the macOS host.

## Phase 5 — Implement the virtio-gpu Device and the macOS gfxstream Host

The macOS host product gains the virtual GPU. `VZCustomVirtioDeviceConfiguration`
declares the standard virtio-gpu device identity, its control and cursor queues,
its negotiated feature set, and its shared-memory regions. The Swift layer owns
configuration, the device and configuration delegates, queue element delivery,
guest memory mappings, shared-region mapping, and lifecycle. It does not decode
the virtio-gpu protocol.

`NucleusVirtioGPUFrontendCxx` owns the protocol: command decoding, context and
resource identity, capability sets, resource blobs, fences, scanout and cursor
semantics, reset, and validation of every length, offset, and identifier
arriving from the guest. It reaches the gfxstream renderer API directly. The
Swift-to-C++ boundary follows the established repository pattern — opaque
handles and scalars only, `extern "C"` guards on every non-inline first-party C
declaration, and `noexcept` entry points with internal catch-all handling
because Swift cannot catch C++ exceptions.

The gfxstream host backend builds for macOS/arm64 from the same pinned
`third-party/gfxstream` submodule that already produces the Linux static
library. MoltenVK joins the graph as a pinned component of the macOS native SDK.
`NucleusMetalPresenter` owns the `CAMetalLayer` and consumes the host-side image
gfxstream produces; no full-resolution readback or per-frame upload exists in the
presentation path.

The delegate callback on the device's serial queue validates, captures or maps
memory, enqueues, and returns. It never waits on Metal completion, shader
compilation, a GPU fence, or drawable acquisition. Save and restore is not
supported for this device.

The guest-side gate is the existing Vulkan lane probe
([`compositor/compositor-core/Sources/NucleusVulkanLaneProbe/main.swift`](../compositor/compositor-core/Sources/NucleusVulkanLaneProbe/main.swift))
running inside the VM against the guest Mesa gfxstream ICD. It must report the
extension surface the renderer requires — `VK_KHR_external_memory_fd`,
`VK_KHR_external_semaphore_fd`, `VK_EXT_external_memory_dma_buf`, and
`VK_EXT_image_drm_format_modifier` — because the compositor's dma-buf import and
scanout allocation depend on all four. An absent extension is resolved in the
guest ICD or in the device model, not by weakening the renderer's declared
requirements.

Verification: the guest enumerates the virtio-gpu device and binds the DRM
driver, the lane probe passes inside the VM, a Vulkan workload renders through
gfxstream to Metal and reaches the macOS window, and the device survives guest
reboot with every retained guest-memory mapping discarded and rebuilt.

## Phase 6 — Negotiate Scanout Capability in the DRM Presenter

`NucleusCompositorRendererLinux` gains an explicit `ScanoutCapabilities` value
resolved once per output device at bring-up. It declares direct client scanout,
hardware cursor plane, format-modifier negotiation, explicit out-fence delivery,
adaptive sync, and lease availability. The presenter, the cursor path, the
buffer allocator, and the Wayland dmabuf feedback advertisement consume that
value.

This replaces the current unconditional assumption of the full modern KMS
surface. The repository posture of hard-requiring modern features stands for
capabilities the renderer's correctness depends on; it does not extend to
optional KMS acceleration paths that a conforming device may legitimately lack.
`tryDirectScanout` already returns `false` for backends that never bypass
composition, so the composition fallback exists and is exercised — this phase
makes the choice a declared capability rather than a backend identity.

The affected files are the presenter and its allocator
([`DRMScanoutPresenter.swift`](../compositor/compositor-core/Sources/NucleusCompositorRendererLinux/DRMScanoutPresenter.swift),
[`DRMScanoutBufferAllocation.swift`](../compositor/compositor-core/Sources/NucleusCompositorRendererLinux/DRMScanoutBufferAllocation.swift)),
the atomic commit path, the cursor plane and color cursor paths, the client
scanout path, and the dmabuf feedback and layout validation in
`NucleusCompositorWaylandRuntime`. Bare-metal amd64 resolves to the full
capability set and its behavior is unchanged; the paravirtual device resolves to
composed presentation with a composited cursor and linear scanout.

This phase lands after Phase 5 so the paravirtual tier is defined by measured
device capability rather than by anticipated device capability.

Verification: the presenter contract tests cover both capability resolutions,
the amd64 bare-metal path produces an unchanged frame trace and unchanged direct
scanout hit rate, and the compositor completes bring-up and renders continuously
inside the VM on the paravirtual device.

## Phase 7 — Complete Input, Seat, and Output Topology in the VM

The VM's virtio input devices surface as guest evdev nodes and flow through the
existing libinput, xkb, seat, and dispatch stack unchanged. The macOS host
translates its own event stream into those devices and owns nothing above the
device layer.

Output topology becomes bidirectional over the vsock control channel. A macOS
window resize, display change, or scale change updates the virtio-gpu device
configuration, the guest observes a KMS hotplug or mode change, and the existing
output topology reconciler drives the compositor's response. The reverse
direction reports the guest's presentable outputs so the macOS window can size
itself to the compositor rather than the compositor to the window.

Cursor handling follows the Phase 6 capability tier: with no usable hardware
cursor plane the cursor is composited in the guest, and the macOS host hides the
native pointer over the presentation view so exactly one cursor is visible.

Verification: input latency instrumentation shows events reaching guest evdev
well inside one refresh interval, a macOS window resize produces a clean guest
mode change with no frame loss beyond the reconfiguration, and keyboard layout,
modifiers, scroll, and pointer capture behave identically to the bare-metal
target.

## Phase 8 — Unify gfxstream Host Placement and Bring Up Android

The gfxstream host becomes an explicit placement rather than an implicit
sibling process. `NucleusAndroidGraphicsContract` declares
`AndroidGfxstreamHostPlacement` with `local` and `paravirtual` cases. The
Android runtime, the GPU broker, and the graphics platform resolve the placement
once at bring-up and reach the host through the corresponding transport: the
existing shared ring for `local`, the virtio-gpu context for `paravirtual`.

Under `paravirtual` placement, no gfxstream host runs inside the VM. The Android
guest's command stream is carried across virtio-gpu to the single macOS-side
host, which is the same host the compositor's own rendering already goes
through. Android and the compositor share one resource namespace and one fence
timeline. The in-VM gfxstream host process is not started on this target, and
the double-translation path it would create is a defect condition the bring-up
path rejects explicitly.

The color buffer contract does not change. The macOS host allocates the buffer,
exposes it into the guest as a virtio-gpu blob-backed dma-buf, and the existing
`nucleus_android_gfxstream_host_dmabuf` shape carries the DRM format, modifier,
offset, stride, fd, and the release and acquire `sync_file` callbacks to the
compositor. The compositor's import path, its Wayland dmabuf advertisement, and
its scene placement of Android surfaces are unchanged.

Android itself runs in LXC inside the guest exactly as it does on bare metal,
against the Phase 3 kernel. The AOSP graph gains a `nucleus_arm64` product
alongside `nucleus_x86_64`; the device configuration, the product workflow in
[`AOSPProductWorkflow.swift`](../collider/engine/Sources/ColliderRuntime/AOSPProductWorkflow.swift),
and the five `nucleus_x86_64` references in
[`AndroidRuntimeColliderRecipe.swift`](../collider/Sources/AndroidRuntimeColliderRecipe/AndroidRuntimeColliderRecipe.swift)
become product-parameterized. The guest Mesa gfxstream ICD builds for Android
arm64, which the Swift Android SDK and NDK already support.

SurfaceFlinger does not composite a virtual Android display in the normal path.
Android remains a window-metadata source and a buffer producer; the Nucleus
compositor remains the only compositor of record. This is already the bare-metal
architecture and it is preserved verbatim.

Verification: an Android application surface produced inside the VM appears in
the compositor scene as a dma-buf-backed node with correct fencing, the resource
and fence namespaces are provably shared with the compositor's own rendering, no
gfxstream host process exists inside the guest, and the bare-metal `local`
placement produces unchanged behavior on amd64.

## Phase 9 — Qualify Frame Pacing and Latency

The presentation telemetry correlator gains end-to-end stage timestamps that
span the VM boundary: macOS event received, virtio input descriptor submitted,
guest evdev delivery, compositor or Android dispatch, application frame
submitted, gfxstream host submission received, Metal command buffer scheduled,
GPU completion, drawable presented. Correlation across the boundary uses the
existing session identity rather than a new one.

The pacing contract is that virtualization adds no buffered frame. Drawable
count, drawable acquisition timing, present scheduling, compositor buffer depth,
and Android buffer queue depth are tuned as one system against that contract.
Command submission is batched, fences are timeline-based, and completion is
asynchronous; per-command host-to-guest round trips are treated as defects.

Full-resolution CPU copies in the steady-state frame path are prohibited
outright and the qualification lane asserts their absence rather than measuring
their cost.

Verification: measured against a 120 Hz presentation target, the guest observes
no additional buffered frame relative to the bare-metal target, host-input to
guest-event stays inside a single-digit fraction of a millisecond, gfxstream
decode and dispatch stays inside the ordinary UI frame budget, and missed
compositor deadlines during ordinary desktop, scrolling, video, and Android
application use stay inside the declared threshold.

## Phase 10 — Settle Qualification Roles and Documentation

The virtualization target becomes a declared qualification role with its own
lane, alongside the existing Linux qualifier and GPU/DRM qualifier roles. The
M2 Ultra hosts it natively.

[Remote Development, macOS Builder, and Self-Hosted Runner Plan](github-actions-macos-builder-and-self-hosted-runner-plan.md)
currently states that the GPU/DRM qualifier role is not replaced by a Linux VM
on the Mac. That statement is correct about *substitution* and becomes wrong as
written once the VM is a shipping target. It is rewritten to distinguish the two
roles explicitly: the GPU/DRM qualifier qualifies the bare-metal amd64 target on
real hardware, and the virtualization qualifier qualifies the Apple silicon
target on the M2 Ultra. Neither qualifies the other's artifacts.

`AGENTS.md` and `CLAUDE.md` state the two supported runtime targets, the two
declared seams that distinguish them, the single-gfxstream-host invariant, and
the macOS host product's position as the second native-build exception. The
manifest portability plan's destination inventory is amended to list Linux
amd64, Linux arm64, Android arm64, Android amd64, and macOS arm64.

Verification: `collider doctor`, `collider bootstrap`, `collider build`, and
`collider test` pass for every declared destination from the documented
fresh-clone sequence, and the qualification lanes for both runtime targets pass
from the same source revision.

## Final Verification Gates

The target is complete only when all of these pass in order:

1. The arm64 Linux product closure builds and tests from clean scratch in the
   pinned `linux/arm64` container.
2. The guest kernel builds reproducibly and satisfies the Android runtime's
   declared requirement list under the doctor lane.
3. The VM boots the first-party kernel and userspace, and the Android
   host-requirements resolution succeeds inside the guest.
4. The Vulkan lane probe passes inside the VM against the guest gfxstream ICD
   with every renderer-required extension present.
5. The compositor completes bring-up and renders continuously on the paravirtual
   scanout capability tier.
6. The bare-metal amd64 target's frame trace, direct scanout hit rate, exported
   symbol inventory, and qualification lanes are unchanged by every phase above.
7. Android applications render into the compositor scene inside the VM through a
   single gfxstream host, with shared resource and fence namespaces and no guest
   gfxstream host process.
8. Input, output topology, cursor, and resize behavior match the bare-metal
   target's observable contract.
9. The pacing contract holds: no additional buffered frame, no full-resolution
   CPU copy in the frame path, deadline misses inside threshold.
10. Both qualification roles pass from one source revision, and the documentation
    states the two-target contract.

## Out of Scope

Running the compositor natively on macOS is not a goal and is not a fallback.
The compositor is a Wayland compositor with a libinput seat, an io_uring
reactor, DRM leases, and an LXC-contained Android runtime; there is no
meaningful portion of it that survives removal of the Linux kernel.

Rosetta-translated amd64 userspace inside the VM is not a supported
configuration for any Nucleus component. It is available for third-party binary
compatibility inside Android and nowhere else.

Custom-device save and restore, VM snapshotting, and live migration are not
supported for the virtio-gpu device.

macOS guest support, an x86_64 macOS host, and any non-Apple hypervisor backend
are out of scope. The existing AOSP Repo-manifest exception to submodule
ownership, the C++ interop bridge patterns, and the Swift visibility contract
are unchanged by this plan.
