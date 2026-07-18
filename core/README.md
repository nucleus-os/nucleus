# nucleus

The shared **render/UI core** for the Nucleus platform — React-agnostic, platform-agnostic.

This package provides the retained render tree, the layer system, the Skia Graphite renderer over Vulkan, the text layout backend, and the NucleusUI design system. It resolves no Wayland/DRM/xcb/input pkg-config and contains no compositor or React Native code. Other monorepo components consume its SwiftPM library products through relative path dependencies.

## Host tooling

```sh
# From the monorepo root
tools/nucleus bootstrap core
tools/nucleus build core
```

This component owns Skia synchronization, generation, and publication of the
native-Vulkan render SDK. Downstream components consume the stable SDK rather
than reproducing those provisioning steps.

## Products

| Product | Description |
|---|---|
| `NucleusTypes` | Shared value types — public structs, enums, constants. No dependencies. |
| `NucleusAppHostProtocols` | Host-protocol surface (imports `NucleusTypes`). |
| `NucleusLayers` | The layer system — composable layer tree, layout, transform. |
| `NucleusRenderModel` | Retained render model (tree nodes, properties, transactions). |
| `NucleusRenderHost` | Adapter layer lowering retained-model render transactions into the host commit sink. |
| `NucleusRenderer` | Platform-agnostic render core — Vulkan/Graphite scanout, presentation plan, retained-tree store, client surface/texture registration, per-output frame recording behind the `PresentationBackend` protocol. No DRM/KMS, no GBM. Cross-compiles for Android. |
| `NucleusTextCxxBridge` | Header-only C façade for the text-layout C++ bridge. |
| `NucleusTextBackend` | Skia text-layout backend — `TextLayoutService` and paragraph registry. Compiled once here, linked by downstream executables. |
| `NucleusSkiaGraphiteBridge` | Skia Graphite C++ façade — compiles against Skia headers, exposes the `nucleus::skia` API. |
| `NucleusUI` | UI framework — views, layout, controls, text system. Imports `Tracy` + the text bridge. |
| `NucleusApp` | SwiftUI-shaped App/Scene entry vocabulary. Single-import front door (`@_exported import NucleusUI`). |
| `NucleusAppHostBundle` | Host-side bundle tying shared types + host protocols to the layers/render model. |

## Native SDK

The core component owns and provisions the **render SDK** (Skia Graphite over native Vulkan):

```
~/.cache/nucleus/nucleus-native-sdk/render/
  ├── include/skia          → third-party/skia/
  ├── lib/skia-graphite/    → .skia-build/graphite/
  └── include/skia-text/    → render-cxx/skia/
```

Consuming components (compositor and React Native) read from this stable cache path; they never reach into the core source tree for generated artifacts.

### Provisioning

```sh
swift package build-skia --allow-writing-to-package-directory
```

Cross-compile the same native Vulkan Graphite stack for Android:

```sh
swift package build-skia-android --allow-writing-to-package-directory
```

## Build

```sh
# From core/ (provisions the render SDK on first evaluation)
swift build

# From a consuming component (SDK pre-provisioned by workspace bootstrap)
swift build
```

## Tests

```sh
swift test -Xswiftc -cxx-interoperability-mode=default
```

The package is C++-interop end to end. `swift build` of the libraries works with per-target cxx settings; only the synthesized test runner needs the global flag.

## Directory layout

```
swift/Sources/          Swift library targets (NucleusTypes, NucleusLayers, …)
swift/Tests/            Test targets (NucleusUITests, NucleusRendererTests, …)
render-cxx/skia/        C++ text backend (skia_text_backend.cpp, TextRegistry.cpp)
third-party/            Skia, swift-system submodules + vendored deps
swiftpm/plugins/        Command plugins (BuildSkia, BuildSkiaAndroid)
swiftpm/cmodules/       C module maps for system library targets
android/                Android platform integration
platform-android/       Android host package
tools/                  Bootstrap, profiling utilities
```

## Consuming this package

Other monorepo packages depend on the core through relative SwiftPM paths:

```swift
.package(name: "Nucleus", path: "../core")
```

They then import library products (e.g. `NucleusRenderer`, `NucleusUI`) via `.product(name: "...", package: "Nucleus")`. The compositor consumes only the render SDK; the React Native platform consumes both the render and RN SDKs.
