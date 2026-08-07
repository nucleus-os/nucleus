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
       └─ installed Android add-on capability
            ├─ privileged LXC launcher
            ├─ Android 17 userspace
            └─ graphics broker and display host
```

The supervisor starts the compositor first, waits for typed physical-presentation readiness, then starts the shell and selected installed capabilities. The base runtime has no Android binaries or declaration; a verified architecture-matched add-on contributes its declaration through the external capability registry. Required child failure retires the complete session. Shutdown proceeds from optional services to shell to compositor so producers stop before consumers disappear.

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

Collider installs one executable on macOS and Linux. `ColliderCLI` owns the
single root grammar and process lifecycle, `ColliderWorkspaceCommands` owns
checkout-oriented commands and catalog construction, and
`ColliderLinuxOperations` owns installed-session and Android add-on operations.
The CLI composes the Linux module only in Linux builds; workspace commands do
not import runtime products or expose installed-host behavior conditionally.
Recipe modules continue to own Linux-native artifact actions.

```text
Collider executable
  └─ ColliderCLI
       ├─ ColliderWorkspaceCommands
       └─ ColliderLinuxOperations [Linux only]
            └─ ColliderWorkspaceCommands
```

There is no reverse dependency, runtime command registration, or second
platform-specific executable. macOS exposes only checkout operations. Linux
adds `run`, session and Android add-on installation, and Android add-on
packaging through the compile-time `ColliderCLI` composition.

On macOS, Collider talks to Apple container services in process through the
upstream Swift APIs for health, networks, image build/inspection/pruning, disk
usage, container creation, process execution, and cleanup. Only the privileged
login-session bootstrap script invokes the installed `container` executable,
because it must establish and verify the service before Collider can use its
API. SwiftPM may still print missing pkg-config-file warnings while planning the
Collider package on macOS: the single root runtime package contains Linux
system-library targets, but those targets are not compiled into the macOS CLI.
Linux target builds resolve their system libraries from the selected Swift
SDK's architecture-specific pkg-config paths.

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
container, lock, record, or artifact ownership. Content-addressed downloads live
only in the `ColliderDownloads` cache; Collider does not snapshot generated or
extracted outputs into a second cache.

Run terminalization retains the newest 20 terminal records and the newest failed
record in addition, while never treating an active run as reclaimable. Explicit
cache pruning uses the same selection policy with its requested retention count.

Host Swift actions always invoke SwiftPM with the `swiftbuild` build system;
SwiftPM and llbuild exclusively own source-level incrementality. Collider asks
SwiftPM for its public bin path and exposes it to downstream tasks through a
stable Collider-owned products link rather than reconstructing SwiftPM's private
scratch layout. Target Swift actions retain a declared-input gate outside the
container so unchanged work avoids container startup.

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
