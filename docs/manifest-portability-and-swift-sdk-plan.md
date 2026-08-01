# Manifest Portability and Swift SDK Plan

Status: active.

## Invariant

The root [`Package.swift`](../Package.swift) evaluates on a bare clone with a
stock Swift 6.4 toolchain and an empty environment. Manifest evaluation reads no
environment variables, spawns no processes, and names no absolute host paths.
Host and target configuration reaches the compiler through Swift SDK artifact
bundles at build-invocation time, never through manifest-time string
interpolation.

Both compilation targets — Linux host and Android — are Swift SDKs. There is no
host special case.

## Why the Current Manifest Is Not Portable

The root manifest is a serialized host configuration expressed in Swift. It
carries 3,584 lines across 216 targets, of which:

- A `guard` over five environment variables terminates evaluation with
  `fatalError("source tools/host-env.sh before invoking SwiftPM")`
  ([`Package.swift:11`](../Package.swift)).
- 326 interpolations thread environment-derived absolute paths into
  `unsafeFlags`, dominated by roughly 300 `nativeSDKRoot + "/render/include/..."`
  Skia and Vulkan include and link paths.
- A `pkg-config` subprocess resolves the icu library directory during manifest
  evaluation, with `try!` and `fatalError` on failure
  ([`Package.swift:20`](../Package.swift)).
- The Swift runtime search path is interpolated as `swiftToolchain + "/lib"`
  ([`Package.swift:317`](../Package.swift)).
- `NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH` supplies a module-map directory
  that Collider itself generates
  ([`SwiftBuildContext.swift:210`](../collider/engine/Sources/ColliderCore/SwiftBuildContext.swift)).

The last item states the defect precisely: the manifest consumes artifacts
produced by the tool whose own build requires that manifest to evaluate. The
`collider` package declares `.package(name: "Nucleus", path: "..")`
([`collider/Package.swift:13`](../collider/Package.swift)), so resolving the
Collider graph evaluates the root manifest. Verified directly:

```sh
swift package --package-path collider show-dependencies --manifest-cache none
```

with the guarded variables unset terminates at
`main/Package.swift:17: Fatal error: source tools/host-env.sh before invoking SwiftPM`.

This defeats the documented fresh-clone path. When no toolchain is present,
`toolchain_present` in [`collider-setup.sh`](../collider-setup.sh) fails at
[`host-env.sh:66`](../tools/host-env.sh), so the bootstrap branch runs
`swift build --package-path collider -c release` without sourcing `host-env.sh`.
That build evaluates the root manifest, which terminates before Collider can
reach `collider toolchain rebuild`.

Every remaining symptom follows from the same property: the launcher pays for
manifest evaluation on every invocation, the Collider engine exists as a
separate package solely to obtain a toolchain-independent floor, and the
manifest is too large and too coupled for prose in [`AGENTS.md`](../AGENTS.md)
to be checked against it.

## The Mechanism Already Exists

`SwiftBuildTarget` already models Swift SDKs and applies them to Android
([`SwiftBuildContext.swift:13`](../collider/engine/Sources/ColliderCore/SwiftBuildContext.swift)):

```swift
case host(identity: String)
case triple(String)
case swiftSDK(name: String, targetTriple: String)
```

The Android lane emits `--swift-sdk swift-release-6.4.x_android`, and
[`ComponentRegistry.swift:482`](../collider/Sources/ColliderCommands/ComponentRegistry.swift)
and [`Toolchain.swift:243`](../collider/Sources/ColliderCommands/Toolchain.swift)
already assemble and install artifact bundles into `.swiftpm/swift-sdks`. This
plan generalizes that machinery to the host lane and deletes the environment
side channel that the host lane uses instead.

## The Non-Cxx Contract Tier Is Real

[`AGENTS.md`](../AGENTS.md) states that every Swift target sets
`.interoperabilityMode(.Cxx)` and that no non-cxx tier exists. The manifest
declares 196 targets with Cxx interop and 16 without:

`NucleusConfig`, `NucleusIPCTransport`, `NucleusSessionProtocol`,
`NucleusAndroidContainerContract`, `NucleusAndroidRuntimeCore`,
`NucleusAndroidRuntimeBridgeProtocol`, `NucleusAndroidRuntimeBrokerCore`,
`NucleusAndroidRuntimeHostLinux`, the `NucleusAndroidRuntime` and
`NucleusAndroidRuntimePrivileged` executables, and their six test targets.

That set is not an oversight. It is the closure of the pure-Swift contract
modules that orchestration and the Android runtime consume without pulling in
Skia or C++ interop, and it is exactly what makes the Collider edge into the
root package cheap. This plan names it the contract tier, declares it
explicitly, and holds it as an invariant rather than an accident.

## Phase 1 — Collapse Repeated Target Settings

The manifest repeats `.strictMemorySafety()`, `-warnings-as-errors`, and
`-Werror StrictLanguageFeatures` across 212 targets, and
`.interoperabilityMode(.Cxx)` across 196. The root manifest has no
`for target in package.targets` loop; [`collider/Package.swift:126`](../collider/Package.swift)
already applies settings this way and is the pattern to adopt.

The root manifest gains a post-hoc settings loop that applies the repository
compilation contract to every regular, executable, and test target, and applies
`-Werror` to every C and C++ target. Cxx interop is applied by default. The
contract tier named above is declared as an explicit set in the manifest and
excluded from Cxx interop by that loop, so membership is a single readable
declaration rather than 196 present and 16 absent settings blocks.

