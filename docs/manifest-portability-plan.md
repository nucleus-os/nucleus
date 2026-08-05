# Manifest portability plan

Status: active.

## Invariant

The root `Package.swift` evaluates from a bare clone with stock Swift 6.4 and no
Nucleus environment. Manifest evaluation reads no environment variables, runs
no process, and embeds no absolute host path. It describes one
destination-independent package graph and the semantic native libraries each
target consumes.

Collider selects every runtime destination with an explicit Swift SDK directory,
artifact ID, target triple, scratch path, and compiler configuration. Swift SDKs
own target sysroots and stable native search roots. SwiftPM owns package topology
and generated build headers. No configuration value crosses those ownership
boundaries through manifest-time environment lookup.

Exact `--swift-sdk` and `--triple` selection is implemented. The remaining work
is the root manifest and its bootstrap dependency cycle.

## Phase 1 — Make the declaration graph unconditional

Declare the Android product, Android targets, and pinned swift-java dependency
unconditionally. Express target applicability with PackageDescription platform
conditions and product selection. Delete manifest branches driven by
`NUCLEUS_TARGET_PLATFORM` and every environment-selected product, dependency,
or target array.

Apply Swift 6 language mode, strict memory safety, warnings as errors, and C++
interoperability uniformly to first-party Swift targets. Retain target-specific
defines, library names, and platform conditions at their semantic owners.

Gate: isolated manifest dumps for macOS, Linux, and Android expose one normalized
product/target graph, while selecting a product builds only its target closure.

## Phase 2 — Move native location out of target flags

Keep repository-owned shims, headers, and module maps in repository-relative C
and C++ targets. Make the selected Swift SDK expose stable target headers,
libraries, module maps, and pkg-config roots. Root targets declare library names
and ordering semantics without interpolating SDK roots or absolute archive
filenames.

Pass SwiftPM-generated module-map and `*-Swift.h` search paths as
invocation-derived compiler arguments tied to the selected scratch directory.
Do not place build-derived headers in a target SDK or checked-in source.

Gate: core, RN, compositor, shell, and Android products build independently from
clean scratch directories using only repository-relative manifest paths and the
selected SDK configuration.

## Phase 3 — Make system libraries declarative

Use checked-in system-library module maps and `pkgConfig` declarations for ICU
and every other system dependency. The selected SDK supplies pkg-config and
library search roots. Delete the manifest's pkg-config subprocess and active
toolchain rpath injection.

Gate: package planning performs no process launch, and emitted link commands
resolve every system library from the declared destination.

## Phase 4 — Delete manifest environment access

Delete the Foundation import, `#filePath` repository-root derivation,
`ProcessInfo` access, the Nucleus-variable guard, HOME lookup, and every derived
absolute path. Remove corresponding manifest-only exports from
`tools/host-env.sh` and Collider child environments.

Gate: `swift package dump-package` for the root and `swift package
show-dependencies` for Collider pass with an isolated HOME and only the selected
Swift binary on PATH.

## Phase 5 — Linearize fresh-clone bootstrap

Build Collider natively with Xcode, publish the Swift target SDK generation,
bootstrap native SDK artifacts, then build and test the runtime graph. Collider
and `collider/engine` remain separate tooling packages; neither depends on
manifest-time provisioned runtime artifacts.

Gate: `./collider-setup.sh`, `collider doctor`, `collider bootstrap`, `collider
build`, and `collider test` pass from a recursive fresh clone and from an
unchanged incremental checkout.

## Phase 6 — Qualify every destination

Build and test Linux/arm64 and Linux/x86_64, compile and link Android/arm64 and
Android/x86_64, run generated Swift-to-C++ bridge tests from clean scratch, and
validate artifact provenance, relocation, exported symbols, and libc++ closure.

Gate: every runtime compilation consumes only its declared immutable SDK and no
supported workflow requires `source tools/host-env.sh` before SwiftPM planning.
