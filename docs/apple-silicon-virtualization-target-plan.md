# Apple Silicon Virtualization Target Plan

Status: deferred.

## Invariant

Nucleus ships one Linux system on two hardware targets:

- **Linux/amd64 bare metal.** The compositor renders with the native Vulkan
  driver and presents through the physical DRM/KMS device. Android runs in LXC.
  Its gfxstream host is a Linux process on the same kernel and physical GPU.
- **Apple silicon virtualization.** The compositor and an arm64 Android 17
  userspace run inside one arm64 Linux VM created by
  `Virtualization.framework`. Both use one standard virtio-gpu device. One
  gfxstream renderer in the macOS host implements that device through MoltenVK
  and presents into a caller-owned `CAMetalLayer`. Selected third-party x86_64
  Linux applications run inside that same arm64 guest through macOS 27's
  integrated Intel binary translation facility.

The compositor remains the only compositor of record on both targets. Android
produces application surfaces and window metadata; it does not first compose a
virtual Android display. The macOS process owns VM lifecycle, virtual devices,
the AppKit window, the Metal layer, and host-side presentation. It owns no
Wayland scene, window-management policy, Android window policy, or compositor
state.

The Apple target has exactly one virtio-gpu device and one host gfxstream
renderer. The Linux compositor, Android, and translated application processes
use separate gfxstream contexts in that renderer. They share an image by
sharing the guest's virtio-gpu GEM object through PRIME/dma-buf and transfer
readiness through `sync_file` or DRM syncobj semantics. They do not depend on
one global context or one global fence timeline.

A Linux dma-buf file descriptor never exists on macOS. Guest userspace creates
or imports a virtio-gpu resource, the Linux virtio-gpu driver owns the GEM
object, and guest processes exchange the PRIME fd entirely inside Linux. The
macOS device model sees resource identifiers, mapped guest memory, queue
commands, and fence identifiers; it maps those identifiers to gfxstream and
MoltenVK objects.

Compositor-owned scanout allocation is Vulkan-first on both targets:

1. Vulkan allocates the renderable image and exportable device memory.
2. Vulkan exports a dma-buf in Linux.
3. DRM imports the dma-buf and creates the KMS framebuffer.
4. Skia Graphite renders into the original `VkImage`.

GBM does not allocate compositor-owned output buffers. Client dma-buf import
remains a separate supported path.

The steady-state frame path performs no CPU readback, full-frame `memcpy`, or
per-frame CPU texture upload. GPU composition, format conversion, and blits are
allowed only when recorded and attributed. Virtualization adds no queued frame.
These are measured contracts, not uses of the phrase “zero-copy.”

The target hard-requires the renderer's authoritative Vulkan contract, including
Vulkan 1.4 and every extension and entry point declared by
[`NucleusVulkanRequirements.swift`](../core/swift/Sources/NucleusRenderer/render/NucleusVulkanRequirements.swift).
Missing requirements fail device creation and target qualification. There is no
software renderer, streamed-display path, second gfxstream host, reduced
extension tier, or retained GBM output path.

The Apple target also hard-requires the exact pinned Mesa Zink, DXVK, and
vkd3d-proton Vulkan profiles. Each profile includes numerical properties and
limits as well as extensions and features. Vulkan 1.4 conformance does not
imply any client profile, and a profile exposed by Mesa but not implemented
through gfxstream, MoltenVK, and Metal fails qualification.

Every first-party process remains native to its operating-system target. The
Apple guest boots an arm64 kernel and arm64 distribution; Nucleus and Android
are arm64. macOS 27's Intel binary translation runs only the x86_64 Steam,
Proton/Wine, game, and supporting Linux processes that require it. Nucleus does
not boot an amd64 Linux distribution and does not translate the compositor or
Android.

Translated games are ordinary clients of the arm64 compositor. Their x86_64
Vulkan loader and Mesa gfxstream ICD use the same guest virtio-gpu render node
as native arm64 clients. They exchange dma-bufs and synchronization with the
arm64 compositor inside Linux and reach the same single macOS gfxstream
renderer. Proton does not run inside Android's LXC container, a second VM, or a
second graphics stack.

## Target Architecture

### Linux/amd64 bare metal

```text
Android application in LXC
    │ gfxstream protocol
    ▼
local Linux gfxstream host ── native Vulkan driver
    │ guest-local dma-buf + sync_file
    ▼
Nucleus compositor ── native Vulkan/Graphite
    │ Vulkan-exported dma-buf
    ▼
physical DRM/KMS
```

The compositor is not a gfxstream client on this target. Android and the
compositor share buffers because the local gfxstream host, the compositor, and
DRM operate on the same Linux kernel and physical GPU.

### macOS/arm64 host with Linux/arm64 guest

```text
macOS NucleusMacHost.app
├── AppKit window and caller-owned CAMetalLayer
├── Virtualization.framework VM
├── VZLinuxRosettaDirectoryShare with required AOT caching
├── VZVirtioSoundDeviceConfiguration backed by host audio
├── standard virtio-input devices implemented as custom Virtio devices
└── standard virtio-gpu device implemented by Nucleus
    └── one gfxstream renderer ── MoltenVK ── Metal ── CAMetalLayer
             ▲
             │ virtqueues, ASG rings, blobs, resources, fences
             │
arm64 Linux VM
├── Nucleus compositor service
│   ├── Mesa gfxstream Vulkan ICD
│   ├── virtio-gpu DRM render node
│   └── virtio-gpu KMS scanout
├── Android 17 arm64 in LXC
│   ├── the same virtio-gpu DRM render node
│   ├── binderfs
│   └── Mesa/gfxstream gralloc and Vulkan clients
└── unprivileged x86_64 game runtime
    ├── macOS 27 Intel binary translation through registered binfmt
    ├── x86_64 Steam and Proton/Wine userspace
    ├── x86_64 DXVK and vkd3d-proton
    └── x86_64 Mesa gfxstream Vulkan ICD on the same render node
```

The VM is the operating-system and security boundary. LXC supplies the Android
userspace boundary. Apple `container` remains a build executor; it is not the
shipping runtime and does not wrap the compositor in another OCI namespace.

## Ownership and Contracts

| Contract | Owner | Required shape |
| --- | --- | --- |
| Runtime target | Collider | Immutable artifact and execution coordinates |
| VM lifecycle and storage | `NucleusMacHostRuntime` | macOS 27 `Virtualization.framework` and `DiskImageKit` |
| Window and presentation surface | `NucleusMacHost` | AppKit on `MainActor`; caller-owned `CAMetalLayer` |
| Virtio transport | Virtualization.framework bridge | Queue delivery, guest mappings, shared aperture, interrupts |
| Virtio-gpu semantics | `NucleusVirtioGPUDeviceModelCxx` | Standard virtio-gpu device ID 16 and protocol |
| Renderer semantics | pinned gfxstream | Contexts, resources, blobs, command decoding, fences |
| Guest resource identity | Linux virtio-gpu DRM driver | GEM handle, PRIME dma-buf, resource UUID |
| Guest interprocess surface handoff | Nucleus Linux contracts | dma-buf layout plus acquire/release synchronization |
| Output allocation | `NucleusCompositorRendererLinux` | Vulkan image → dma-buf → KMS framebuffer |
| Optional scanout acceleration | `ScanoutCapabilities` | Measured once from DRM/KMS properties |
| VM control plane | `NucleusVMControlProtocol` | Bounded, typed, dedicated vsock framing |
| Input | custom standard virtio-input devices | AppKit events → Linux evdev → existing libinput stack |
| Audio | Virtualization.framework virtio-sound | Core Audio ↔ standard guest ALSA/PipeWire device |
| Android containment | Linux guest | LXC, binderfs, cgroup v2, AppArmor, device policy |
| Intel binary translation | macOS 27 plus guest init | `VZLinuxRosettaDirectoryShare`, AOT cache, VirtioFS mount, x86_64 ELF binfmt |
| TSO optimization | owned guest kernel plus translation runtime | Per-thread `PR_SET_MEM_MODEL_TSO`; never global TSO |
| Translated application runtime | Linux guest | Hermetic x86_64 userspace; no amd64 kernel or distribution |
| Translated CPU contract | macOS 27 translation runtime | Measured x86_64 CPUID and instruction set; never fabricated by Nucleus |
| Windows compatibility | pinned Proton stack | Wine/Proton, DXVK, and vkd3d-proton as Wayland clients |
| Client Vulkan contracts | pinned compatibility profiles | Exact Zink, DXVK, and vkd3d-proton features, properties, limits, formats, and entry points |

Two values describe the legitimate target differences:

- `GfxstreamHostPlacement.local` selects the existing Linux gfxstream host for
  the bare-metal artifact. `GfxstreamHostPlacement.paravirtual` selects the
  virtio-gpu transport for the Apple guest artifact. Collider derives the value
  immutably from the artifact target. It is not a user setting, environment
  variable, runtime feature flag, or compatibility mode.
- `ScanoutCapabilities` contains only optional KMS acceleration discovered from
  the opened DRM device: direct client scanout, a usable cursor plane,
  non-linear output modifiers, explicit out-fences, adaptive sync, and leases.
  Atomic modesetting, PRIME import/export, KMS framebuffer creation, and DRM
  syncobj support are baseline requirements and do not appear as optional
  capabilities.

The existing
[`nucleus_android_gfxstream_host_dmabuf`](../android-runtime/Sources/NucleusAndroidGfxstreamHostC/include/NucleusAndroidGfxstreamHostC.h)
is a local-host API, not a placement-independent host ABI. Its current producer
allocates a Linux GBM object and imports that object into gfxstream. The
paravirtual target cannot and does not reproduce that direction from macOS. The
shared Linux-side contract is an owned dma-buf layout and synchronization
handoff at the compositor boundary; each placement reaches that contract
through its correct resource-creation path.

## Required External Baseline

The target baseline is:

- macOS 27 and the Xcode 27 SDK;
- the `com.apple.security.virtualization` entitlement;
- macOS 27 `DiskImageKit`, ASIF overlays, and the
  `VZDiskImageStorageDeviceAttachment` DiskImage initializer;
- the macOS 27 custom-Virtio, guest-memory-mapping, and Virtio shared-memory
  APIs;
- macOS 27's integrated Intel binary translation facility,
  `VZLinuxRosettaDirectoryShare`, and required AOT caching;
- Virtio 1.4 virtio-gpu and virtio-input device contracts, VirtioFS, and
  Virtualization.framework virtio-sound;
- a pinned Android Common Kernel `android17-6.18` revision configured for arm64
  16 KiB pages, x86_64 ELF binfmt, VirtioFS, and Apple's per-thread TSO kernel
  contract;
