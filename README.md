# Nucleus

A platform for building native desktop applications and operating system UI — composed in Swift, rendered with Skia Graphite over Vulkan, running on Linux.

Nucleus is one monorepo containing independently buildable Swift packages:

| Component | Role |
|---|---|
| [`core`](core) | The shared **render/UI core** — React-agnostic and platform-agnostic. |
| [`react-native`](react-native) | The **React Native platform** — Fabric, Hermes, JSI, and the RN native stack. |
| [`compositor`](compositor) | The **Wayland/DRM compositor** — server, renderer backend, and policy; zero React. |
| [`shell`](shell) | The first-party **desktop shell** — an out-of-process native Swift layer-shell client built with NucleusUI. |

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
│  Window policy      │        │  Native Swift product    │
│  Shell overlay      │        │  NucleusUI bar + lock    │
│  (NucleusUI)        │        │                           │
└────┬────────────────┘        └────────────┬──────────────┘
     │                                      │
     │             (relative SwiftPM paths) │
┌────▼──────────────────────────────────────▼──────────────┐
│                         nucleus                           │
│                                                           │
│  NucleusTypes · NucleusLayers · NucleusRenderModel        │
│  NucleusRenderer (Skia Graphite + native Vulkan)          │
│  NucleusTextBackend · NucleusUI · NucleusApp              │
│  NucleusRenderHost · NucleusAppHostProtocols              │
│  NucleusSkiaGraphiteBridge · native SDK tooling           │
└───────────────────────────────────────────────────────────┘
```

### Key design principles

- **`core/` is the single source of truth** for rendering, layout, and the UI framework. Other packages consume it through relative SwiftPM paths.
- **The compositor links zero React.** It provides the Wayland server, DRM/KMS scanout, window management, and a shell overlay built with NucleusUI — but React Native is not part of it.
- **The shell is out-of-process.** `nucleus-shell` is a normal Wayland client connected over `WAYLAND_DISPLAY`. The compositor and shell meet only at runtime over standard protocols — each is swappable independently.
- **The React Native platform is independent of the shell.** `react-native/` owns Fabric, Hermes, folly, and its Swift runtime bridge for RN applications; `shell/` does not depend on that package or SDK.
- **Native SDK ownership is explicit.** Render consumers use the `render` SDK (Skia Graphite + native Vulkan), while only `react-native/` consumes the `rn` SDK (Hermes + ReactCommon + folly). The root bootstrap provisions both under `~/.cache/nucleus/nucleus-native-sdk/`.

## Supporting components

- [`swift-vulkan`](swift-vulkan) — Swift Vulkan bindings (VulkanGen generator + generated typed API + vendored Khronos headers).
- [`swift-wayland`](swift-wayland) — Swift Wayland protocol bindings (server + client C façades + Swift dispatch).
- [`swift-tracy`](swift-tracy) — Swift bindings for the Tracy profiler.
- [`swift-toolchain`](swift-toolchain) — the Collider recipe that publishes the
  host compiler and Android Swift SDK as one user-level platform generation.

The bindings are first-party SwiftPM path dependencies and participate in
`tools/collider build all` and `tools/collider test all`. Swift platform rebuilds remain
explicit and publish the host toolchain and Android SDK together; ordinary workspace builds
consume the active generation.

## Building

Clone the canonical monorepo, then use the workspace CLI as the entry point for the complete checkout:

```sh
git clone --recurse-submodules git@github.com:nucleus-os/nucleus.git
cd nucleus
```

If the repository was cloned without `--recurse-submodules`, `bootstrap` initializes the
required third-party submodules.

```sh
tools/collider bootstrap
tools/collider build all
tools/collider test all
```

It selects the installed Nucleus Swift toolchain and runs the component
bootstrap sequence. SwiftPM, CMake, Ninja, Yarn, and the package generators own
their normal incremental state; the workspace does not maintain a second
fingerprint/cache layer around them.

The same Swift CLI owns the cross-component workflows that previously lived in
component shell scripts:

```sh
tools/collider android build
tools/collider toolchain rebuild
tools/collider install session
tools/collider run
```

`tools/collider run` is the complete development runtime entry point. It
incrementally builds the compositor, native Swift shell, PAM helper, and session
launcher into `.install/`, then starts that installed session. Launch it from a
free virtual terminal or a display-manager session because Nucleus owns the DRM
seat rather than nesting inside an existing Wayland/X11 desktop.

Runtime diagnostics use the same entry point, so the instrumented binaries and
the session being measured cannot drift apart:

```sh
tools/collider run --seconds 20
tools/collider run --tracy --seconds 20
tools/collider run --sanitize address
tools/collider run --vk-validation
tools/collider run --valgrind
```

Use `tools/collider run --help` for capture location, presentation mode, render
benchmark, sanitizer, optimization, and compositor-argument options.
Every run streams the complete build and session output to a UTC-timestamped
file under `logs/`; `logs/latest` is a symlink to the most recent run, including
runs that fail during build or startup.

Long-running Swift toolchain and Android SDK compiler recipes remain shell-based
internals because they directly adapt upstream build systems. The top-level Swift
workflow stages, verifies, and atomically activates them under the user cache; it
does not install into `/opt` or require `sudo`.

All first-party SwiftPM dependencies use monorepo-relative paths. No sibling-repository
detection or local dependency override step is required.

The top-level CLI is the sole orchestration entry point; individual SwiftPM packages remain
directly buildable with `swift build --package-path …`.

See each component's README for focused build, rebuild, and test instructions.

## License

Copyright (C) 2026 Noesis Reality LLC. Licensed under the GNU General Public
License, version 3. See [`LICENSE`](LICENSE).
