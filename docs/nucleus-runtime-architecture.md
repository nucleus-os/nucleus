# Nucleus runtime architecture

This document is a current architecture reference, not an implementation diary.

## Invariants

- The root `Package.swift` owns every first-party runtime target.
- Collider is a separate build-tool package with a reusable engine at `collider/engine/`.
- Runtime processes exchange typed capabilities and narrow protocols, not ambient global state or unvalidated dictionaries.
- GPU resources stay GPU-resident through rendering, cross-process presentation, Android integration, capture, and scanout whenever the platform contract permits it.
- One owner exists for each lifecycle, file descriptor, GPU object, process, session coordinate, and persisted artifact.

## Runtime graph

```text
nucleus-session
  └─ nucleus-session-supervisor
       ├─ NucleusCompositor
       │    ├─ Wayland server and desktop policy
       │    ├─ Nucleus render server
       │    └─ DRM/KMS presentation
       ├─ NucleusShell
       │    ├─ NucleusUI product surfaces
       │    ├─ Wayland client/input/render runtime
       │    └─ Linux service projections
       └─ installed Android package capability
            ├─ privileged LXC launcher
            ├─ Android 17 userspace
            └─ graphics broker and display host
```

The supervisor starts the compositor first, waits for typed physical-presentation readiness, then starts the shell and selected installed capabilities. The base runtime has no Android binaries or declaration; the architecture-matched `nucleus-android` native package contributes its declaration through the external capability registry. Required child failure retires the complete session. Shutdown proceeds from optional services to shell to compositor so producers stop before consumers disappear.

## Package graph

`core/` owns portable render/UI code and the Android application host. `react-native/` owns Hermes, Fabric, and RN bridges. `compositor/` owns Wayland/DRM policy and presentation. `shell/` owns first-party desktop product UI. `config/`, `session/`, and `platform-linux/` own shared service and platform contracts.

Supported external Swift source products are `Nucleus`, `NucleusDesktop`, `NucleusReactRuntime`, `NucleusFoundation`, `NucleusSessionProtocol`, and `NucleusAndroidRuntimeCore`. First-party cross-module APIs use `package` visibility. Dynamic libraries define deployment boundaries but do not automatically widen source API.

Every Swift target enables C++ interoperability. C and C++ shims remain narrow; Swift domain models carry opaque handles and scalars, not imported implementation types. Throwing C++ code is contained behind `noexcept` entry points.

## Rendering and presentation

The retained render model and renderer are platform-neutral. Platform presenters supply window/swapchain or DRM targets and explicit synchronization. The Linux compositor composes Wayland surfaces, attempts direct scanout only when all correctness gates pass, and falls back to composition without changing client-visible semantics.

The shell uses the same render core through Wayland WSI. Android application hosting uses an Android Vulkan swapchain. The Android desktop runtime exports broker-owned buffers to the compositor with explicit acquire/release synchronization. No supported path copies a full framebuffer through CPU memory each frame.

## Session and configuration

The launcher owns XDG roots, the private runtime directory, private session bus, standard environment coordinates, and immutable launch configuration. The compositor owns the Wayland socket and display state. The shell receives no privileged Wayland identity.

The configuration service is the only reader/writer of the user desktop JSON document. It validates `NucleusConfiguration` and publishes typed render-server and shell projections with epoch/generation identity. Invalid reloads preserve the last valid generation.

## Toolchains and artifacts

macOS uses Xcode. A native Linux/arm64 Apple container uses the matching
official Swift.org compiler as a bootstrap compiler. Nucleus never builds a
Swift compiler, Swift driver, LLVM, Clang, or Linux host tools. Collider builds
the Linux target standard library and overlays natively for arm64 and by
cross-compilation for amd64, assembles them into one Linux Swift SDK, installs
the Android Swift SDK artifact, and provisions the render/RN native SDKs under
the user cache.

Collider owns declared task graphs, planning, execution, artifact identity, locks, and records. Underlying build systems retain their own incremental state. Source submodules are validated pinned inputs and are never mutated by Collider.

Collider currently installs one executable on macOS. `ColliderCLI` owns the
single root grammar and process lifecycle, and `ColliderWorkspaceCommands` owns
checkout-oriented commands and catalog construction. The source graph retains
`ColliderLinuxOperations` for installed-session and Linux development operations,
but no supported setup, launcher, or OCI backend currently exposes a Linux-host
Collider build. Recipe modules continue to own Linux-target artifact actions.

```text
Collider executable
  └─ ColliderCLI
       ├─ ColliderWorkspaceCommands
       └─ ColliderLinuxOperations [Linux only]
            └─ ColliderWorkspaceCommands
```

There is no reverse dependency, runtime command registration, or second
platform-specific executable. The supported macOS command exposes only
checkout operations. Linux-host command composition remains inactive until the
rootless Linux backend and setup contract land together.

On macOS, Collider talks to Apple container services in process through the
upstream Swift APIs for health, networks, image build/inspection/pruning, disk
usage, container creation, process execution, and cleanup. Only the current-user
login-session bootstrap script invokes the installed `container` executable,
because it must establish and verify the service before Collider can use its
API. The bootstrap installs its launcher under the user's Library and requires
no elevated privileges. The single root runtime package contains Linux
system-library targets, but pkg-config discovery for those targets is enabled
only when SwiftPM evaluates the manifest on Linux. Planning the Collider package
on macOS neither searches for those Linux packages nor compiles their targets.
Linux target builds resolve their system libraries from the selected Swift SDK's
architecture-specific pkg-config paths.

