# Nucleus

A platform for building native desktop applications and operating system UI — composed in Swift, rendered with Skia Graphite over Vulkan, running on Linux.

Nucleus is one monorepo containing independently buildable Swift packages:

| Component | Role |
|---|---|
| [`core`](core) | The shared **render/UI core** — React-agnostic and platform-agnostic. |
| [`react-native`](react-native) | The **React Native platform** — Fabric, Hermes, JSI, and the RN native stack. |
| [`compositor`](compositor) | The **Wayland/DRM compositor** — server, renderer backend, and policy; zero React. |
| [`shell`](shell) | The first-party **desktop shell** — an out-of-process React Native layer-shell client. |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Wayland Protocols                     │
│  wlr-layer-shell · foreign-toplevel · session-lock      │
│  screencopy · xdg-shell · …                            │
└────┬────────────────────────────────────┬────────────────┘
     │                                    │
     │  (socket)                          │
┌────▼───────────────┐        ┌───────────▼──────────────┐
│  nucleus-compositor │        │       nucleus-shell       │
│                     │        │                           │
│  Wayland server     │        │  Wayland client           │
│  DRM/KMS scanout    │        │  VK_WSI wl_surface        │
│  Window policy      │        │  RN app (bar, dock, …)   │
│  Shell overlay      │        │                           │
│  (NucleusUI)        │        │                           │
└────┬────────┬───────┘        └───────┬──────────────────┘
     │        │                        │
     │        │                        │  (relative path)
     │        │           ┌────────────▼────────────┐
     │        │           │   nucleus-react-native   │
     │        │           │                           │
     │        │           │  Fabric · Hermes · JSI   │
     │        │           │  Native module bridge     │
     │        │           │  RN codegen · build       │
     │        │           └───────┬──────────────────┘
     │        │                   │
     │        │                   │  (relative path)
     │        └───────────────────┼───────────────────┐
     │                            │                   │
     │                            │  (relative path)  │
┌────▼────────────────────────────▼───────────────────▼────┐
│                         nucleus                           │
│                                                           │
│  NucleusTypes · NucleusLayers · NucleusRenderModel        │
│  NucleusRenderer (Skia Graphite + Dawn + Vulkan)          │
│  NucleusTextBackend · NucleusUI · NucleusApp              │
│  NucleusRenderHost · NucleusAppHostProtocols              │
│  NucleusSkiaGraphiteBridge · native SDK tooling           │
└───────────────────────────────────────────────────────────┘
```

### Key design principles

- **`core/` is the single source of truth** for rendering, layout, and the UI framework. Other packages consume it through relative SwiftPM paths.
- **The compositor links zero React.** It provides the Wayland server, DRM/KMS scanout, window management, and a shell overlay built with NucleusUI — but React Native is not part of it.
- **The shell is out-of-process.** `nucleus-shell` is a normal Wayland client connected over `WAYLAND_DISPLAY`. The compositor and shell meet only at runtime over standard protocols — each is swappable independently.
- **The React Native platform remains an architectural boundary.** `react-native/` owns Fabric/Hermes/folly and the Swift runtime bridge, while living in the same atomic source-control unit.
- **Shared native SDKs.** The `render` SDK (Skia Graphite + Dawn + Vulkan) and the `rn` SDK (Hermes + ReactCommon + folly) are provisioned into `~/.cache/nucleus/nucleus-native-sdk/` by the root Swift bootstrap stage graph. All components consume from this stable cache path, decoupling build artifacts from any single source directory.

## Supporting components

- [`swift-vulkan`](swift-vulkan) — Swift Vulkan bindings (VulkanGen generator + generated typed API + vendored Khronos headers).
- [`swift-wayland`](swift-wayland) — Swift Wayland protocol bindings (server + client C façades + Swift dispatch).
- [`swift-tracy`](swift-tracy) — Swift bindings for the Tracy profiler.
- [`swift-toolchain`](swift-toolchain) — Swift toolchain build infrastructure.
- [`swift-android-sdk`](swift-android-sdk) — Swift Android SDK provisioning.

The bindings are first-party SwiftPM path dependencies and participate in
`tools/nucleus build all` and `tools/nucleus test all`. The toolchain and Android SDK are independently
buildable source components whose long-running release builds remain explicit; Nucleus
consumes their installed artifacts rather than building them during ordinary workspace builds.

## Building

Clone the canonical monorepo, then use the workspace CLI as the entry point for the complete checkout:

```sh
git clone --recurse-submodules git@github.com:nucleus-os/nucleus.git
cd nucleus
```

If the repository was cloned without `--recurse-submodules`, `bootstrap` initializes the
required third-party submodules.

```sh
tools/nucleus bootstrap
tools/nucleus build all
tools/nucleus test all
```

It selects the installed Nucleus Swift toolchain and runs the component
bootstrap sequence. SwiftPM, CMake, Ninja, Yarn, and the package generators own
their normal incremental state; the workspace does not maintain a second
fingerprint/cache layer around them.

The same Swift CLI owns the cross-component workflows that previously lived in
component shell scripts:

```sh
tools/nucleus android build
tools/nucleus android sdk build
tools/nucleus profile --launch --seconds 20
tools/nucleus install compositor
```

Because Nucleus is a DRM compositor rather than a nested Wayland client, launch
profiles must run from a free virtual terminal or a display-manager session where
another compositor does not already own the seat.

Long-running Swift toolchain and Android SDK compiler recipes remain shell-based
because they directly adapt upstream build systems; ordinary workspace dependency
ordering, verification, profiling, and packaging are Swift-owned.

All first-party SwiftPM dependencies use monorepo-relative paths. No sibling-repository
detection or local dependency override step is required.

The top-level CLI is the sole orchestration entry point; individual SwiftPM packages remain
directly buildable with `swift build --package-path …`.

See each component's README for focused build, rebuild, and test instructions.

## License

Copyright (C) 2026 Noesis Reality LLC. Licensed under the GNU General Public
License, version 3. See [`LICENSE`](LICENSE).
