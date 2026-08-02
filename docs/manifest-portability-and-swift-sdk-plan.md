# Manifest Portability and Swift SDK Plan

Status: active.

## Invariant

The root [`Package.swift`](../Package.swift) evaluates on a bare clone with a
stock Swift 6.4 toolchain and no Nucleus environment. Manifest evaluation reads
no environment variables, spawns no processes, and embeds no absolute host
paths. The manifest describes repository topology and target-specific build
semantics only.

Every Nucleus runtime product compiles through an explicitly selected Swift SDK
and target triple. The supported runtime destinations are Linux amd64, Android
arm64, and Android amd64. Collider itself remains a native host tool: Xcode 27
builds and runs it on macOS. The pure-Swift contract tier may compile natively
when Collider consumes it. There is no generated Linux host toolchain and no
implicit host destination for a Nucleus runtime build.

Configuration has exactly three owners:

- A Swift SDK owns a target sysroot, Swift runtime resources, stable native
  headers and libraries, compiler and linker tool configuration, and SDK-local
  `pkg-config` search roots.
- `Package.swift` owns products, targets, dependencies, checked-in module maps
  and shims, platform conditions, target-specific defines, library names, and
  linker grouping semantics.
- Collider owns invocation-derived state: SDK identity and search path, target
  triple, scratch path, generated-header path, configuration, sanitizer,
  diagnostics, compiler identity, and task identity.

No value crosses those boundaries through manifest-time environment lookup.

## Current State

The root manifest is a serialized host configuration expressed in Swift. It is
3,584 lines and declares 230 targets: 216 regular, executable, or test targets
and 14 system-library targets. The current host-evaluated graph contains 227
targets because three Android declarations are admitted only when an environment
branch selects Android.

The concrete portability defects are:

- A guard over `NUCLEUS_NATIVE_SDK_ROOT`,
  `NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH`, `SWIFT_TOOLCHAIN`,
  `NUCLEUS_SWIFT_SOURCE_ID`, and `HOME` terminates manifest evaluation with
  `fatalError("source tools/host-env.sh before invoking SwiftPM")`.
- `NUCLEUS_TARGET_PLATFORM` changes the package's products, dependencies, and
  targets. `NUCLEUS_SWIFT_SDKS_PATH` and `NUCLEUS_SWIFT_SOURCE_ID` construct an
  Android runtime-library search path inside the manifest.
- 326 interpolations thread environment-derived absolute paths through
  `unsafeFlags`, dominated by Skia, Vulkan, Hermes, React Native, and generated
  Swift-to-C++ header paths.
- A `pkg-config` subprocess resolves the ICU library directory during manifest
  evaluation and terminates manifest loading when it fails.
- The manifest injects the active toolchain's `lib` directory as an rpath.
- The manifest consumes SwiftPM's build-derived
  `GeneratedModuleMaps-*` directory. Collider computes and exports the expected
  directory, but SwiftPM generates its module maps and `*-Swift.h` files during
  that exact build.

Collider declares `.package(name: "Nucleus", path: "..")`. Resolving Collider
therefore evaluates the root manifest before Collider can provision the
toolchain, native SDK, or generated-header directory demanded by that manifest.
This makes the documented fresh-clone bootstrap graph cyclic.

The existing Swift SDK path also has a correctness defect. `SwiftBuildTarget`
stores `.swiftSDK(name:targetTriple:)`, but `SwiftPMInvocation` emits only
`--swift-sdk`. The Android artifact contains SDK entries for both arm64 and
amd64, so selection by artifact ID is ambiguous unless the invocation also
passes `--triple`.

## The Compilation Contract

The manifest applies one strict compilation contract to every Swift target:
Swift 6.4 language mode, strict memory safety, warnings as errors, and
`.interoperabilityMode(.Cxx)`. C++ interoperability is a uniform compiler mode,
not a dependency tier. Review and target dependencies keep C++ implementation
types out of Swift domain models.

## Phase 1 — Make Swift SDK Selection Exact

`SwiftPMInvocation` emits both parts of every Swift SDK destination:

```text
--swift-sdk <artifact-id> --triple <target-triple>
```

The target triple remains part of `SwiftBuildContext.identityBytes`, product
directory naming, and task identity. Tests install a fixture artifact containing
multiple target triples and prove that arm64 and amd64 select different entries
under the same artifact ID. A request for an absent or ambiguous destination
fails during SwiftPM destination planning before compilation.

