# Nucleus

Nucleus is a Swift 6.4 platform for native applications and operating-system UI rendered with Skia Graphite over Vulkan.

## Architecture

All first-party runtime code belongs to the single SwiftPM package rooted at `Package.swift`:

- `core/` owns the portable render and UI core plus the Android application host.
- `react-native/` owns the React Native platform, Hermes, Fabric, and native RN stack.
- `compositor/compositor-core/` and `compositor/compositor/` own the Linux Wayland/DRM render server and executable.
- `shell/` owns the out-of-process native Swift desktop shell.
- `config/`, `session/`, and `platform-linux/` own shared runtime services and platform contracts.
- `swift-vulkan/`, `swift-wayland/`, and `swift-tracy/` are root-package targets, not separately selected build tiers.

The compositor links no React runtime. The shell is an ordinary Wayland client and communicates with compositor policy through typed session channels. Android is an optional session capability hosted in an LXC container; its surfaces enter the same compositor path through the Android graphics broker.

The separate `collider/` package provides the checkout build, test, install, and run tool. Its `collider/engine/` package owns the reusable execution kernel. Collider consumes the runtime package only through `NucleusSessionProtocol` and `NucleusAndroidRuntimeCore`.

Every Swift target enables C++ interoperability. Swift/C++ seams carry opaque handles and scalars, and throwing C++ entry points are contained behind `noexcept` bridges.

## Toolchains and native SDKs

macOS development uses the selected Xcode toolchain. Linux/arm64 work in Apple containers uses the official Swift Linux/arm64 toolchain. The workspace does not build Swift, LLVM, or Linux host compilers.

Collider cross-builds only the Nucleus Linux/amd64 runtime and its Swift SDK overlays, and builds the Android Swift SDK artifact required by the Android host. Native C++ artifacts are provisioned under `~/.cache/nucleus/nucleus-native-sdk`, split into `render` and `rn` ownership.

## Setup and verification

Clone with submodules, then provision the checkout once:

```sh
git clone --recurse-submodules git@github.com:nucleus-os/nucleus.git
cd nucleus
./collider-setup.sh
```

Thereafter run Collider from any directory inside the clone:

```sh
collider doctor
collider bootstrap
collider build
collider test
```

Focused workflows include:

```sh
collider bootstrap core
collider bootstrap rn
collider android build
collider android-runtime image
collider install session
```

`collider run` builds, installs, and starts the complete DRM-owning session. Run it only from a free virtual terminal or display-manager session; it is not a nested desktop application.

Architecture and active execution plans are indexed in [docs/README.md](docs/README.md).

## License

Copyright (C) 2026 Noesis Reality LLC. Licensed under GPL-3.0; see [LICENSE](LICENSE).