Collider recipes declare typed actions, inputs, outputs, execution placement,
filesystem effects, and locks. Planning lowers those declarations into one
deterministic DAG. The runtime schedules ready tasks through bounded lightweight
host and OCI lanes plus one host-exclusive barrier that runs without other work.
Shared reads and exclusive
writes prevent overlapping filesystem effects across every lane. Concrete OCI
CPU and memory limits remain properties of the container execution rather than
inputs to a fictional aggregate host-capacity model. The runtime emits
structured run records and validates declared outputs before recording
successful task state. Actions
cannot construct nested execution graphs or bypass the runtime's process,
container, lock, record, or artifact ownership. The download manager keeps only
resumable transfer state in `ColliderDownloads`; after verification, recipes move
the bytes into their component-owned destinations. Collider does not snapshot
generated or extracted outputs into a second cache.

## Storage ownership and lifecycle

The resolved component catalog is Collider's sole generated-storage inventory.
Each declaration identifies its component owner, task or runtime producers,
storage class, safety root, cleanup policy, active-generation link, inactive
rollback count, and candidate naming convention. Catalog validation rejects
removable storage that overlaps source or identity data, lies outside its safety
root, or lacks the producer locks needed to mutate it.

Source and identity data are never cleanup candidates. Incremental build roots
remain until `collider clean <component>` explicitly removes the selected
component's declared roots. Run records use bounded retention. Only declarations
with an explicit prune policy participate in `collider cache prune`; ordinary
build and test operations perform only bounded candidate and generation
retention cleanup.

Publication validates a complete candidate before installing an immutable
generation and atomically replacing its activation symlink. Retention preserves
the active generation and the declaration's exact number of inactive rollback
generations. Rolling back is the same atomic activation operation pointed at a
retained generation. Interrupted publication never exposes partial output.

`clean` and `cache prune` derive their mutation locks from the resolved producer
tasks and acquire them through the task runtime. Runtime-owned removable state
without a shared lock is invalid. These are kernel file locks, so task
cancellation or process death releases ownership without a stale lease or manual
repair. Status is observational and tolerates entries disappearing during a
concurrent prune.

On macOS, Collider resolves caches, Apple-container state, artifacts, and logs
through the conventional per-user storage layout on the default Data
filesystem. Linux trees that require case-sensitive semantics live inside
Apple-container persistent volumes rather than loose host directories. This
placement does not create a second ownership model: `collider cache status`
reports the same catalog declarations and sparse-volume allocation metadata.

Run terminalization retains the newest 20 terminal records and the newest failed
record in addition, while never treating an active run as reclaimable. Explicit
cache pruning uses the same selection policy with its requested retention count.

Host Swift actions always invoke SwiftPM with the `swiftbuild` build system;
SwiftPM and llbuild exclusively own source-level incrementality. Collider asks
SwiftPM for its public bin path and exposes it to downstream tasks through a
stable Collider-owned products link rather than reconstructing SwiftPM's private
scratch layout. Target Swift actions retain a declared-input gate outside the
container so unchanged work avoids container startup.

The Linux arm64 builder starts from the exact official Swift 6.4 compiler
archive. Collider then resolves the exact pinned SwiftPM closure on the host,
compiles the pinned Nucleus SwiftPM and SwiftBuild sources offline and natively
for arm64 in a persistent workspace, and assembles a deterministic overlay. The
overlay contains only the arm64 `swift-package-manager` executable, its
`swift-package` and `swift-build` links, matching resource bundles, and
source/compiler provenance. Collider
publishes it as a bounded host artifact and mounts it read-only at
`/swiftpm-overlay` for production SwiftPM actions. The single stable builder
image retains the official adjacent SwiftPM tools for bootstrap work but never
contains or depends on the overlay. Production actions address the mounted
executable explicitly, so overlay changes do not rebuild or unpack the
heavyweight image. No remote release or GitHub-hosted build participates. Its SwiftBuild patch
preserves the host SDK through host-build-tool dependency specialization when
the destination is another Linux architecture. Collider invokes the mounted
unified executable directly with an explicit command mode and selects the
official arm64 compiler through `SWIFTPM_CUSTOM_BIN_DIR`. Both Linux target lanes
therefore run the arm64 host compiler and SwiftPM process natively; x86_64
remains only a target triple and target SDK, not a translated host compiler.

The Swift target-SDK workspace is one immutable generation graph. Collider
validates the pinned source gitlinks, prepares exact Linux sysroots, builds the
Linux/arm64 target runtime natively in the Apple-container builder, cross-builds
the Linux/amd64 target runtime in that same arm64 environment, and assembles one
relocatable Linux Swift SDK with both target variants. It also installs the
official Android Swift SDK artifact and validates Linux and Android consumers
for both architectures. Unchanged tasks reuse their declared outputs; source
identity changes invalidate only dependent tasks. Every C++ closure links
libc++, and validation rejects `libstdc++` and `GLIBCXX` dependencies.

## Verification boundary

Agent-runnable verification uses the installed `collider` command, whose
workspace launcher derives the host environment and refreshes its release
executable when the active checkout's Git/toolchain source fingerprint changes.
Hardware qualification, device
installation, compositor launch, and interactive sessions remain explicit
user-run handoffs. Current execution plans and their dependency order are
indexed in [README.md](README.md).