The runtime destination inventory becomes explicit:

- Linux: `x86_64-unknown-linux-gnu`.
- Android arm64: `aarch64-unknown-linux-android<api>`.
- Android amd64: `x86_64-unknown-linux-android<api>`.

This phase records the current product inventory, normalized compiler and linker
commands, exported-symbol inventories, and runtime smoke results. Those records
are behavioral comparison inputs for later phases. Task fingerprints are not a
comparison contract because changing `Package.swift` or the destination model
necessarily changes them.

### Progress — 2026-08-01

Exact SDK selection is implemented. Collider now emits `--swift-sdk` and
`--triple` together, and behavioral tests prove distinct invocation, task, and
product identities for the Android arm64 and amd64 entries in one real artifact
bundle.

The starting host graph contains 77 products and 227 targets. Its normalized
product-and-target inventory hashes to
`a4757e0881c837fa2d0e5ff54024320826efe4db64797b325956235352585977`.
The environment-selected Android graph contains 78 products and 230 targets and
hashes to
`37715ac42e8900a208a5d13aae8210b2c6c5814faa2a442f0f405e0b6537bea1`.
Normalized compiler and linker commands, exported symbols, and runtime smoke
results remain to be captured from the immutable target SDK generation.

The compiler-build experiment was removed. The qualified architecture uses
Xcode's Swift compiler for macOS execution and an official Swift.org
Linux/arm64 compiler inside a native Apple container to cross-build only the
Nucleus Linux/amd64 runtime and SDK overlays. The runtime, Dispatch, Foundation,
Swift Testing, and XCTest now complete against the package-only libc++ sysroot;
an audit of all 59 installed ELF artifacts finds no `libstdc++` dependency or
`GLIBCXX` requirement. Production generation begins after the modified Swift
and `swift-sdk-generator` submodules are recorded as pinned source revisions.

## Phase 2 — Centralize the Compilation Contract

The root manifest gains a post-construction settings loop over regular,
executable, and test targets. It applies `.strictMemorySafety()`,
`-warnings-as-errors`, `-Werror StrictLanguageFeatures`, and
`.interoperabilityMode(.Cxx)` once for every Swift target.

The same loop applies `-Werror` to C and C++ compilation. This deliberately
normalizes the five existing targets that declare C++ settings without C++
`-Werror`; it is a warning-policy correction, not an input-neutral refactor.
All repeated copies of the centralized settings leave individual target
declarations.

Target-specific settings remain local to their targets: platform conditions,
feature defines, include requirements, sanitizer behavior, library names, and
linker grouping. Verification compares the recorded product inventory and
normalized commands, then builds and tests the affected five-target warning
policy delta explicitly.

## Phase 3 — Make the Package Graph Destination-Independent

The manifest declares the Android product, Android targets, and the pinned local
`swift-java` package dependency unconditionally. Android-only dependencies and
settings use `PackageDescription` platform conditions such as
`.when(platforms: [.android])`. Selecting a product controls which target closure
builds; manifest evaluation never adds or removes declarations.

The `nucleus-os/swift-java` fork hard-wires its sibling
`../swift-java-jni-core` package dependency. The
`SWIFT_JAVA_JNI_CORE_PATH` manifest override and the corresponding export in
`tools/host-env.sh` are deleted, so dependency resolution always uses the pinned
root submodule graph.

`NUCLEUS_TARGET_PLATFORM`, `isAndroidTarget`, `hostProducts`,
`androidProducts`, `hostDependencies`, `androidDependencies`, `hostTargets`,
and `androidTargets` leave the root manifest. The package is constructed from
one product list, one dependency list, and one target list.

Verification dumps and resolves the same declaration graph when invoked for
Linux and Android. Linux product builds do not select the Android product
closure. Android arm64 and amd64 builds select the same target closure with
different SDK triples.

## Phase 4 — Assemble Complete Runtime Swift SDKs

Collider assembles immutable SDK generations instead of exposing a loose
`nucleus-native-sdk` directory to the manifest.

The Linux amd64 SDK contains:

- The exact Ubuntu amd64 package sysroot, including libc++ and excluding every
  libstdc++ file, module map, dependency, and symbol requirement.
