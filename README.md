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

The compositor links no React runtime. The shell is an ordinary Wayland client and communicates with compositor policy through typed session channels. Android is an optional architecture-specific native package hosted in an LXC container. The base Nucleus OS contains only generic session-capability machinery; installing `nucleus-android` through APT, DNF, or pacman contributes the Android executables, images, policy, tools, and capability declaration. Native package signatures authenticate that payload and Android Verified Boot authenticates its image chain. Its surfaces enter the same compositor path through the Android graphics broker.

The separate `collider/` package provides the checkout build, test, install, and run tool. Its `collider/engine/` package owns the reusable execution kernel. Collider consumes the runtime package only through `NucleusSessionProtocol` and `NucleusAndroidRuntimeCore`.

Every Swift target enables C++ interoperability. Swift/C++ seams carry opaque handles and scalars, and throwing C++ entry points are contained behind `noexcept` bridges.

## Toolchains and native SDKs

macOS development, Collider, and macOS-side Swift SDK assembly use the selected
Xcode 27 compiler and developer tools. A native Linux/arm64 Apple container
uses the matching official Swift.org Linux compiler as a bootstrap compiler.
Nucleus does not build the Swift compiler, Swift driver, LLVM, Clang, SwiftPM,
SourceKit-LSP, DocC, or another host toolchain.

`collider build swift-sdk --rebuild` builds only the Linux target-side Swift standard
library and overlays, Dispatch, Foundation, XCTest, and Swift Testing. It builds
those products natively for Linux/arm64 and cross-builds them for Linux/amd64 in
the same arm64 container, then publishes both architectures in one Swift SDK.
Collider also installs the matching official Android Swift SDK artifact. Native
C++ artifacts are provisioned under per-target roots such as
`~/.cache/nucleus/nucleus-native-sdk/linux-arm64`, split into `render`, `rn`,
and `wayland` ownership. Linux/amd64 and Android/arm64 use sibling target roots.

## Setup and verification

On the supported macOS development host, clone with submodules, then install
Collider once. Linux host setup is not implemented yet; Linux products are
built as targets through Collider's offline Apple-container execution:

```sh
git clone --recurse-submodules git@github.com:nucleus-os/nucleus.git
cd nucleus
./collider-setup.sh
```

Setup does not build workspace artifacts. Thereafter the installed `collider`
command is the only supported entrypoint. It derives the host environment and
uses SwiftPM to refresh the release executable whenever the active checkout's
Git/toolchain source fingerprint changes, so no shell environment script or
manual Collider rebuild is required. Run it from any directory inside the
clone; each command materializes its own prerequisite graph:

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
collider build android
collider build android-image
collider package linux-runtime --android-arm64 <arm64-input> --android-x86-64 <x86_64-input>
```

On Nucleus OS, install the optional Android capability through the native package
manager:

```sh
sudo apt install nucleus-android
```

`collider run` builds, installs, and starts the complete DRM-owning session. Run it only from a free virtual terminal or display-manager session; it is not a nested desktop application.

Architecture and active execution plans are indexed in [docs/README.md](docs/README.md).

## License

Copyright (C) 2026 Noesis Reality LLC. Licensed under GPL-3.0; see [LICENSE](LICENSE).
