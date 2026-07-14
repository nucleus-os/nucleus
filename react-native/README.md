# nucleus-react-native

The **React Native platform for Nucleus** — Fabric, Hermes, JSI bound to the Nucleus render/UI core.

This is what an app or the shell targets to render React Native on Nucleus. It consumes the monorepo's `core/` package and owns the RN half of the native SDK.

## Products

| Product | Description |
|---|---|
| `NucleusReactRuntime` | The Swift RN runtime module — boots Hermes, installs Fabric, wires RN-produced layer trees to the render backend. Imports the C++ facade under C++ interop. |
| `NucleusReactRuntimeCxx` | Swift C++ interop bridge — implements Swift↔Fabric virtual overrides, device event emitter, turbo module registry, text layout manager bridge. |
| `NucleusReactRuntimeHostCxx` | The C++ host implementation — `ReactRuntimeHost`, JSI call invoker, mounting observer bridge, platform modules. Compiled as a static archive. |
| `NucleusReactNativeCxxBridge` | C-ABI bridge — compiles against Hermes JSI API + folly. Header-only façade for the Swift modules. |

## Native SDKs

This package provisions the **RN SDK** and consumes the **render SDK** from `../core`:

```
~/.cache/nucleus/nucleus-native-sdk/
├── render/            (owned by core/)
│   ├── include/skia
│   ├── lib/skia-graphite/
│   └── include/skia-text/
└── rn/               (owned by react-native/)
    ├── include/hermes
    ├── include/folly
    ├── include/boost
    ├── include/glog, glog-gen
    ├── include/react-native
    ├── include/react-bridge
    ├── include/react-runtime
    ├── lib/rn/
    └── lib/nucleus-cxx-libs/   (staged host-cxx archive)
```

### Provisioning

The RN C++ stack is built by command plugins, provisioned out of band:

```sh
# 1. Build Hermes (lean VM + hermesc)
swift package build-hermes --allow-writing-to-package-directory

# 2. Build support libs (fmt, double-conversion)
swift package build-rn-support --allow-writing-to-package-directory

# 3. Build RN C++ layer (glog, folly_runtime, jsi)
swift package build-rn-cxx --allow-writing-to-package-directory

# 4. Regenerate RN codegen (once per RN version bump)
swift package generate-rn-spec --allow-writing-to-package-directory

# 5. Stage host-cxx archives for downstream linking
swift package provision-cxx-libs --allow-writing-to-package-directory
```

### Third-party dependencies

Everything under `third-party/` is a pinned git submodule except `boost` (1.83.0), which is vendored as header-only and fetched by bootstrap.

```
third-party/react-native/   RN 0.87 (ReactCommon, Fabric, Yoga, Hermes adapter)
third-party/hermes/         Hermes JS engine + hermesc compiler
third-party/folly/          Folly (meta), folly_runtime (built)
third-party/glog/           Google glog
third-party/fmt/            fmt (CMake)
third-party/double-conversion/
third-party/fast_float/     (header-only)
third-party/boost/          (vendored, header-only)
```

## Build

```sh
# From the monorepo root
tools/nucleus bootstrap rn

# Rebuild
source ../core/tools/host-env.sh
swift build
```

The root workspace CLI provisions both native SDKs, fetches boost, runs RN codegen into
`.rn-build/generated`, builds the native C++ stack, then builds the Swift package. It invokes
component-local tooling as an implementation detail. The vendored React Native checkout
remains clean, and fingerprinted stages are safe to re-run.

## Tests

```sh
swift test -Xswiftc -cxx-interoperability-mode=default
```

Notable test targets:
- `NucleusReactNativeCxxTests` — Links the full Hermes/folly native stack and runs a JSI round-trip.
- `NucleusReactRuntimeFabricTests` — Drives the full RN fabric headless (single-threaded): Hermes runtime + Fabric install + bytecode eval. Links the same fabric set as downstream executables.

## Directory layout

```
swift/Sources/          Swift library targets (NucleusReactRuntime, NucleusReactRuntimeCxx)
swift/Tests/            Test targets (FabricTests, CxxTests)
third-party/            RN native stack submodules + vendored deps
swiftpm/plugins/        Command plugins (BuildHermes, BuildRNSupportLibs, BuildReactNativeCxx, …)
swiftpm/cmodules/       C module maps (NucleusReactRuntimeCxxBridge, NucleusReactFabricSmokeC)
swiftpm/shims/          Swift→C++ header shim for the host C++ target
tools/                  Bootstrap script
.rn-build/              Staged RN C++ build artifacts (Hermes, folly, glog, fmt)
.cxx-build/             Staged host-cxx archives for downstream linking
```

## Consuming this package

Monorepo apps depend on both packages by relative path:

```swift
.package(name: "NucleusReactNative", path: "../react-native")
.package(name: "Nucleus", path: "../core")
```

Import products via `.product(name: "NucleusReactRuntime", package: "NucleusReactNative")` and the core products via `package: "Nucleus"`. The RN runtime is statically linked into the final executable.