- Android 17 arm64 userspace;
- a hermetic x86_64 Linux application runtime inside the arm64 guest;
- pinned Mesa gfxstream guest builds for arm64 and x86_64, gfxstream host,
  MoltenVK, Vulkan-Headers, DXVK, vkd3d-proton, Wine/Proton, and Vulkan Profiles
  revisions qualified as one compatibility set.

Authoritative external references:

- [Expand the capabilities of your Virtualization app](https://developer.apple.com/videos/play/wwdc2026/224/)
- [VZCustomVirtioDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzcustomvirtiodeviceconfiguration)
- [VZVirtioQueueElement](https://developer.apple.com/documentation/virtualization/vzvirtioqueueelement)
- [VZVirtioSharedMemoryRegionConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiosharedmemoryregionconfiguration)
- [Adding the Virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)
- [DiskImageKit](https://developer.apple.com/documentation/diskimagekit)
- [DiskImage](https://developer.apple.com/documentation/diskimagekit/diskimage)
- [StackedImage](https://developer.apple.com/documentation/diskimagekit/stackedimage)
- [Attaching a DiskImage to a virtual machine](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment/init(diskimage:cachingmode:synchronizationmode:))
- [Running Intel Binaries in Linux VMs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
- [Accelerating the performance of Rosetta](https://developer.apple.com/documentation/virtualization/accelerating-the-performance-of-rosetta)
- [VZLinuxRosettaDirectoryShare](https://developer.apple.com/documentation/virtualization/vzlinuxrosettadirectoryshare)
- [Rosetta AOT caching options](https://developer.apple.com/documentation/virtualization/vzlinuxrosettadirectoryshare/cachingoptions-swift.enum)
- [VZVirtioSoundDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceconfiguration)
- [Game Controller](https://developer.apple.com/documentation/gamecontroller)
- [Virtio 1.4 specification](https://docs.oasis-open.org/virtio/virtio/v1.4/virtio-v1.4.html)
- [Android common kernels](https://source.android.com/docs/core/architecture/kernel/android-common)
- [Android 17 Linux 6.18 branch](https://android.googlesource.com/kernel/common/+/refs/heads/android17-6.18)
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
- [MoltenVK release notes](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/Whats_New.md)
- [DXVK driver requirements](https://github.com/doitsujin/dxvk/wiki/Driver-support)
- [vkd3d-proton requirements](https://github.com/HansKristian-Work/vkd3d-proton)
- [Proton](https://github.com/ValveSoftware/Proton)

## Current State

The repository has the right high-level seams and nine blocking mismatches.

[`PresentationBackend.swift`](../core/swift/Sources/NucleusRenderer/render/PresentationBackend.swift)
already isolates presentation from the portable render core. The Linux
implementation, however, opens GBM in
[`RendererDevice.swift`](../compositor/compositor-core/Sources/NucleusCompositorRendererLinux/RendererDevice.swift)
and allocates GBM first in
[`DRMScanoutBufferAllocation.swift`](../compositor/compositor-core/Sources/NucleusCompositorRendererLinux/DRMScanoutBufferAllocation.swift).
The Apple compositor and output path cannot depend on GBM allocation, so output
ownership must reverse for every target. Application OpenGL through Zink may
retain its Mesa Gallium implementation without owning compositor scanout.

The renderer requires Vulkan 1.4, external-memory fd, dma-buf, DRM format
modifiers, physical DRM identity, external-semaphore fd, timeline semaphores,
foreign queue-family ownership, and the remaining declared modern extensions.
The pinned gfxstream guest currently caps its advertised API below that
contract, and the guest stack does not yet synthesize the physical DRM identity
from the actual virtio-gpu render node. That compatibility work is mandatory.

Virtio 1.4 defines `VIRTIO_GPU_F_BLOB_ALIGNMENT` and the `blob_alignment`
device-configuration field. The current `android17-6.18` virtio-gpu UAPI stops
at `VIRTIO_GPU_F_CONTEXT_INIT` and does not expose that field. The owned kernel
adds the standard feature, sets the negotiated alignment to 16 KiB, and tests
its map/unmap behavior. Silent device-side rounding is not the contract.

The current Android graphics flow in
[`NucleusAndroidGfxstreamBroker`](../android-runtime/Sources/NucleusAndroidGfxstreamBroker/main.cpp)
allocates a GBM object in Linux, exports its fd, imports it into gfxstream, and
returns a Linux fd to Android. The arm64 VM product instead needs Android
gralloc and Mesa to allocate a virtio-gpu GEM/blob resource through the guest
render node. PRIME and `SCM_RIGHTS` then keep all fd exchange inside the guest.

Collider's typed platform model now contains Linux/arm64 and Linux/x86_64
artifact targets, native macOS/arm64 and Linux/arm64 OCI execution, exact SDK
and triple selection, and complete dual-architecture runtime build/test graphs.
It does not yet admit a macOS runtime artifact target or the distinct x86_64
Apple-guest runtime assembly. The AOSP product remains rooted under
`device/nucleus/nucleus_x86_64`. The existing
[`SwiftTargetSDKColliderRecipe.swift`](../collider/Sources/SwiftTargetSDKColliderRecipe/SwiftTargetSDKColliderRecipe.swift)
already establishes the correct target-SDK ownership: it uses signed Swift.org
bootstrap inputs, builds only the Linux target runtime and SDK overlays in a
native Linux/arm64 OCI executor, and assembles immutable SDKs with Xcode on
macOS. It never builds a Swift compiler or LLVM. The new architecture extends
that model rather than introducing a second compiler pipeline.

Finally,
[`NucleusSessionProtocol`](../session/protocol/Sources/NucleusSessionProtocol)
contains reusable message concepts, while the existing Linux IPC transport uses
`SOCK_SEQPACKET`, `SCM_RIGHTS`, and peer credentials. The models move or are
shared; the Linux transport does not compile unchanged into the macOS VM host.

The existing seams still expose placement-specific resource production,
presentation, and process lifecycle in types that later targets would otherwise
copy. The Linux/amd64 behavior needs one canonical owned dma-buf and fence
contract, an explicit output-allocation boundary, immutable host placement, and
transport-independent control models before another platform implementation is
added.

The guest image has no production contract for macOS 27 Intel binary
translation. It does not yet mount a `VZLinuxRosettaDirectoryShare`, register
the x86_64 ELF interpreter, provide a hermetic x86_64 dynamic-library hierarchy,
or prove that a translated x86_64 Vulkan client can use the arm64 kernel's
virtio-gpu device and share a surface with the arm64 compositor.

The pinned kernel does not yet carry the complete per-thread TSO behavior Apple
documents for translated Linux workloads, and the host does not configure an
AOT cache. The graphics compatibility lock also describes only the Nucleus
renderer; Vulkan 1.4 by itself does not establish the exact extension, feature,
property, descriptor-limit, and synchronization contracts required by DXVK and
vkd3d-proton. Finally, the current input and host configuration do not yet
provide the gamepad, force-feedback, or low-latency audio path required to call
Windows gaming a supported workload.

The phases below execute strictly in numeric order. Phase N+1 begins only after
every gate in Phase N passes.

## Phase 1 — Normalize the Existing Architecture

This phase changes no supported target. It removes ambiguity from the current
Linux/amd64 system and establishes the contracts every later phase extends.

First, capture one behavioral baseline on the physical Linux qualifier:

- the renderer's exact Vulkan features, properties, limits, formats, modifiers,
  and entry points;
- compositor output allocation and destruction order;
- Android color-buffer creation, dma-buf transfer, acquire/release fencing, and
  gfxstream lifetime order;
- direct-scanout and cursor-plane capability discovery;
- exported products and symbols;
- steady-state frame-copy counters, queue depth, frame-time percentiles, and
  input-to-present trace stages.

The baseline is diagnostic evidence, not a compatibility fixture. Every
replaced implementation is deleted as its callers move, and the resulting
Linux behavior must continue to satisfy the same runtime contracts.

Baseline capture reuses the existing runtime interfaces. It does not introduce
a baseline schema, a second capability model, or a baseline-specific Collider
command. On physical Linux hardware, preserve one Collider run containing
`collider test gpu-drm --verbose`, the existing Vulkan behavioral test output,
`vulkaninfo` and `drm_info` output, the installed-product ELF and symbol
inventory, and one bounded `collider run --tracy` capture with Android enabled.
The Collider run record, compositor log, Tracy event and plot exports, and
trace summary are the evidence bundle. The current dual-architecture
`collider build runtime` and `collider test runtime` run records establish the
host-independent build and test baseline; they do not substitute for the
physical DRM/KMS capture.

Second, settle source and dependency ownership before adding platform code:

- `core/` retains only portable rendering and UI policy and imports no
  Virtualization.framework, AppKit, DRM, LXC, or host gfxstream implementation;
- `compositor/` retains Linux DRM/KMS, libinput, Wayland, output allocation, and
  guest-local surface import;
- `android-runtime/` retains Android lifecycle and its Linux-local gfxstream
  placement, without becoming the owner of the paravirtual GPU device;
- root-package `virtualization/` owns the macOS app and runtime targets,
  Swift/C/Objective-C++ custom-device bridge, guest kernel and image inputs,
  translated-runtime assembly, and VM qualification fixtures; it does not
  become a second Swift package;
- pure cross-boundary control models depend only on Foundation and sit above
  distinct Darwin-vsock and Linux-vsock transports;
- third-party Mesa, gfxstream, MoltenVK, DXVK, vkd3d-proton, Wine/Proton,
  Vulkan-Headers, and Vulkan-Profiles revisions remain root-owned locks or
  submodules, with every required patch carried in the appropriate genuine
  upstream fork;
- all Swift-to-C++ entry points use the repository's opaque-handle and scalar C
  ABI pattern; Swift never decodes the complete virtio-gpu protocol and no C++
  exception crosses into Swift.

No virtualization declaration becomes a supported external Swift source
product. Internal cross-target declarations use `package`; implementation
details remain `internal` or narrower.

Third, normalize graphics ownership:

1. Define one Linux surface-handoff value carrying an owned dma-buf plane
   layout, DRM format and modifier, color metadata, acquire synchronization, and
   a release-completion obligation. It owns fd lifetime explicitly and never
   serializes a native Swift or C++ memory layout.
2. Separate compositor-owned output allocation from `PresentationBackend`.
   Allocation produces a Vulkan render target plus the platform presentation
   identity; presentation schedules and retires it. Neither layer infers the
   other's ownership.
3. Make reset and output generations explicit in resource, fence, and
   presentation lifetime APIs so stale callbacks cannot target a rebuilt device
   or resized output.
4. Centralize optional KMS behavior in `ScanoutCapabilities`; callers stop
   probing DRM properties independently or branching on host identity.
5. Make `GfxstreamHostPlacement` an immutable artifact property. Delete runtime
   toggles, environment inference, and placement-neutral APIs that actually
   expose a Linux-local GBM producer.

Fourth, split data contracts from transports:

- pure lifecycle, topology, clock-calibration, diagnostics, and session models
  live in modules usable by Linux and macOS;
- Linux `SOCK_SEQPACKET`, `SCM_RIGHTS`, and peer-credential behavior remains in
  the Linux transport;
- fd-carrying surface transfer remains guest-local and never enters the vsock
  control protocol;
- same-build internal messages use operation discriminators and exact framing,
  without schema versions or unjustified magic.

Fifth, establish one capability-profile pipeline. The existing Nucleus Vulkan
requirements remain authoritative for the compositor. Separate pinned Mesa
Zink, DXVK, and vkd3d-proton profiles describe their exact required extensions,
features, properties, limits, queue behavior, formats, and function pointers.
Collider generates host, guest, and qualification probes from those inputs; it
never substitutes a Vulkan core-version comparison for a profile result.

Sixth, remove architecture-specific source duplication before adding arm64:

- move architecture-neutral AOSP device implementation and policy into
  `device/nucleus/nucleus/` while the existing `nucleus_x86_64` product becomes
  a thin product selection;
- parameterize AOSP workflows, artifact locks, validation, and product
  selection over an explicit product coordinate;
- replace free-form architecture and platform strings in Collider recipes with
  the existing typed platform values;
- inventory every native dependency, generated artifact, sysroot, loader path,
  page-size assumption, and architecture-specific serialization boundary.

Seventh, land the measurement foundation before the VM exists. Host-independent
trace events describe input receipt, dispatch, application submission,
compositor submission, GPU completion, presentation, queue depth, copies,
conversions, cache state, and resource counts. Producers use monotonic clocks
and attach a calibration generation when a later phase crosses the VM boundary.
Counters attribute every readback, upload, staging operation, GPU blit, and
format conversion by workload and byte count.

Phase gate:

1. The physical Linux/amd64 build, tests, Android surface path, and graphics
   qualifier pass after the structural moves.
2. One owned dma-buf and synchronization contract crosses every current Linux
   producer/consumer boundary; duplicate layout and fence models are gone.
3. Output allocation, presentation, gfxstream placement, control models, and
   Linux transports have distinct owners and behavioral tests.
4. The common AOSP source move leaves `nucleus_x86_64` behavior unchanged and
   no shared implementation remains copied beneath the product directory.
5. Nucleus, Zink, DXVK, and vkd3d-proton capability profiles can be evaluated
   from one generated probe pipeline without claiming that one profile implies
   another.
6. The Linux qualifier emits the copy, queue, lifetime, and latency telemetry
   that later VM gates consume.

## Phase 2 — Complete the Target Coordinates

The manifest and destination contract in
[Single-root SwiftPM Architecture](single-root-swiftpm-architecture.md)
has already removed manifest-time environment selection. Immutable Swift SDK
generations and exact `--swift-sdk` plus `--triple` selection are also
implemented.

`ArtifactTarget.linuxARM64`, `ArtifactTarget.linuxX86_64`,
`ExecutionPlatform.linuxARM64OCI`, `ExecutionPlatform.macOSARM64Native`, exact
target triples, OCI platform names, Debian multiarch names, architecture names,
and dual-architecture runtime task identities are implemented. Complete this
model by adding `ArtifactTarget.macOSARM64` and a distinct assembled-product role
for the translated x86_64 Apple-guest runtime.

The translated application payload continues to use the Linux/x86_64 artifact
coordinate because its ELF ABI is x86_64 glibc. Collider gives its assembled
product a distinct Apple-guest translated-runtime role so it cannot be confused
with the Linux/amd64 bare-metal Nucleus product. Translation is a deployment
mode for selected artifacts, not a new CPU architecture, build execution
platform, or permission to emit an amd64 kernel.

All existing single-value checks in
[`PlatformContract.swift`](../collider/engine/Sources/ColliderCore/PlatformContract.swift),
[`OCIExecutor.swift`](../collider/engine/Sources/ColliderRuntime/OCIExecutor.swift),
[`Doctor.swift`](../collider/Sources/ColliderWorkspaceCommands/Doctor.swift),
[`CommandSupport.swift`](../collider/Sources/ColliderWorkspaceCommands/CommandSupport.swift),
and
[`VulkanTestLanes.swift`](../collider/Sources/ColliderWorkspaceCommands/VulkanTestLanes.swift)
switch on the declared coordinate and reject every unlisted combination.

`SwiftTargetSDKColliderRecipe` already publishes one immutable Linux Swift SDK
with arm64 and amd64 entries. It:

- download the signed Swift.org macOS host package and exact target-system
  package closure;
- use an official Linux/arm64 bootstrap compiler to build the arm64 target
  runtime natively and cross-build the amd64 target runtime against libc++;
- assemble the target SDK natively on macOS from that runtime install;
- use Xcode's compiler to cross-compile Nucleus Swift products against the
  published SDK;
- avoid building a Swift compiler or LLVM.

Xcode 27 builds the macOS/arm64 host artifact natively. This is a runtime
artifact target, not an execution-platform alias and not a Linux cross-compile.

Phase gate:

1. Collider plans distinct task identities for Linux/x86_64, Linux/arm64, and
   macOS/arm64 artifacts.
2. The x86_64 Apple-guest runtime and Linux/amd64 Nucleus product have distinct
   assembly and deployment identities despite sharing an ELF architecture.
3. `collider doctor` reports provisioned and missing target SDK generations
   separately.
4. Requesting a missing or unsupported coordinate fails during planning.
5. Platform-contract and workflow tests exercise every admitted coordinate and
   every rejection.

## Phase 3 — Prove the Production-Shaped Architecture Slice

This phase is a hard architectural gate. No full arm64 product, Android image,
production root filesystem, or Proton product lands until this slice proves the
actual native and translated execution, resource, synchronization, scanout, and
presentation paths.

The slice creates the permanent targets that later phases extend:

- `virtualization/Sources/NucleusMacHostRuntime`;
- `virtualization/Sources/NucleusVirtioDeviceBridgeC`;
- `virtualization/Sources/NucleusVirtioGPUDeviceModelCxx`;
- a minimal `NucleusMacHost` AppKit harness;
- the exact `third-party/android-common-kernel` source pin and initial 16 KiB
  qualification configuration, including the per-thread TSO delta required by
  the pinned kernel;
- a minimal guest qualification initramfs built from the pinned
  `android17-6.18` kernel revision;
- a guest boot unit that mounts the translation VirtioFS share and registers
  Apple's runtime for x86_64 ELF through `binfmt_misc`;
- the macOS gfxstream/MoltenVK build and arm64 and x86_64 Mesa gfxstream guest
  builds;
- a minimal hermetic x86_64 glibc userspace containing a dynamic loader and the
  libraries required by the translated qualification programs;
- pinned 64-bit Wine/Proton, DXVK, and vkd3d-proton qualification fixtures.

The harness is a behavioral qualification fixture, not a discarded prototype.
The Swift side creates the custom device, owns VZ queue and mapping objects, and
forwards opaque handles and scalars through a C boundary. The C++ side decodes
the virtio-gpu requests and calls gfxstream's renderer C API. It does not
duplicate gfxstream's existing resource, context, blob, or fence renderer
semantics and does not add rutabaga as a second abstraction.

Phase gate:

The slice proves all of the following in order:

1. The macOS 27 host constructs `VZLinuxRosettaDirectoryShare` directly,
   enables `.defaultUnixSocket` AOT caching, places it behind a validated and
   unique VirtioFS tag, and appends the device to the VM configuration. It does
   not query availability, call `installRosetta()`, offer a macOS 26 path, or
   continue without the required share and cache.
2. The arm64 guest mounts the share at a fixed root-owned path, verifies the
   supplied `rosetta` runtime, and registers Apple's exact x86_64 ELF magic and
   mask with `--credentials yes --preserve yes --fix-binary yes`. A static
   x86_64 program and a dynamically linked x86_64 program run while the kernel,
   init, and native control process remain arm64. CPUID and instruction probes
   record the exact translated x86_64 feature set and execute every advertised
   ISA family without an illegal-instruction mismatch. Memory probes exercise
   the guest's real 16 KiB page size, Windows-style address-space reservation,
   `mmap`, `mprotect`, executable mappings, signals, thread creation, and
   self-modifying/JIT-style code before Wine is admitted.
3. The kernel accepts `prctl(PR_SET_MEM_MODEL, PR_SET_MEM_MODEL_TSO)` for the
   translated execution threads, preserves the per-thread state across context
   switches, and leaves native arm64 threads in the normal ARM memory model.
   The phase compares Apple's Linux 6.10 enhancement patch with the pinned
   Android Common Kernel 6.18 tree and carries only the missing equivalent
   behavior.
4. A standard Linux `virtio_gpu` driver with the owned Virtio 1.4 alignment
   support binds to custom Virtio device ID 16, negotiates
   `VIRTIO_F_VERSION_1`, `VIRTIO_GPU_F_BLOB_ALIGNMENT`, and the remaining
   declared virtio-gpu feature bits, and exposes a primary and render DRM node.
5. An address-space graphics ring and one CPU-visible resource blob operate
   through a `VZVirtioSharedMemoryRegion`. Every host pointer, aperture offset,
   mapping size, and allocation is aligned to the host's 16 KiB page size. The
   device configuration reports `blob_alignment = 16384`.
6. The shared aperture contains only CPU-addressable rings, metadata, and
   mappable blobs. GPU-private images remain gfxstream/MoltenVK allocations.
   gfxstream `ExternalBlob` is not used to pretend that Metal device-local
   memory is host-addressable.
7. The arm64 guest Vulkan ICD passes the full authoritative Nucleus renderer
   probe: Vulkan 1.4, every required extension, every required feature,
   physical DRM major/minor identity matching the opened render node, and every
   required function pointer including `vkGetMemoryFdKHR` and
   `vkGetImageDrmFormatModifierPropertiesEXT`.
8. Native guest process A creates an exportable gfxstream `VkImage`, exports its
   virtio-gpu GEM object as a PRIME dma-buf, sends the fd over a guest-local
   `SOCK_SEQPACKET` socket, and signals readiness with a real `sync_file`.
   Native guest process B imports the same dma-buf, waits on that
   synchronization, samples or renders from the image, and returns a release
   fence that process A successfully waits.
9. A translated x86_64 Vulkan client loads only x86_64 userspace libraries,
   creates a device through the x86_64 Mesa gfxstream ICD, submits through the
   arm64 kernel's same virtio-gpu render node, and passes the exact Zink, DXVK,
   and vkd3d-proton capability profiles. Its Wayland-style image and acquire
   fence cross to an arm64 importer, and the translated producer successfully
   waits for the returned release fence.
10. A 64-bit Windows D3D11 qualification program runs through the pinned
    Wine/Proton and DXVK stack, and a 64-bit Windows D3D12 qualification program
    runs through vkd3d-proton. A 64-bit Windows OpenGL qualification program
    runs through Wine and x86_64 Mesa Zink. Each renders into the
    production-shaped arm64 Wayland/import fixture and final scanout path
    through the same x86_64 Vulkan ICD and single host renderer. This is a
    separate behavioral gate because Apple's documented contract covers x86_64
    Linux ELF translation, not Proton or Windows PE compatibility.
11. The guest creates a KMS framebuffer for a Vulkan-exported image, selects it
   as virtio-gpu scanout, and the exact resource reaches the caller-owned
   `CAMetalLayer` through gfxstream and MoltenVK.
12. Instrumented counters report zero framebuffer readbacks, zero frame-sized CPU
   copies, and zero per-frame CPU texture uploads.
13. A cold translated launch exercises the configured AOT endpoint and populates
    the guest graphics caches. A warm relaunch keeps the AOT socket healthy,
    reuses the guest graphics caches, and records its launch and translation
    behavior. The report does not invent an AOT hit counter that Apple's API
    does not expose.
14. Guest reboot and device reset invalidate every guest-memory mapping, unmap
   every shared-aperture range, cancel every pending completion by reset
   generation, rebuild the device, remount and re-register the translation
   runtime, and repeat the native and translated tests.

The pinned Mesa, gfxstream, Vulkan-Headers, Vulkan Profiles, MoltenVK, DXVK,
vkd3d-proton, and Wine/Proton revisions become one compatibility lock. Required
changes to Vulkan command generation, capset advertisement, DRM identity,
queue-family-foreign semantics, descriptor limits, transform feedback,
external semaphore fd behavior, pipeline caching, and Metal support land in
those pinned components as part of this phase.

Failure of any gate rejects this architecture. It does not authorize a CPU
framebuffer path, display streaming, a private non-DRM guest graphics API, a
second renderer, software CPU translation fallback, global TSO, an amd64 guest,
or weaker Vulkan requirements.

## Phase 4 — Build the Complete Linux Graph for arm64

A pinned Linux/arm64 OCI builder image joins the Linux/amd64 image for
Linux-native C and C++ dependency builds. The render SDK, React Native SDK,
Mesa, gfxstream guest components, and other native artifacts build for
`aarch64-unknown-linux-gnu` through Apple `container`. Swift product compilation
uses the Phase 2 Swift target SDK from the native Xcode host compiler.

The complete first-party Linux closure gains Linux/arm64 artifacts:

- portable core and renderer;
- compositor library and executable;
- shell, window client, configuration, session, and IPC processes;
- Android runtime host and LXC orchestration;
- headless tools, test fixtures, and all test targets.

Architecture defects are fixed at their source for both Linux targets. This
includes native-layout assumptions, atomic widths, endian or alignment
assumptions, hard-coded multiarch paths, page-size assumptions, and unsafe
serialization of C or Swift memory layouts. There is no conditional legacy
implementation for amd64.

The full closure executes in the arm64 builder. GPU-independent Vulkan behavior
uses the staged arm64 lavapipe ICD; the production gfxstream path remains owned
by the Phase 3 VM qualification fixture.

Phase gate:

1. The full Linux/arm64 closure builds from the complete-checkout bootstrap.
2. Unit, headless, sanitizer, and lavapipe lanes pass on arm64.
3. Runtime product and symbol inventories match the declared cross-architecture
   contracts.
4. No arm64 task consumes an amd64 SDK, sysroot, native library, generated file,
   or OCI image.

## Phase 5 — Replace GBM-First Output Allocation

`NucleusCompositorRendererLinux` replaces
`DRMScanoutBufferAllocation` with `VulkanScanoutBufferAllocation` for every
Linux target. The new allocator owns this exact sequence:

1. Read each usable KMS plane's formats. Parse `IN_FORMATS` when present;
   otherwise pair each advertised format with `DRM_FORMAT_MOD_LINEAR`.
2. Intersect that set with Vulkan external-image format properties for
   `VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT`, the render-target usage,
   and DRM modifier tiling.
3. Create the `VkImage` with external-memory and explicit modifier information.
4. Allocate dedicated exportable Vulkan memory, bind it, query the selected DRM
   modifier and every memory-plane layout, and validate offsets, row pitches,
   sizes, and plane counts.
5. Export the memory with `vkGetMemoryFdKHR`.
6. Import the dma-buf into DRM with `drmPrimeFDToHandle` and create the
   framebuffer with `drmModeAddFB2WithModifiers`.
7. Wrap the original `VkImage` directly for Graphite.

The Vulkan allocation owns storage. KMS owns only its framebuffer reference and
imported GEM handles. After the render and KMS fences retire, teardown releases
the Graphite wrapping, removes the framebuffer, closes imported GEM handles and
dma-buf fds, then destroys the Vulkan image and memory.

[`RendererDevice.swift`](../compositor/compositor-core/Sources/NucleusCompositorRendererLinux/RendererDevice.swift)
stops creating a GBM device. The compositor renderer deletes its GBM C wrapper,
link dependency, allocation structs, and tests once no caller remains. Android's
bare-metal local gfxstream broker keeps its own GBM dependency because it is a
different resource producer.

The behavioral Vulkan tests replace the GBM round-trip with a
Vulkan-export-to-DRM round-trip. It creates the image, exports the dma-buf,
imports it into DRM, creates and removes a framebuffer, and verifies lifetime
and synchronization behavior. Source-shape assertions are not used.

`ScanoutCapabilities` is resolved from the live DRM object properties after the
baseline requirements pass. The presenter, cursor path, direct-client-scanout
path, dmabuf feedback, and lease advertisement consume it. The Apple target does
not hard-code linear output or a composited cursor; it reports what its
virtio-gpu implementation actually exposes. The physical target likewise
advertises only measured optional acceleration.

Phase gate:

1. The new allocator and behavioral Vulkan tests pass on physical Linux hardware.
2. The same tests pass through the Phase 3 virtio-gpu device.
3. Graphite renders into the original Vulkan image without an import copy.
4. Client dma-buf import and explicit synchronization behavior remain intact.
5. No compositor-owned output allocation calls GBM.

## Phase 6 — Own the 16 KiB Android-Capable Guest

The VM kernel remains the first-party build component established by Phase 3
and expands from its qualification configuration to the complete guest
contract. It is rooted at the pinned `android17-6.18` Android Common Kernel
revision. The source lives in a root-managed submodule; any Nucleus patch points
the submodule at a genuine `nucleus-os` fork. `virtualization/kernel/` owns the
exact source revision, configuration, module manifest, build preset, and
artifact lock.

The arm64 configuration sets `CONFIG_ARM64_16K_PAGES=y`. This matches the
Apple-silicon host page size, the target's 16 KiB-compatible Android 17
userspace, and the VZ shared-aperture alignment used by Phase 3.

Boot-critical support is built into the kernel:

- Virtio PCI transport, block, network, console, vsock, input, `uinput`, and DRM
  virtio-gpu;
- VirtioFS, FUSE, ELF loading, and `binfmt_misc` built in so translation is
  available before application services start;
- the Virtio 1.4 blob-alignment UAPI and driver behavior established by Phase 3;
- binder IPC and binderfs;
- namespaces, cgroup v2 controllers and delegation, seccomp filtering;
- EROFS, overlayfs, loop, tmpfs, devtmpfs, and the BPF filesystem;
- io_uring, PSI, and the device and memory accounting required by LXC;
- the synchronization and process primitives required by the pinned Proton
  runtime, including its selected `ntsync` or futex backend, `futex_waitv`,
  eventfd, epoll, pidfd, memfd, and required namespace behavior;
- AppArmor selected and enabled in the LSM order;
- per-thread memory-model selection with working
  `PR_SET_MEM_MODEL_TSO`, implemented by the upstream-equivalent 6.18 behavior
  or the minimal port of Apple's enhancement patch;
- readable kernel configuration through `/proc/config.gz`.

TSO remains a per-thread translated-workload property. The image never selects
TSO globally, and native Nucleus and Android services never call the TSO
`prctl`. A kernel behavior test switches repeatedly between native ARM and
translated x86_64 threads and verifies both memory-model states after migration
and preemption.

The legacy xtables and related networking entries enumerated by
[`AndroidRuntimeKernelRequirements.swift`](../android-runtime/Sources/NucleusAndroidRuntimeCore/AndroidRuntimeKernelRequirements.swift)
remain loadable modules because Android `netd` probes that ABI. Collider derives
the build-time validation directly from the runtime requirement list and fails
on a missing built-in symbol, module, or required value.

The guest image is a persistent VM system, not an Apple OCI container. Phase 6
publishes two deterministic, content-verified RAW block artifacts: an immutable
root filesystem and an immutable initialized data-filesystem base. RAW remains
the build output because Linux image assembly owns filesystem creation while
DiskImageKit owns host-side opening and stacking in Phase 7. Neither artifact is
ever opened writable after publication.

The image contains:

- immutable base root filesystem;
- separate data filesystem whose writable lifetime begins in a per-machine ASIF
  overlay;
- a real init system that owns service readiness and shutdown;
- a root-owned `/run/nucleus/rosetta` mount point and a VirtioFS mount unit for
  the fixed validated `nucleus-rosetta` tag;
- an idempotent binfmt registration unit ordered after that mount, using
  Apple's exact x86_64 ELF discriminator and
  `--credentials yes --preserve yes --fix-binary yes`;
- an x86 translation readiness target on which every translated service
  depends; it fails when the mount, runtime, binfmt registration, static probe,
  dynamic loader probe, or TSO probe fails;
- compositor, shell, and Nucleus services at VM level;
- Android 17 in LXC beneath that service graph;
- binderfs mounts, cgroup delegation, mount propagation, render-node policy,
  network setup, and AppArmor profiles declared as image inputs.

The image-owned units perform the equivalent of Apple's documented activation
sequence after mounting `binfmt_misc`:

```sh
mount -t virtiofs -o ro,nosuid,nodev \
  nucleus-rosetta /run/nucleus/rosetta

/usr/sbin/update-binfmts --install rosetta \
  /run/nucleus/rosetta/rosetta \
  --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" \
  --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" \
  --credentials yes --preserve yes --fix-binary yes
```

The ELF magic is required here because Linux `binfmt_misc` must distinguish an
x86_64 ELF executable from other executable formats at `exec` dispatch. It is
not reused in a Nucleus protocol or file format. The production unit implements
the operation idempotently, holds the VirtioFS mount for the VM lifetime, and
removes stale registration state before replacing it.

Phase gate:

1. The kernel and modules build reproducibly for arm64 from their locks.
2. Collider validates the built artifact against every Android host and kernel
   requirement and every VirtioFS, binfmt, and per-thread TSO requirement.
3. The image boots, mounts the immutable and writable filesystems, reaches the
   service target, and shuts down cleanly.
4. The root and initialized data-base RAW artifacts have exact declared block
   counts, deterministic contents, and recorded content digests; a post-build
   mutation changes their identities and fails validation.
5. With the Phase 3 host fixture, the translation readiness target succeeds on
   every boot and after a controlled service restart without duplicate binfmt
   state.
6. The LXC host-requirements probe passes without suppressed checks.
7. The Android AppArmor profile loads and a minimal LXC payload reaches binderfs,
   cgroup v2, networking, and the shared render node.

## Phase 7 — Build the Shipping macOS Host and Control Plane

The root package gains internal or package-visible targets under
`virtualization/Sources/` and one executable product:

- `NucleusVMControlProtocol`;
- `NucleusVMControlDarwin`;
- `NucleusVMControlLinux`;
- `NucleusMacHostRuntime`;
- `NucleusMacHost`.

Collider packages the executable as a signed `NucleusMacHost.app` with a
macOS 27 deployment target and the virtualization entitlement. No new library
becomes a supported external Swift source product. The AppKit application owns
its `NSWindow`, presentation view, `CAMetalLayer`, menu and application
lifecycle on `MainActor`. VM and custom-device callbacks run on dedicated serial
queues and cross to `MainActor` only for AppKit state.

`NucleusMacHostRuntime` is the sole owner of shipping VM block-image lifetime.
It imports `DiskImageKit` directly and uses this fixed storage topology:

- the content-addressed Phase 6 root RAW is opened explicitly read-only and
  attached as the immutable root disk;
- the content-addressed Phase 6 data-base RAW is opened explicitly read-only;
- every installed VM owns one ASIF overlay graph with exactly one active chain
  above that data-base artifact;
- every parent layer is opened read-only and only the top overlay is opened
  read-write;
- the complete `DiskImage` or `StackedImage` object graph remains alive for the
  lifetime of its `VZDiskImageStorageDeviceAttachment` and VM;
- the data attachment uses full synchronization. A clean guest shutdown and
  attachment closure complete before any layer transition.

The first launch creates an ASIF overlay that inherits the data-base artifact's
block geometry. A stopped-disk restore point seals the current top layer,
reopens the complete existing chain read-only, and appends a new ASIF overlay
that receives all subsequent writes. Restoring selects a validated historical
chain prefix and appends a new writable overlay; Nucleus never reopens the
selected historical top for writing. This preserves DiskImageKit's parent/layer
UUID compatibility and permits multiple restore branches without mutating their
common ancestry.

The app stores one atomically replaced internal storage record beside the
machine directory. It contains the exact root and data-base artifact digests,
every sealed layer URL and its final layer and parent UUID, the writable top URL
and expected parent UUID, the ordered active chain, and retained restore-point
tips. It has no protocol version because only the same installed monorepo
product reads and writes it. A writable top's layer UUID is deliberately not a
persisted identity because DiskImageKit changes that UUID when the layer is
written. The transition that seals a top records its final UUID before making
it a parent.

Startup opens every layer reachable from the active chain or a retained restore
point. It validates format, block size, block count, open mode, ordering, every
sealed UUID edge, the writable top's parent UUID, and base digest against the
record, and fails before VM construction on any mismatch, missing layer,
corruption, unexpected writable parent, or child above the writable top. It
never repairs or guesses a graph from directory contents.

Every layer transition is a crash-safe publication. The runtime creates the new
layer at its final unique URL, validates the resulting stack, synchronizes the
image and containing directory, then atomically replaces the storage record.
An interruption before record replacement leaves an unreferenced candidate that
can be removed after proving that no machine record names it. An interruption
after replacement leaves the new active chain complete. Root-image replacement
uses the same stopped-VM transaction. Existing machines retain their pinned
data-base digest; a newer data base applies only to newly created machines.

DiskImageKit does not replace host filesystem ownership. Immutable bases,
machine records, and overlays remain in an app-owned persistent APFS directory;
APFS continues to own encryption, backup, free-space accounting, and quotas.
Collider owns installation and atomic replacement of immutable base artifacts.
`NucleusMacHostRuntime` owns only machine records and overlays. No cleanup can
remove a base referenced by a machine record, a layer referenced by a retained
restore branch, or any image held by a running VM.

The initial product creates no DiskImageKit cache layer: its bases are local and
content-addressed, so an additional read cache has no demonstrated benefit.
Apple `container` build execution, its OCI image store, Collider caches,
persistent build volumes, and the host-owned macOS remote-development checkout
never pass through DiskImageKit.

`NucleusMacHostRuntime` creates the full `VZVirtualMachineConfiguration`:

- Phase 6 kernel and boot arguments;
- immutable RAW root `DiskImage` and the writable RAW-base-plus-ASIF data
  `StackedImage`;
- entropy, memory balloon, console, network, and vsock devices;
- the custom virtio-gpu configuration established by Phase 3;
- a validated `nucleus-rosetta` VirtioFS device whose share is a directly
  constructed `VZLinuxRosettaDirectoryShare` with
  `.defaultUnixSocket` AOT caching;
- deterministic CPU and memory policy;
- lifecycle, reset, crash, and diagnostics ownership.

Because the app hard-requires macOS 27, it contains no translation-availability
switch and never calls `installRosetta()`. Failure to construct the share,
configure its AOT cache, append the directory-sharing device, or validate the
VM configuration is a startup failure. The app exposes Apple's special share
for translation; it does not copy or redistribute the host runtime and does not
use a general host-directory share as a substitute.

The configuration is structurally equivalent to:

```swift
let translationTag = "nucleus-rosetta"
try VZVirtioFileSystemDeviceConfiguration.validateTag(translationTag)

let translationShare = try VZLinuxRosettaDirectoryShare()
try translationShare.setCachingOptions(.defaultUnixSocket)

let translationFileSystem =
    VZVirtioFileSystemDeviceConfiguration(tag: translationTag)
translationFileSystem.share = translationShare
configuration.directorySharingDevices.append(translationFileSystem)
```

Phase 10 adds the input and sound device configurations after their standard
implementations pass their own contract tests.

`NucleusVMControlProtocol` depends only on Foundation and owns typed lifecycle,
session, output-topology, resize, configuration, diagnostic, and clock-sampling
messages. Reusable pure models move out of `NucleusSessionProtocol` when both
targets need them. Linux `NucleusIPCTransport` remains the fd- and
credential-carrying local channel and is not imported by macOS.

The VM control channel uses one dedicated vsock port. Each frame contains an
operation discriminator, a bounded payload length, and the exact typed payload
encoding. It does not encode native Swift layouts. The dedicated same-build
channel has no magic bytes and no protocol version. Unknown operations, excess
lengths, trailing bytes, partial frames, and disconnects are rejected
deterministically. The channel never claims to pass file descriptors.

Phase gate:

1. Configuration validation succeeds for the signed app and all required
   entitlements are present in the built bundle.
2. The app boots the Phase 6 image, receives native-service and translation
   readiness events, reports service failure, and performs orderly and forced
   shutdown.
3. The configured AOT socket remains healthy across cold and warm translated
   smoke launches and app relaunch; measured launch behavior is reported
   without claiming an unavailable cache-hit signal.
4. Darwin and Linux codec tests exchange every control message and reject every
   malformed framing case.
5. Root and data disk lifetimes survive app relaunch. A stopped VM creates a
   restore point, advances to a new writable overlay, restores by branching from
   the retained prefix, and rejects reordered, missing, corrupted,
   writable-parent, UUID-incompatible, and wrong-base chains.
6. Two installed VMs share the same read-only root and data-base artifacts while
   owning disjoint overlays. Concurrent startup never opens a writable overlay
   from both machines, and deleting one machine cannot remove shared bases or
   the other machine's layers.
7. Truncating a DiskImage is never treated as filesystem resizing, no cache
   layer is created for local bases, and stopped-disk restore points make no
   claim to preserve CPU, memory, custom-device, or gfxstream state.

## Phase 8 — Complete and Harden the virtio-gpu Device

`NucleusVirtioGPUDeviceModelCxx` becomes the complete VZ-facing standard
virtio-gpu device model. It is deliberately distinct from gfxstream's existing
`VirtioGpuFrontend`, which remains responsible for renderer-side resource,
context, blob, and fence behavior behind the `stream_renderer_*` API.

The advertised device contract is explicit:

- standard Virtio device ID 16 and PCI display class;
- control queue and cursor queue;
- `VIRTIO_F_VERSION_1`;
- `VIRTIO_GPU_F_VIRGL`;
- `VIRTIO_GPU_F_EDID`;
- `VIRTIO_GPU_F_RESOURCE_UUID`;
- `VIRTIO_GPU_F_RESOURCE_BLOB`;
- `VIRTIO_GPU_F_CONTEXT_INIT`;
- `VIRTIO_GPU_F_BLOB_ALIGNMENT` with `blob_alignment = 16384`;
- shared-memory region `VIRTIO_GPU_SHM_ID_HOST_VISIBLE` (region ID 1);
- exact scanout and capset counts in device configuration.

The device implements and behaviorally tests the required command families:

- display information, EDID, config events, scanout, scanout blob, and flush;
- 2D resource create, unref, attach backing, detach backing, and transfers;
- context create, destroy, attach resource, detach resource, and 3D submission;
- capset enumeration and payloads;
- resource UUID assignment, blob creation, map, and unmap;
- host/guest 3D transfers;
- cursor update and move;
- fenced and unfenced completion;
- device reset, queue reset, and renderer teardown.

The queue contract is:

1. On the VZ serial device queue, consume each readable descriptor exactly once,
   copy the small control structure into owned memory, validate the full chain,
   and register bounded in-flight work.
2. Dispatch renderer work without retaining an untrusted queue buffer or raw
   guest pointer.
3. Return to the device queue for completion.
4. Check the device reset generation.
5. Write the complete response before calling `returnToQueue()`.
6. Delay fenced commands until the virtio-gpu specification's completion point;
   deliver asynchronous fence completion without blocking the VZ queue.

The implementation bounds descriptor-chain length, request size, response size,
in-flight elements, contexts, resources, attached backing, blob bytes, aperture
space, mappings, and pending fences. Every addition, multiplication, range, and
guest physical address calculation uses checked arithmetic. Queue saturation
applies backpressure instead of allocating without limit. Parser and state
machine fuzz tests exercise behavior, reset races, duplicate IDs, stale IDs,
short responses, overlapping mappings, and late callbacks.

The VZ shared aperture is backed through a new platform-neutral
host-visible-memory provider in the pinned gfxstream integration. The provider
allocates CPU-addressable memory with 16 KiB alignment and returns an owned host
pointer, size, and lifetime token. The device model maps that allocation into
the standard host-visible region. GPU-private Metal images never enter this
provider. Unmap, reset, reboot, renderer teardown, and VM stop release mappings
in one declared order.

The locked compatibility contract established in Phase 3 remains mandatory as
the device expands to the full production command surface. It includes:

- guest Vulkan 1.4 capset and command support for the Nucleus renderer profile;
- Mesa Zink's pinned profile for Android and translated Windows OpenGL clients;
- DXVK's pinned required profile, including its depth-clip, maintenance,
  robustness, transform-feedback, descriptor-indexing, and push-constant
  contracts;
- vkd3d-proton's pinned required profile, including its descriptor-indexing,
  update-after-bind capacity, mirror-clamp, shader-draw-parameter, robustness,
  push-descriptor, and selected descriptor-buffer or mutable-descriptor
  contract;
- the pinned performance profile used by both compatibility layers, including
  every available present-wait, swapchain-maintenance, memory-budget,
  pipeline-library, shader-identifier, and extended-dynamic-state fast path
  that qualification declares mandatory;
- physical DRM identity sourced from the bound virtio-gpu render node;
- correct dma-buf import/export and modifier reporting;
- correct `sync_file`, external semaphore fd, timeline, and
  `VK_EXT_queue_family_foreign` guest semantics;
- the exact pinned MoltenVK feature set required by the renderer;
- persistent shader and pipeline caches;
- a renderer C entry point that accepts a caller-owned `CAMetalLayer`.

The arm64 and x86_64 guest ICD builds consume the same generated capset inputs
and expose the same physical-device identity, formats, feature values, and
limits. A feature reported by Mesa but missing from gfxstream, MoltenVK, or the
underlying Metal implementation fails the profile instead of reaching a game as
late undefined behavior. Vulkan 1.4 support never substitutes for a client
compatibility profile.

The existing Cocoa helper no longer creates its own child `NSView` from an
`NSWindow`. Nucleus owns the view, layer, backing scale, drawable size, resize
coordination, and input region. gfxstream owns the Vulkan surface, swapchain,
render submission, and present against that supplied layer. No public API
extracts an `MTLTexture` for a second presenter and no extra Metal copy bridges
the two.

Save/restore support remains disabled. Device reset is fully supported.

Phase gate:

1. Virtio protocol conformance tests cover every advertised command and feature.
2. Fuzz and reset-stress tests complete without leaks, stale completion, guest
   memory use after reset, or unbounded growth.
3. The Nucleus, Zink, DXVK, and vkd3d-proton Vulkan profiles pass through both
   the arm64 and translated x86_64 guest ICDs on every VM boot.
4. Resource sharing and real fence round trips pass under sustained concurrent
   native compositor, Android, and translated-client load.
5. Presentation uses the supplied layer and all frame-sized CPU-copy counters
   remain zero.

## Phase 9 — Bring Up the Complete Compositor in the VM

The Phase 4 Linux/arm64 runtime and Phase 6 guest image consume the completed
virtio-gpu device. The compositor opens the DRM primary node for KMS and the
render node for Vulkan, verifies that `VK_EXT_physical_device_drm` identifies
the same device, resolves `ScanoutCapabilities`, and creates its output ring
through `VulkanScanoutBufferAllocation`.

The virtio-gpu device exposes one KMS scanout backed by the macOS window. Device
configuration, display-info responses, EDID, and config-change interrupts carry
the current logical size and refresh contract. A host resize updates the
drawable size and device display state; the guest receives a KMS hotplug or
mode-change event; the existing output topology reconciler recreates output
buffers and acknowledges the new mode. Stale-size frames are discarded by
generation rather than stretched.

gfxstream presents the guest-selected scanout resource directly to its Vulkan
swapchain on the caller-owned Metal layer. The host does not sample a guest
framebuffer with CPU code and does not maintain an independent scene.

Phase gate:

1. The complete compositor reaches readiness and renders shell content
   continuously at the advertised refresh rate.
2. Repeated resize, scale, fullscreen, display migration, guest restart, and
   device reset preserve correct output generation and resource lifetime.
3. Both linear and non-linear output modes are exercised when advertised.
4. Optional direct scanout and cursor-plane behavior follow measured
   capabilities rather than target identity.
5. A capture of steady-state host and guest traces contains no CPU framebuffer
   path.

## Phase 10 — Implement Input, Audio, Seat, Cursor, and Topology

The macOS host implements standard virtio-input device ID 18 as separate
keyboard and pointer devices. It does not depend on `VZVirtualMachineView`,
because presentation occurs in the Nucleus-owned Metal view.

The keyboard device advertises the exact Linux evdev key bitmap and uses its
status queue for LED state. The pointer device advertises absolute coordinates,
relative motion for pointer capture, buttons, vertical and horizontal wheel
events, and high-resolution wheel events. AppKit events are translated once
into evdev codes with host receipt timestamps. Linux receives ordinary evdev
nodes and the existing libinput, xkb, seat, focus, gesture, and dispatch stack
runs unchanged.

The VM configuration also creates a fixed set of standard virtio-input gamepad
endpoints. The macOS host maps GameController devices into stable slots and
translates buttons, hats, sticks, triggers, and timestamps to Linux evdev
events. The guest endpoints remain stable because custom Virtio devices are
configured before VM creation; host controller connection and disconnection
binds and unbinds those slots and emits a neutral state without claiming Virtio
hot-plug. Guest force-feedback and light commands return through each device's
status queue and map to the corresponding bound host-controller capability.
Unsupported output capabilities fail explicitly rather than acknowledging an
effect that was not produced. Guest udev metadata and the scoped `uinput`
policy satisfy Steam Input without exposing unrelated input devices to the game
runtime.

The host configures a standard `VZVirtioSoundDeviceConfiguration` backed by host
audio streams. Linux exposes the device through ALSA and PipeWire; applications
do not use a private vsock audio protocol. The output path owns sample-format
and rate negotiation, bounded ring depth, host clock correlation, underrun and
overrun counters, volume, mute, device loss, and app relaunch. Microphone input
uses the same standard device and the macOS permission model. Audio callbacks
never block a VM or custom-device serial queue.

The host view owns pointer capture, coordinate conversion, backing-scale
conversion, confinement, and native-cursor visibility. The guest compositor
owns cursor shape and policy. A measured KMS cursor plane uses the virtio-gpu
cursor queue; otherwise the guest composites the cursor and the host hides the
native pointer over the presentation view. Exactly one cursor remains visible.

Output topology messages over the control plane report host display identity,
logical scale, drawable pixel size, refresh rate, color-space contract, and
fullscreen state. Virtio-gpu remains the source of the Linux KMS event; vsock
does not become a private display device.

Phase gate:

1. Keyboard layout, modifiers, repeat, LEDs, buttons, scroll, gestures, absolute
   motion, relative capture, confinement, and focus transitions pass behavioral
   tests.
2. Gamepad discovery, stable slot assignment, host bind and unbind, neutral
   unbound state, buttons, axes, triggers, hats, and supported force feedback
   pass behavioral tests.
3. Host-event-to-guest-evdev latency is measured at p50, p95, and p99 for
   keyboard, mouse, and gamepad input.
4. Guest audio reaches Core Audio without a per-buffer vsock round trip; warmed
   guest-submit-to-host-render p99 is no greater than 20 ms with zero underruns
   under concurrent graphics load.
5. Resize, scale, refresh-rate change, fullscreen, and display migration produce
   one ordered topology transition with no stale input transform.
6. Cursor behavior passes in both advertised cursor capability states.

## Phase 11 — Build Android 17 arm64 on the Native virtio-gpu Path

The AOSP device tree organization established by Phase 1 supplies:

- `device/nucleus/nucleus/` owns shared init, permissions, SELinux policy,
  composer, gralloc interfaces, display-control protocol, presentation
  protocol, and other shared implementation;
- `device/nucleus/nucleus_x86_64/` owns the bare-metal product selection;
- `device/nucleus/nucleus_arm64/` owns the paravirtual product selection.

The exact Repo manifest continues to own the AOSP source graph. Shared source is
not copied between product directories. The parameterized
[`AndroidRuntimeColliderRecipe.swift`](../collider/Sources/AndroidRuntimeColliderRecipe/AndroidRuntimeColliderRecipe.swift),
artifact validation, product locks, and
[`AndroidRuntimeColliderRecipe.swift`](../collider/Sources/AndroidRuntimeColliderRecipe/AndroidRuntimeColliderRecipe.swift)
consume the declared product and architecture.

The arm64 product replaces the local host-broker resource flow:

1. Android Mesa/gfxstream uses the native Linux VirtGpu transport on the render
   node resolved from the virtio-gpu DRM device.
2. Gralloc creates virtio-gpu GEM/blob resources in the guest and exports guest
   PRIME dma-bufs.
3. CPU-lockable allocations use the qualified host-visible blob mapping; GPU
   device-local allocations remain unmapped.
4. GEM, dma-buf, Android native-handle, and gfxstream resource lifetimes agree;
   there is no paravirtual lifetime socket to a guest gfxstream host.
5. Android surfaces cross from the LXC container to the compositor through the
   existing guest-local fd-capable channel with their exact plane layout and
   acquire fence. Release synchronization returns through that same guest-local
   contract.

The LXC configuration bind-mounts the same render node used by the compositor,
mounts an isolated binderfs instance, grants only the required device
major/minor pairs, installs the correct render group, delegates the required
cgroup subtree, and aligns SELinux and AppArmor policy with those resources.
The card node enters the container only when a behaviorally proven Android
operation requires modesetting ioctls; ordinary rendering uses the render node.

The bare-metal product retains one local Linux gfxstream host. Its socket and
shared-ring transport remain the correct placement implementation behind the
Phase 1 normalized same-build contracts.

`GfxstreamHostPlacement` is bound by the built product:

- `nucleus_x86_64` → `local`;
- `nucleus_arm64` → `paravirtual`.

No gfxstream host process runs inside the Apple guest. Android and the
compositor receive separate contexts from the one macOS renderer and share
resources only through standard virtio-gpu GEM/PRIME and synchronization
mechanisms.

The Nucleus composer continues to expose Android applications as individual
surfaces and window metadata to the Wayland compositor. SurfaceFlinger does not
compose a full virtual display in the normal path.

Phase gate:

1. The arm64 Android 17 image boots in LXC and passes binder, cgroup, AppArmor,
   SELinux, networking, storage, and render-node probes.
2. A Vulkan Android application and a GL-through-Zink application render through
   the macOS gfxstream renderer.
3. An Android surface arrives as a guest dma-buf in the compositor, completes a
   real acquire/release fence cycle, and remains GPU-resident through final
   composition.
4. No gfxstream host process or second renderer exists inside the VM.
5. The amd64 product passes its existing local-host behavior tests after the
   common-source move.

## Phase 12 — Build the Hermetic x86_64 Application Runtime

The Apple guest gains one unprivileged x86_64 application runtime. It is a
userspace payload inside the arm64 distribution, not an amd64 distribution,
kernel, VM, Nucleus build, or Android product. An arm64 supervisor owns its
installation, namespaces, lifecycle, health, storage, and connection to native
guest services.

Collider assembles the runtime as a locked filesystem hierarchy containing:

- the x86_64 ELF interpreter and glibc closure;
- the Steam Linux runtime and the pinned 64-bit Wine/Proton closure used for
  qualification;
- the x86_64 Vulkan loader, Mesa gfxstream ICD, OpenGL loader, and Zink build
  from the same Phase 3 compatibility lock as the arm64 graphics stack;
- x86_64 Wayland, X11 client, PipeWire, PulseAudio-client, ALSA, controller, font,
  locale, networking, and graphics dependencies required by the pinned
  runtime;
- DXVK and vkd3d-proton builds whose architecture, loader paths, Vulkan profile,
  and cache identity are recorded in the artifact lock;
- static, dynamically linked, Vulkan, Wayland, audio, input, and process-model
  health probes plus CPUID, instruction-set, 16 KiB page, virtual-memory,
  executable-mapping, signal, and thread fixtures.

Open-source x86_64 components build in the pinned Linux/amd64 OCI execution
platform. Rosetta is a shipping execution facility, not a build executor.
Externally distributed Steam components enter through their supported
installation source and must pass the same architecture and dependency
inventory before qualification.

The runtime enters dedicated mount, user, PID, IPC, network, cgroup, AppArmor,
and seccomp policy beneath the VM boundary. It receives only:

- the compositor's Wayland socket and one native arm64 rootless Xwayland
  endpoint for games that still require X11;
- PipeWire, PipeWire-Pulse, and controller endpoints;
- the virtio-gpu render node, never the KMS card node;
- its immutable runtime hierarchy, writable prefix, game-library storage, and
  bounded cache directories;
- the network and host-integration services explicitly required by the desktop
  policy.

The arm64 supervisor launches the x86_64 entry point normally. The kernel's
Phase 6 binfmt registration selects Apple's mounted translation runtime; no
launcher probes Rosetta availability, invokes a second emulator, or enables
TSO for native arm64 threads. `--fix-binary yes` keeps the registered
interpreter valid across the runtime's mount namespace.

The absolute x86_64 dynamic-loader paths resolve inside the runtime hierarchy.
An x86_64 process never loads an arm64 shared object, and an arm64 process never
loads an x86_64 plug-in. Cross-architecture interaction occurs only through
kernel ABIs and framed IPC: Wayland, X11, PipeWire, evdev, DRM ioctls, dma-buf,
and synchronization fds.

The macOS host owns Apple's AOT cache endpoint. The guest runtime persists
separate bounded caches for Wine/Proton, DXVK, vkd3d-proton, Mesa, and shader
pipelines. Every guest cache key includes the exact producer and graphics
compatibility lock. A lock change invalidates the incompatible cache directly
instead of preserving readers for old formats.

The documented Apple handler recognizes x86_64 ELF. This phase does not install
an i386 Linux library hierarchy or register an i386 ELF interpreter. A future
32-bit Windows application is supportable only when the pinned 64-bit
Wine/Proton Unix process implements it without launching an i386 Linux ELF
helper; that behavior is not inferred here.

Phase gate:

1. The runtime is assembled reproducibly and contains no arm64 library in its
   x86_64 dependency closure.
2. Static and dynamically linked x86_64 probes start through Apple's registered
   interpreter inside the final namespace and security policy; their observed
   CPUID features match successful instruction execution, and their memory and
   process behavior passes on the unmodified 16 KiB guest page size.
3. The x86_64 Vulkan probe opens the same virtio-gpu render node as the arm64
   compositor and passes the Zink, DXVK, and vkd3d-proton profiles.
4. x86_64 Wayland and Xwayland clients present dma-buf-backed surfaces to the
   arm64 compositor with real acquire and release synchronization.
5. Audio, keyboard, relative mouse, gamepad, and supported force feedback reach
   translated clients through standard guest interfaces.
6. Runtime termination, guest reboot, and host-app relaunch release processes,
   fds, mappings, controllers, audio streams, and cache locks without corrupting
   the persistent prefix or game library.
7. No amd64 kernel, translated first-party process, second GPU device, second
   gfxstream renderer, or framebuffer streaming path exists.

## Phase 13 — Bring Up 64-bit D3D9–11 and OpenGL Games

The translated runtime brings up the pinned 64-bit Steam and Proton/Wine path
with DXVK as the only Direct3D 9, 10, and 11 renderer. Wine's Vulkan bridge
loads the x86_64 Mesa gfxstream ICD directly. It does not fall back to a CPU
renderer, a host display stream, or a second Vulkan implementation.

Windows OpenGL uses Wine's OpenGL bridge and the x86_64 Mesa Zink path over that
same gfxstream Vulkan ICD. It does not introduce a native host OpenGL backend or
software rasterizer.

The Phase 6 guest kernel exposes the synchronization and process primitives
required by the pinned Proton build. The runtime host-requirements probe derives
the exact `ntsync` or futex backend, `futex_waitv`, eventfd, epoll, pidfd,
memfd, namespace, and seccomp requirements from the compatibility lock and
tests both the built kernel and live devices.

Native arm64 rootless Xwayland serves games without a native Wayland path and
forwards each window to Nucleus; it never becomes the final compositor.
Fullscreen, borderless, resolution changes, scaling, focus, relative-pointer
capture, keyboard grabs, controller hotplug, audio-device changes, and orderly
process termination remain Nucleus policies expressed through standard
protocols.

DXVK state, shader, and pipeline caches persist under the compatibility-lock
identity. Qualification separates cold first-use compilation from warmed play
and records every cache miss capable of causing a frame hitch. Background
compilation never blocks the VZ custom-device queue or compositor presentation
thread.

Bring-up proceeds through 64-bit behavioral fixtures before representative
games:

1. Direct3D 9 device creation, draw, resize, fullscreen, and presentation;
2. Direct3D 10 resource, shader, and presentation behavior;
3. Direct3D 11 multithreaded submission, compute, queries, resource sharing,
   resize, and presentation;
4. Windows OpenGL context creation, sharing, shader compilation, resize, and
   presentation through Zink;
5. device loss, process crash, compositor restart, and guest shutdown;
6. representative CPU-bound, GPU-bound, shader-compilation-heavy, controller,
   audio, and high-refresh 64-bit titles.

Phase gate:

1. Every D3D9–11 and Windows OpenGL fixture renders through DXVK or Zink, the
   x86_64 gfxstream ICD, the single host renderer, and the caller-owned Metal
   layer.
2. No fixture selects WineD3D software rendering or performs a frame-sized CPU
   readback, copy, or upload in steady state.
3. Windowed, borderless, fullscreen, relative mouse, controller, audio, and
   focus behavior pass through both native Wayland and rootless Xwayland paths
   where applicable.
4. Warmed representative titles meet their declared frame-time, pacing, audio,
   input, memory, and cache targets from Phase 15.
5. A title is never marked compatible from launcher or menu success alone; the
   qualification workload reaches sustained interactive rendering and clean
   shutdown.

## Phase 14 — Bring Up 64-bit D3D12 and Windows Vulkan Games

The pinned vkd3d-proton build becomes the Direct3D 12 implementation. Its exact
Vulkan profile is a hard device contract, including descriptor indexing,
update-after-bind limits, robustness, push descriptors, shader draw parameters,
mirror clamp, synchronization, and the selected descriptor-buffer or
mutable-descriptor path. The profile records numerical limits; it does not
reduce them to extension names or a Vulkan version.

The same phase qualifies 64-bit Windows Vulkan applications through Wine's
Vulkan bridge. Both paths use the x86_64 Mesa gfxstream ICD and the same resource
and fence namespace as DXVK, Android, and the compositor. D3D12 does not receive
a separate renderer or Metal interop shortcut.

Bring-up covers the pinned supported D3D12 feature baseline, root signatures,
descriptor heaps, graphics and compute pipelines, barriers, timeline behavior,
queries, memory budgeting, pipeline libraries, swapchain recreation, and device
loss. Sparse, video, mesh, and other advanced features enter the contract only
when the pinned vkd3d-proton profile requires them; unsupported features fail
device or application qualification explicitly.

Phase gate:

1. The complete vkd3d-proton profile passes through Mesa, gfxstream, MoltenVK,
   and Metal with the same values observed by the x86_64 application.
2. A 64-bit D3D12 behavioral suite and a 64-bit Windows Vulkan suite render,
   resize, synchronize, recover from device loss, and terminate cleanly.
3. Representative D3D12 games complete sustained interactive workloads without
   a CPU graphics fallback, full-frame CPU transfer, unbounded descriptor or
   resource growth, or an additional queued frame.
4. Warmed workloads meet their declared Phase 15 performance targets; cold
   shader and pipeline work is reported separately and populates persistent
   caches for the next run.
5. Missing Metal, MoltenVK, gfxstream, or Mesa functionality is attributed to
   the exact failed profile field and never reported as generic Proton
   incompatibility.

## Phase 15 — Qualify Frame Pacing, Copies, Latency, and Compatibility

The host, device model, guest compositor, Android runtime, translated runtime,
and graphics compatibility layers emit one correlated trace with these stages:

1. AppKit event receipt;
2. virtio-input enqueue;
3. guest evdev receipt;
4. compositor, Android, or Wine/Proton dispatch;
5. Zink, DXVK, or vkd3d-proton submission when applicable;
6. guest Vulkan submission;
7. host gfxstream decode and dispatch;
8. Metal command-buffer schedule;
9. GPU completion;
10. drawable presentation.

The trace also records the native or translated architecture of each process,
the TSO result for translated work, AOT endpoint and cold/warm launch state,
graphics-cache state, API path,
swapchain depth, audio-buffer depth, audio underruns, shader and pipeline
compilation, descriptor pressure, and every guest/host queue transition.

Session identity correlates records but does not claim synchronized clocks. The
control plane performs periodic host/guest midpoint sampling, computes the
monotonic-clock offset and uncertainty, and attaches the calibration generation
to every cross-boundary trace. Reports include p50, p95, p99, maxima, missed
deadlines, queue depth, and calibration uncertainty.

The final presentation pipeline uses two drawables, late drawable acquisition,
asynchronous fence completion, batched command submission, interrupt
coalescing, and persistent translation, shader, and pipeline caches. Guest
applications may maintain the buffering required by their declared present
mode, but virtualization and the host presenter add no queued frame. No VZ
device serial queue waits for Metal, translation, shader compilation, a fence,
audio, or drawable acquisition. Cold AOT, shader, and pipeline work is measured
separately from the warmed steady-state lane.

Every path capable of readback, upload, staging, format conversion, GPU blit, or
software composition increments an attributed counter with byte and frame
counts. The qualification lane fails on any steady-state frame-sized CPU
readback, CPU copy, or CPU upload. GPU conversions and blits remain visible in
the report and require a named workload reason.

The hard desktop and Android 120 Hz steady-state targets are:

- host AppKit event to guest evdev p99 no greater than 1 ms;
- gfxstream decode and dispatch p99 no greater than 1 ms for the deterministic
  UI workload;
- zero virtualization-added queued frames;
- zero frame-sized CPU readbacks, copies, or uploads;
- missed compositor presentation deadlines no greater than 0.1% after cache
  warm-up;
- bounded queue depth and no monotonically growing in-flight resource, fence,
  mapping, or drawable count.

Gaming qualification uses a fixed matrix. Each workload records the exact game
build, Proton/Wine, Zink, DXVK or vkd3d-proton build, graphics profile,
resolution, quality settings, frame cap, display refresh, translated CPU
feature set, input path, cache state, and expected API feature baseline. Results
use these unambiguous states:

- **qualified at 120 Hz:** after warm-up, the declared workload meets an
  8.33 ms p99 frame budget with no more than 1% missed presents;
- **qualified at 60 Hz:** after warm-up, the declared workload meets a 16.67 ms
  p99 frame budget with no more than 1% missed presents;
- **functional:** sustained interactive play and clean shutdown pass, but the
  workload misses its declared performance target;
- **unsupported:** startup, API, graphics-profile, anti-cheat, DRM, bitness, or
  runtime behavior fails, with the exact reason recorded.

Every game lane hard-requires:

- zero virtualization-added queued frames;
- zero steady-state frame-sized CPU readbacks, copies, or uploads;
- bounded GPU, descriptor, mapping, fence, translation, audio, and drawable
  queues;
- host input to guest evdev p99 no greater than 1 ms;
- warmed guest-submit-to-host-render audio p99 no greater than 20 ms and zero
  underruns;
- no recurring observable translation, shader, or pipeline compilation for
  unchanged content;
- reported average, p50, p95, and p99 frame time, 1% and 0.1% low frame rate,
  missed-present rate, input-to-present, memory use, available cache counters,
  and power state.

A game becomes qualified only after a fixed sustained interactive workload. A
launcher, splash screen, menu, benchmark splash, or single rendered frame is
not compatibility evidence. Anti-cheat and DRM are reported independently from
rendering performance so a policy failure is never described as a GPU failure.

The reported end-to-end measure is input-to-present. It is not called
input-to-photon without an external optical measurement rig.

Phase gate:

1. Deterministic shell animation, scrolling, Android UI, video, and mixed
   Wayland/Android workloads satisfy the hard targets.
2. The D3D9–11, Windows OpenGL, D3D12, and Windows Vulkan behavioral suites
   satisfy their absolute copy, buffering, resource, synchronization, input,
   audio, and cache contracts.
3. The declared representative-game matrix publishes a reproducible state and
   complete metric set for every title; every qualified title meets its 60 Hz
   or 120 Hz target.
4. Heavy Vulkan, GL, DXVK, and vkd3d-proton workloads never weaken the desktop
   and Android target.
5. Reset, resize, focus transition, display migration, translated-process
   failure, controller or audio-device loss, and application churn do
   not add an unbounded queue or a latent extra frame.
6. The physical Linux and Apple virtualization qualifiers each pass their
   absolute contracts; neither is treated as the timing oracle for the other.

## Phase 16 — Settle Qualification Roles and Documentation

Collider adds an Apple-native-guest qualifier and an Apple-translated-gaming
qualifier hosted by the M2 Ultra. The existing physical GPU/DRM qualifier
continues to own Linux/amd64 behavior on real DRM hardware. The Apple native
role owns VM, compositor, Android, standard device, and desktop performance
contracts. The translated role owns x86_64 ELF, TSO, AOT, x86_64 gfxstream,
Proton, Zink, DXVK, vkd3d-proton, game input/audio, and compatibility-matrix
contracts. Each role builds and qualifies its own declared artifacts from the
same source revision; none substitutes for another.

[GitHub Actions Self-Hosted CI Plan](github-actions-self-hosted-runner-plan.md)
distinguishes the shipping virtualization qualifier from the physical Linux
qualifier. [macOS Remote Development Plan](macos-remote-development-plan.md)
keeps the shipping VM runtime separate from the host-owned development
checkout.
[Single-root SwiftPM Architecture](single-root-swiftpm-architecture.md)
is updated with Linux/amd64, Linux/arm64, Android/amd64, Android/arm64, and
macOS/arm64 artifact destinations plus the distinct x86_64 Apple-guest runtime
assembly role.

`AGENTS.md`, `CLAUDE.md`, target setup documentation, and runtime architecture
documentation state:

- the two shipping runtime targets;
- Vulkan-first output allocation;
- guest-owned GEM/dma-buf identity;
- one macOS gfxstream renderer with separate client contexts;
- immutable gfxstream host placement;
- the 16 KiB Android 17 guest contract;
- the arm64-guest/x86_64-application translation boundary;
- unconditional macOS 27 translation-share and AOT-cache configuration;
- guest VirtioFS, binfmt, dynamic-library, and per-thread TSO ownership;
- the separate Nucleus, Zink, DXVK, and vkd3d-proton Vulkan profiles;
- gamepad, force-feedback, PipeWire, and virtio-sound ownership;
- the gaming compatibility states and qualification methodology;
- the macOS host product and entitlement;
- qualification commands and failure interpretation.

Phase gate:

1. `collider doctor`, `collider bootstrap`, `collider build`, and
   `collider test` pass for every declared destination from the documented
   complete-checkout sequence.
2. The physical Linux, Apple native-guest, and Apple translated-gaming
   qualification lanes pass.
3. A clean operator procedure produces, signs, boots, diagnoses, and shuts down
   the app; verifies translation readiness; manages the x86_64 runtime, caches,
   prefixes, and game storage; and explains every qualification result without
   undocumented state.
4. Documentation contains no CPU display fallback, nested gfxstream design,
   macOS-created dma-buf, global-fence-timeline claim, Rosetta-in-Android claim,
   amd64-guest claim, global-TSO instruction, or implication that Vulkan 1.4
   alone qualifies Proton.

## Final Verification Gates

The target is complete only when every gate passes in this order:

1. The existing Linux architecture is normalized, its baseline behavior is
   preserved, and its resource, presentation, placement, protocol, AOSP, Vulkan
   profile, and telemetry contracts have one owner each.
2. Collider admits and isolates the Linux/arm64 and macOS/arm64 coordinates and
   distinguishes the x86_64 Apple-guest runtime from Linux/amd64 Nucleus.
3. The production-shaped slice proves macOS 27 translation-share and AOT setup,
   x86_64 ELF execution, per-thread TSO, standard virtio-gpu binding, all four
   Vulkan profiles, cross-architecture dma-buf and fence sharing, 64-bit
   Windows OpenGL, D3D11, and D3D12 fixtures, Metal presentation, and reset-safe
   16 KiB mappings.
4. The complete Linux/arm64 product closure builds and passes its noninteractive
   lanes.
5. Vulkan-first output allocation passes on physical DRM and VZ virtio-gpu, and
   the compositor-owned GBM allocator is gone.
6. The pinned Android Common Kernel and persistent guest satisfy every declared
   Android/LXC, VirtioFS, binfmt, TSO, and Proton process-primitive requirement.
7. The signed macOS app validates and attaches the read-only RAW root plus the
   DiskImageKit RAW-base/ASIF data stack, configures the required translation
   share and AOT cache, boots the guest, and controls it through the bounded
   typed vsock channel. Stopped-disk restore branching and crash recovery pass
   without claiming live VM state capture.
8. The complete virtio-gpu device passes protocol, security, all Vulkan
   profiles, cross-architecture resource-sharing, presentation, fuzz, and reset
   gates.
9. The complete Wayland compositor renders and reconfigures continuously in the
   VM.
10. Standard virtio-input and virtio-sound provide correct keyboard, pointer,
    gamepad, force-feedback, audio, cursor, seat, and output-topology behavior.
11. Android 17 arm64 runs in LXC, exports individual application surfaces through
    guest PRIME dma-bufs, and has no guest gfxstream host.
12. The hermetic x86_64 runtime passes architecture, loader, sandbox, Vulkan,
    Wayland/Xwayland, audio, input, cache, lifecycle, and cross-architecture
    sharing gates without an amd64 guest.
13. The 64-bit D3D9–11 DXVK and Windows OpenGL/Zink paths pass their behavioral
    and representative-game gates without a software or copy fallback.
14. The 64-bit D3D12 vkd3d-proton and Windows Vulkan paths pass their profile,
    behavioral, representative-game, and bounded-resource gates.
15. Desktop, Android, and every declared game workload pass the applicable
    pacing, copy, latency, audio, cache, and compatibility targets.
16. All three qualification roles and the documented complete-checkout and
    operator workflows pass.

## Out of Scope

Running the compositor natively on macOS is not a target. The compositor
requires Linux DRM/KMS, libinput, io_uring, namespaces, cgroups, binderfs, and
LXC.

Translated Nucleus or Android userspace is unsupported. The supported
translation boundary contains selected third-party x86_64 Linux applications,
Steam, Proton/Wine, and 64-bit Windows game code only. An arm64 Android process
cannot load an x86_64 application library without an Android native bridge;
x86-only APK native libraries are outside this plan.

An amd64 Linux kernel or bootable distribution, i386 Linux ELF runtime, 32-bit
Windows game contract, translated first-party plug-in, second VM, second
virtio-gpu device, and second gfxstream renderer are outside this plan. A future
32-bit Windows target must prove a 64-bit Wine/Proton Unix-process path without
assuming that Apple's x86_64 ELF handler translates i386 Linux executables.

Windows kernel drivers, kernel-mode anti-cheat, VM-hostile DRM, GPU passthrough,
DirectX Raytracing, and VR are outside the initial compatibility contract.
Proton-enabled user-mode anti-cheat is supported only for titles that pass the
same sustained behavioral qualification as every other game. The plan promises
the declared compatibility matrix, not universal Windows-game compatibility.
A title requiring an instruction that macOS 27's translated CPU profile does
not advertise is unsupported; Nucleus never fabricates CPUID support.

Custom-device save/restore, VM snapshots containing live gfxstream state,
online disk checkpoints, ASIF layer merge or compaction, live migration, macOS
26 and earlier, macOS guests, Intel Mac hosts, non-Apple hypervisors,
`VZVirtualMachineView` framebuffer presentation, software rendering, and
streamed-display fallbacks are outside this plan.

The AOSP Repo-manifest ownership exception, first-party C/C++ bridge rules,
Swift visibility contract, and root-package product boundaries remain in force.
