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
       └─ optional NucleusAndroidRuntime
            ├─ privileged LXC launcher
            ├─ Android 17 userspace
            └─ graphics broker and display host
```

The supervisor starts the compositor first, waits for typed physical-presentation readiness, then starts the shell and optional capabilities. Required child failure retires the complete session. Shutdown proceeds from optional services to shell to compositor so producers stop before consumers disappear.

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

## Verification boundary

Agent-runnable verification uses Collider and direct host tests after sourcing `tools/host-env.sh`. Hardware qualification, device installation, compositor launch, and interactive sessions remain explicit user-run handoffs. Current execution plans and their dependency order are indexed in [README.md](README.md).