Genuine per-target flags — Skia include paths, linker groups, Android
conditions — remain on their targets untouched. This phase removes repetition
only; it changes no compiler input. That is the verification: the built product
set and every task fingerprint are unchanged.

The manifest shrinks substantially, which is what makes the interpolation
removal in Phases 2 and 3 reviewable.

## Phase 2 — The Native Stack Becomes a Swift SDK Bundle

`~/.cache/nucleus/nucleus-native-sdk`, split into `render` and `rn`, already
holds precisely what a Swift SDK artifact bundle carries: sysroot, header search
paths, library search paths, and extra `swiftc` and `clang` flags.

Bootstrap stops populating a loose directory that the manifest reads by absolute
path. It assembles a host artifact bundle and installs it into
`.swiftpm/swift-sdks` alongside the Android bundle, using the installation path
that [`Toolchain.swift:243`](../collider/Sources/ColliderCommands/Toolchain.swift)
already owns. The generated module maps move into that bundle.

The roughly 300 Skia and Vulkan include and link interpolations leave the
manifest as part of this phase. `SwiftBuildTarget.host` is deleted and every
lane resolves to `.swiftSDK`. `commandEnvironment` loses
`NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH` and `NUCLEUS_TARGET_PLATFORM`,
because the bundle's `swift-sdk.json` carries both; the Android branch at
[`SwiftBuildContext.swift:216`](../collider/engine/Sources/ColliderCore/SwiftBuildContext.swift)
is deleted with it.

Verification is a full host build and test run driven through the bundle,
compared against the pre-phase artifact fingerprints.

## Phase 3 — System Libraries Become Declarative and the Guard Is Deleted

The icu dependency becomes a `.systemLibrary` target with `pkgConfig:`, which
SwiftPM resolves itself. This removes the last process spawn from manifest
evaluation. The Swift runtime search path comes from the bundle's runtime paths
rather than an interpolated toolchain string, removing the
`swiftToolchain + "/lib"` rpath.

With no remaining consumers, the five-variable `guard` and its `fatalError` are
deleted, along with the `repoRoot` derivation from `#filePath` and the absolute
paths built from it. Target paths become repository-relative.

The verification gate for this phase is the invariant itself, run in an empty
environment on a clean checkout:

```sh
env -i PATH=/usr/bin:/bin swift package dump-package --manifest-cache none
```

## Phase 4 — The Package Graph Settles at Two Packages

`collider/engine` merges into `collider` as targets. `ColliderCore`,
`ColliderRuntime`, `ColliderDownloads`, and `ColliderPlatformC` remain a library
layer beneath `ColliderCommands`, which is a target boundary and never required
a package boundary. The engine exists as a separate package only to provide a
toolchain-independent floor, and Phase 3 makes the entire repository that floor.

The repository settles at two packages:

- `nucleus` at the root, owning every first-party runtime, library, executable,
  benchmark, generator, sanitizer harness, and test target.
- `collider`, owning orchestration, the task engine, and the component recipes.

Collider depends on the root package. The root package has no reference to
Collider. Two packages rather than one, for two reasons that survive the
cleanup: SwiftPM makes "the runtime graph never depends on orchestration" a
resolution error rather than a review rule, and `swift build --package-path
collider` stays a fast, SDK-free build, which is what the installed launcher
runs on every invocation.

The `.package(name: "Nucleus", path: "..")` edge stays exactly as declared.
`NucleusSessionProtocol` and `NucleusAndroidRuntimeCore` do not move. The
fresh-clone bootstrap defect is resolved by Phase 3 rather than by relocating
contracts.

## Phase 5 — Bootstrap and Documentation Close

Bootstrap becomes linear, with no step depending on a later step's output:

```sh
swift build --package-path collider -c release
collider toolchain rebuild
collider bootstrap
collider build
```

The `toolchain_present` fork in [`collider-setup.sh`](../collider-setup.sh) is
deleted. It exists only because the first step currently requires the second
step's output.

[`tools/host-env.sh`](../tools/host-env.sh) stops being a contract. Its absence
is currently fatal for every SwiftPM invocation; afterward it is optional
convenience for running raw `swift` commands by hand, and Collider passes
toolchain and SDK selection as arguments.

[`AGENTS.md`](../AGENTS.md) is corrected as part of this phase. Its build-system
section currently describes four first-party package manifests — `core/`,
`react-native/`, `compositor/compositor-core`, and `shell/` — that do not exist,
states that the repository root is not a Swift package, and names the
`core/.skia-build`, `react-native/.rn-build`, and `react-native/.cxx-build`
output directories, none of which exist. It also asserts that no non-cxx tier
exists. The corrected section states the two-package graph, the contract tier,
the Swift SDK build contract, and `collider build` as the verification command.

## Out of Scope

The `@_spi(NucleusCompositor)` seam, the C++ bridge patterns including
`extern "C"` guards and `noexcept` entry points, the placement of component
recipe modules under `collider/Sources`, and the AOSP Repo-manifest exception to
submodule ownership are all load-bearing and correct. This plan changes only how
host and target configuration reaches the compiler.

Generating the root manifest from the component recipes is rejected. It breaks
editor and language-server integration and contradicts the standing position
that stock SwiftPM owns one first-party package graph. The manifest remains
hand-maintained; Phase 1 is what makes that sustainable.
