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

The compositor links no React runtime. The shell is an ordinary Wayland client and communicates with compositor policy through typed session channels. Android is a separately signed, architecture-specific downloadable add-on hosted in an LXC container. The base Nucleus OS contains only the compatibility declaration and generic session-capability machinery; installing the add-on contributes the Android executables, images, policy, tools, and capability declaration. Its surfaces enter the same compositor path through the Android graphics broker.

The separate `collider/` package provides the checkout build, test, install, and run tool. Its `collider/engine/` package owns the reusable execution kernel. Collider consumes the runtime package only through `NucleusSessionProtocol` and `NucleusAndroidRuntimeCore`.

Every Swift target enables C++ interoperability. Swift/C++ seams carry opaque handles and scalars, and throwing C++ entry points are contained behind `noexcept` bridges.

## Toolchains and native SDKs

macOS development, Collider, and macOS-side Swift SDK assembly use the selected
Xcode 27 compiler and developer tools. A native Linux/arm64 Apple container
uses the matching official Swift.org Linux compiler as a bootstrap compiler.
Nucleus does not build the Swift compiler, Swift driver, LLVM, Clang, SwiftPM,
SourceKit-LSP, DocC, or another host toolchain.

`collider swift-sdk rebuild` builds only the Linux target-side Swift standard
library and overlays, Dispatch, Foundation, XCTest, and Swift Testing. It builds
those products natively for Linux/arm64 and cross-builds them for Linux/amd64 in
the same arm64 container, then publishes both architectures in one Swift SDK.
Collider also installs the matching official Android Swift SDK artifact. Native
C++ artifacts are provisioned under
`~/.cache/nucleus/nucleus-native-sdk`, split into `render` and `rn` ownership.

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

On Nucleus OS, the installed product CLI manages a downloaded Android add-on without
a source checkout or Collider:

```sh
sudo nucleus addon install <artifact-directory>
nucleus addon status
```

`collider run` builds, installs, and starts the complete DRM-owning session. Run it only from a free virtual terminal or display-manager session; it is not a nested desktop application.

Architecture and active execution plans are indexed in [docs/README.md](docs/README.md).

## License

Copyright (C) 2026 Noesis Reality LLC. Licensed under GPL-3.0; see [LICENSE](LICENSE).