- Dynamic and static Nucleus Swift runtime resources cross-built from the
  pinned source graph by an official Linux/arm64 Swift compiler. No compiler or
  LLVM product is built.
- The render and React Native headers and Linux/amd64 libraries cross-built by
  pinned native Linux/arm64 OCI builders.
- SDK-local module maps and `pkg-config` metadata for stable native artifacts.
- Compiler, C compiler, C++ compiler, and linker toolset configuration.

The Android SDK contains one entry for each supported Android triple and
contains:

- The pinned NDK sysroot.
- Architecture-specific dynamic and static Swift runtime resources.
- Android render artifacts and stable native headers.
- SDK-local module maps and toolset configuration.
- The 16 KiB maximum-page-size linker contract.

SDK generations live under Collider's immutable target-SDK cache.
Collider passes their containing directory with `--swift-sdks-path`; it does not
depend on a mutable user-global discovery symlink. Publication validates every
declared path, target triple, runtime directory, header root, library root, and
tool executable before switching the active generation.

Build-derived SwiftPM module maps and `*-Swift.h` headers are explicitly absent
from both SDKs.

## Phase 5 — Move Stable Native Topology Out of Absolute Flags

Repository-owned headers and module maps become ordinary SwiftPM C or C++
targets with repository-relative paths. Checked-in React Native shims remain in
the repository and depend on those targets. No checked-in source or module map
moves into a generated SDK.

SDK-owned headers and libraries reach the compiler through SDK include and
library search paths. Individual targets retain semantic linkage by library
name, required linker ordering, and `--start-group`/`--end-group` boundaries.
The SDK supplies where a library resides; the manifest continues to state which
target links it and why.

Absolute archive filenames, `nativeSDKRoot` interpolations, and absolute
repository paths leave target settings. The emitted commands may contain
absolute paths resolved by SwiftPM and Collider, but no absolute path originates
as a value embedded by `Package.swift`.

Verification builds each render and React Native product separately before the
complete product closure. This catches accidental global linkage, missing
per-target library edges, and static archive ordering regressions.

## Phase 6 — Move Build-Derived Headers to the Invocation

`SwiftPMInvocation` remains the owner of the scratch directory and derives the
matching `GeneratedModuleMaps-*` directory. It passes that directory through
the SwiftPM command line using the required `-Xcxx` and Swift Clang-importer
flags. The path becomes part of the build context identity.

`NucleusReactRuntimeHostCxx` continues to include the checked-in
`NucleusReactRuntimeCxx.h` shim, which includes SwiftPM's generated
`NucleusReactRuntimeCxx-Swift.h`. The task graph guarantees that the Swift module
emits the header before the C++ bridge consumes it. A clean-scratch build proves
that no stale generated header or editor build directory is required.

`NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH` and
`NUCLEUS_SWIFTPM_SCRATCH_PATH` leave the command environment. The generated
module-map export also leaves `tools/host-env.sh`. Any other SwiftPM environment
entry without a non-manifest consumer is deleted in the same phase.

## Phase 7 — Make System Libraries Declarative

ICU becomes a repository-owned `.systemLibrary` target with checked-in module
map metadata and `pkgConfig: "icu-uc"`. Its target dependencies and linked
library names replace the manifest-time `pkg-config` subprocess and the
interpolated ICU rpath. SDK configuration supplies the appropriate
`pkg-config` and library search roots for each destination that consumes ICU.

The generated Swift SDK supplies Swift runtime resource and library paths. The
manifest's `swiftToolchain + "/lib"` rpath leaves without replacement.

Every other system dependency follows the same rule: the manifest declares the
library relationship, the selected SDK supplies target-owned search roots, and
the host environment supplies neither.

## Phase 8 — Delete Manifest Environment and Process Access

After the preceding consumers are gone, the root manifest deletes:

- `Foundation`.
- `ProcessInfo.processInfo.environment`.
- The five-variable guard and its `fatalError`.
- The `pkgConfig` process helper.
- `repoRoot` derived from `#filePath`.
- `nativeSDKRoot`, `generatedModuleMaps`, `swiftToolchain`, `swiftSourceID`,
  `homeDirectory`, `androidSDKSearchRoot`, and every string derived from them.

Target source paths are repository-relative. Manifest evaluation requires only
`PackageDescription` and the checked-out source tree.

The behavioral gate runs with an isolated home and no Nucleus variables on both
Xcode 27 and the official Linux/arm64 Swift 6.4 toolchain:

