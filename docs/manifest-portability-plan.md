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

Exact compiler, `--swift-sdk`, `--triple`, native SDK, and scratch selection is
implemented. Native location and Linux system-library discovery are no longer
manifest concerns. The remaining work is isolated manifest qualification and
fresh-clone qualification.

## Phase 1 — Make the declaration graph unconditional

Status: complete.

Declare the Android product, Android targets, and pinned swift-java dependency
unconditionally. Express target applicability with PackageDescription platform
conditions and product selection. Delete manifest branches driven by
`NUCLEUS_TARGET_PLATFORM` and every environment-selected product, dependency,
or target array.

Apply Swift 6 language mode, strict memory safety, warnings as errors, and C++
interoperability uniformly to first-party Swift targets. Retain target-specific
defines, library names, and platform conditions at their semantic owners.

The declaration graph was already unconditional when this phase began. The
manifest now applies its shared Swift, C, and C++ compilation contract once and
declares Swift 6 at package scope. A normalized manifest comparison preserved all
44 products, 4 package dependencies, 232 targets, target dependencies, paths,
conditions, and target-specific settings exactly. Subsequent Phase 2 work
removed the native-path environment access entirely.

Gate: complete. Product selection continues to build only the selected target
closure from the single normalized graph.

## Phase 2 — Move native location out of target flags

Status: complete.

Keep repository-owned shims, headers, and module maps in repository-relative C
and C++ targets. Make the selected Swift SDK expose stable target headers,
libraries, module maps, and pkg-config roots. Root targets declare library names
and ordering semantics without interpolating SDK roots or absolute archive
filenames.

Pass SwiftPM-generated module-map and `*-Swift.h` search paths as
invocation-derived compiler arguments tied to the selected scratch directory.
Do not place build-derived headers in a target SDK or checked-in source.

Collider now owns the compiler executable, Swift SDK artifact, target triple,
native SDK include and library roots, generated module-map directory, and
content-addressed SwiftPM scratch directory for each destination. The root
manifest contains only repository-relative paths, semantic library names, and
link-order requirements. Android Gradle consumes the native library,
`libSwiftJava.so`, generated Java sources, NDK, and libc++ runtime as explicit
typed build artifacts; it no longer locates Collider output or recursively
invokes Collider.

The required `JExtractSwiftPlugin` closure remains in the `swift-java` fork, but
its generator support no longer introduces a network-resolved collection
dependency. Build-tool execution is therefore checkout-owned and compatible
with Collider's network-free SwiftPM actions.

Gate: complete. Core and RN linked for Linux/arm64 and Linux/x86_64 from isolated
scratch directories. Compositor and shell resolved through the same valid
dual-architecture graph without additional SwiftPM work. The Android/arm64 JNI
library, generated Swift and Java bridge, APK, and AAR built and passed Gradle
verification using the selected SDK and typed artifact inputs.

## Phase 3 — Make system libraries declarative

Status: complete.

Use checked-in system-library module maps and `pkgConfig` declarations for Linux
ABI dependencies supplied by the selected target SDK. Aggregate related ABI
dependencies behind semantic Nucleus pkg-config files instead of repeating raw
link flags at executable and test targets. The selected SDK owns those checked-in
aggregate files, distribution pkg-config metadata, headers, and libraries.

Keep Nucleus-built Wayland and bundled Skia/React Native archives on their
explicit native-SDK search paths. Their link groups encode static archive order;
they are not distribution package discovery. Likewise, libc, libm, libdl,
libpthread, and Android NDK libraries are target-toolchain primitives rather
than pkg-config packages.

The manifest process helper and active-toolchain library lookup are deleted.
SwiftPM may invoke pkg-config while planning a selected destination, but
manifest evaluation itself launches no process.

Gate: manifest evaluation performs no process launch, both Linux destinations
resolve the complete declared pkg-config closure inside their selected SDK, and
emitted link commands resolve every ABI dependency from the declared
destination.

The root manifest now declares the Linux ABI surface through SwiftPM system
library targets. Checked-in aggregate pkg-config files group the DRM, input,
XCB, and render dependencies, while their distribution metadata, headers, and
libraries are assembled into each target SDK. Collider sets
`PKG_CONFIG_LIBDIR` and `PKG_CONFIG_SYSROOT_DIR` exclusively from the selected
SDK and no longer exposes container-host include or library directories.

The obsolete manifest process helper, module-map link directives, repeated raw
ABI linker flags, and active-toolchain rpath behavior are gone. Direct
pkg-config queries for both Linux architectures resolve exclusively against the
selected SDK. The compositor and shell link successfully for Linux/arm64 and
Linux/x86_64 with this boundary, and target-SDK validation passes for both Linux
and Android architectures.

## Phase 4 — Delete manifest environment access

The Foundation import, `#filePath` repository-root derivation, `ProcessInfo`
access, Nucleus-variable guard, HOME lookup, and derived absolute paths are
already gone. Remove any corresponding manifest-only exports that remain in
`tools/host-env.sh` or Collider child environments.

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