```sh
env -i HOME="$isolated_home" PATH="$swift_bin_dir:/usr/bin:/bin" \
  "$swift_bin" package dump-package --manifest-cache none

env -i HOME="$isolated_home" PATH="$swift_bin_dir:/usr/bin:/bin" \
  "$swift_bin" package --package-path collider show-dependencies \
  --manifest-cache none
```

The second command runs after the pinned submodules are initialized and proves
the fresh-clone Collider edge, not merely the root manifest in isolation.

## Phase 9 — Route Builds and Linearize Bootstrap

Every Collider-driven Nucleus runtime invocation selects an SDK directory,
artifact ID, and target triple explicitly. `SwiftBuildTarget.host` and
`SwiftBuildTarget.triple` are deleted after their final runtime callers migrate.
The native Collider bootstrap build remains outside that model.

Bootstrap becomes a strict dependency chain:

```sh
swift build --package-path collider -c release
collider toolchain rebuild
collider bootstrap
collider build
```

The first command builds Collider with the native compiler and can evaluate the
root dependency graph without provisioned SDKs. `toolchain rebuild` publishes
the Linux/amd64 Nucleus target SDK overlay and Android Swift SDK artifact; it
does not build a compiler. `bootstrap` builds the native
render/RN artifacts and assembles the complete runtime SDKs. `build` consumes
only those published SDK generations.

The `toolchain_present` bootstrap fork is deleted. `tools/host-env.sh` stops
being a SwiftPM manifest contract and remains only an optional convenience for
interactive raw-tool invocation. Collider passes every compiler and SDK choice
as an argument.

## Phase 10 — Settle the Package Graph and Documentation

`collider/engine` merges into `collider` as targets. `ColliderCore`,
`ColliderRuntime`, `ColliderDownloads`, and `ColliderPlatformC` remain a library
layer beneath `ColliderCommands`. The repository settles at two first-party
packages:

- `nucleus` owns runtime libraries, executables, benchmarks, generators,
  sanitizer harnesses, and tests.
- `collider` owns orchestration, the task engine, and component recipes.

Collider depends on the root package. The root package has no reference to
Collider. The package boundary makes a runtime-to-orchestration dependency a
resolution error. The target boundary inside Collider preserves the engine's
independent library architecture without retaining a third package manifest.

`AGENTS.md`, `README.md`, the toolchain documentation, and the macOS builder
plan are updated to state the root-runtime plus Collider package graph, the uniform compilation contract, the runtime
Swift SDK contract, the native Collider bootstrap exception, and `collider
build` as the complete product verification entry point.

## Final Verification Gates

The migration is complete only when all of these gates pass in order:

1. Root manifest dump and Collider dependency resolution pass with an isolated
   home and no Nucleus environment on macOS and Linux.
2. Xcode 27 builds and tests Collider natively on macOS.
3. The official Linux/arm64 Swift 6.4 toolchain builds and tests Collider
   natively in the Apple container.
4. The Linux amd64 SDK builds and tests every selected Nucleus product from a
   clean scratch directory.
5. The Android arm64 and amd64 SDK entries compile and link their complete
   product closures from clean scratch directories.
6. Generated Swift-to-C++ header bridge tests pass without a prior editor or
   host build.
7. Exported-symbol inventories and runtime smoke tests match the Phase 1
   behavioral baseline, except for reviewed intentional changes.
8. SDK publication validation proves that every runtime, sysroot, header,
   library, module-map, toolset, and `pkg-config` path belongs to the published
   immutable generation.
9. `collider doctor`, `collider bootstrap`, `collider build`, and `collider test`
   pass from the documented fresh-clone sequence.

Task or artifact fingerprints are expected to change when manifest contents,
SDK identity, destination identity, or command arguments change. Cache misses
are accepted once; product behavior and declared provenance are the contracts.

## Out of Scope

The `@_spi(NucleusCompositor)` seam, the C++ bridge patterns including
`extern "C"` guards and `noexcept` entry points, component recipe placement
under `collider/Sources`, and the AOSP Repo-manifest exception to submodule
ownership remain unchanged.

The root manifest remains hand-maintained. Generating it from Collider recipes
would break editor and language-server integration and reverse the required
dependency direction. The centralized compilation contract and explicit
configuration ownership make the maintained manifest sustainable.
