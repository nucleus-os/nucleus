# Swift Target SDK Workspace Plan

Status: active.

## Invariant

The M2 Ultra owns the complete build graph. Host execution is native arm64.
The selected Xcode 27 supplies the macOS host compiler, SDK, and developer
tools. A native Linux/arm64 Apple container supplies the checksum-pinned
official Linux bootstrap compiler.
Rosetta, QEMU, an amd64 VM, and an amd64 build machine are absent.

Nucleus never builds a Swift compiler, Swift driver, LLVM, Clang, LLDB,
SourceKit-LSP, DocC, SwiftPM, or another host toolchain. The native Linux/arm64
container builds only the Linux target-side Swift standard library and
overlays, Dispatch, Foundation, Swift Testing, and XCTest natively
for Linux/arm64 and by cross-compilation for Linux/amd64. Those products contain Nucleus APIs and therefore come from the
pinned target-runtime source closure rather than an official Linux runtime
tarball.

Every Linux and Android target uses libc++. No target sysroot or published SDK
contains a libstdc++ library, module map, header facade, dynamic dependency, or
`GLIBCXX` symbol requirement. Pure C and Swift ELF artifacts need not acquire a
spurious C++ dependency; every artifact that links a C++ runtime links libc++.

Collider assembles immutable SDK generations for Linux arm64, Linux amd64,
Android arm64, and Android amd64 on macOS. No target executable runs on the Mac.

## Architecture

The checked-in external-input manifest pins only artifacts outside git:

- the signed Swift.org macOS host package;
- the official Android artifact bundle;
- exact Ubuntu arm64 and amd64 package closures for glibc, libc++, Foundation
  native dependencies, headers, and the ELF interpreters.

Root gitlinks are the sole authority for every Swift source revision, including
`swift-sdk-generator`.

The Linux target pipeline is strictly ordered:

1. Collider downloads and verifies the pinned external inputs.
2. `prepare-linux-sysroot.sh` extracts only Ubuntu packages into a fresh
   package-only sysroot and rejects every libstdc++-shaped path.
3. Collider prepares the digest-addressed native Linux/arm64 runtime-builder
   image with the official Swift.org bootstrap compiler.
4. The builder mounts source read-only, builds the Linux/arm64 standard library,
   overlays, Dispatch, Foundation, and XCTest natively, and cross-builds the
   same products for Linux/amd64 into independent external install roots. It
   skips compiler, driver, LLVM, and host-tool builds.
5. The builder invokes Swift Testing's CMake build explicitly for each target
   after Foundation. The SDK build fails if `Testing.swiftmodule` or
   `libTesting.so` is absent; upstream build-script's Linux cross-product no-op
   is not accepted as success.
6. The macOS `swift-sdk-generator` consumes those install roots as the sole
   target-Swift packages. It never mixes in an official Linux runtime tarball.
7. Collider overlays each runtime into its architecture-matched package
   sysroot, combines both entries into one Linux SDK, installs the official
   Android bundle, and builds one behavioral consumer per target triple.
8. Structural validation rejects libstdc++, requires libc++ on every consumer,
   verifies ELF architecture and interpreter, and verifies Android 16 KiB load
   alignment.
9. Collider atomically publishes the immutable generation and discovery links.

## Source and Cache Identity

The pinned source closure is `libxml2`, `llvm-project`, `swift`, `swift-collections`,
`swift-corelibs-foundation`, `swift-corelibs-libdispatch`,
`swift-corelibs-xctest`, `swift-experimental-string-processing`,
`swift-foundation`, `swift-foundation-icu`, `swift-testing`, and
`swift-sdk-generator`. Collider refuses dirty or mismatched source before task
construction. This check enforces the root gitlinks; it does not compare them
with a second revision manifest. Those exact gitlinks, the runtime preset,
builder context, external-input manifest, sysroot preparer, Xcode identity,
NDK identity,
validation fixture, and validator select the immutable generation. Unrelated
Swift compiler-tooling and platform repositories are not source-identity
inputs.

`llvm-project` supplies the CMake source tree that upstream `build-script`
requires while configuring a cross-compilation host. The runtime pipeline sets
`--skip-build-llvm` and consumes LLVM/Clang from the builder image, so LLVM is
configured for upstream build-system dependency resolution but is not built or
installed into the SDK.

Runtime Ninja products and ccache live outside source submodules. Each
architecture has an independent content-addressed runtime task, so a target
whose inputs did not change skips the entire task. When an identity changes,
the architecture-specific external build root and ccache preserve valid
upstream incremental work; that runtime install root is recreated before
publication so stale files cannot survive.

Downloads, sysroot preparation, builder-image preparation, generator build,
runtime build, assembly, validation, activation, and discovery are separate
tasks. Their declared inputs determine reuse. There is no legacy build-root
lookup, migration reader, dual pipeline, or cache fallback.

## Phase 1 — Establish the libc++ Target Boundary

The Nucleus Swift fork removes Linux from the libstdc++ platform set and passes
`-stdlib=libc++` to the Linux C++ overlay. The upstream libstdc++ module-map
implementation remains available for its non-Linux platforms but is inactive
in the Nucleus target graph, so no libstdc++ facade is installed. Runtime,
Dispatch, and Foundation C++ compilation receive explicit libc++ flags.

The SDK generator writes libc++ flags into the Linux Swift and C++ tool
properties. Its Swift tool properties include `-lc++`, so ordinary SwiftPM
products retain the target C++ runtime dependency even when their immediate
source file does not import C++.

Phase gate:

1. The Nucleus Swift runtime graph completes for Linux/aarch64 and Linux/x86_64.
2. Every installed ELF file is free of libstdc++ and `GLIBCXX` requirements.
3. C++-using runtime artifacts require `libc++.so.1`.
4. Generator tests assert the exact libc++ tool properties.

## Phase 2 — Make the Runtime Build Native-arm64 Hosted

The runtime-builder image is Linux/arm64 and contains the exact official
Swift.org Linux/arm64 snapshot. Its wrapper translates CMake's unsupported
Swift linker spelling to the official driver's `-use-ld=lld` spelling and
supplies the just-built architecture-matched `swiftrt.o` when a package-only sysroot has no
bootstrap Swift overlay.

The preset accepts a typed Linux target descriptor and declares its package sysroot, build resource
directory, module cache, lld, libc++, and only the required runtime products.
Source is read-only; build, compiler cache, and install roots are explicit
writable mounts. Network access and Linux capabilities are disabled.

Phase gate:

1. Apple `container` executes only arm64 Linux processes.
2. Runtime outputs are architecture-matched ELF for arm64 and x86_64.
3. Foundation resolves XML and compression libraries from the matching sysroot.
4. A repeated unchanged build reports no work for either stable runtime.

## Phase 3 — Assemble Without a Prebuilt Linux Runtime

Remove the Linux target package from the external-input manifest and download
graph. Pass the qualified runtime install root directly to
`swift-sdk-generator --target-swift-package-path`. The sysroot task depends
only on pinned Ubuntu packages.

Phase gate:

1. The task graph contains no Linux runtime download.
2. Assembly names the runtime install root as the sole target-Swift package.
3. The generated Linux SDK ships `libc++.so.1` and no libstdc++-shaped path.
4. Linux and Android consumers compile and link without target execution.

## Phase 4 — Publish and Prove Reuse

Candidate assembly remains isolated from active generations. Validation lands
before activation. Activation atomically moves the complete candidate to its
content identity and updates discovery links only after every gate passes.

Run the acceptance sequence in order:

1. Record the modified Swift and generator repositories as pinned fork commits
   and update their root gitlinks.
2. Run a fresh `collider swift-sdk rebuild`.
3. Inspect every Linux SDK ELF artifact and all four behavioral consumers.
4. Run an unchanged rebuild and prove the complete generation is reused.
5. Change one runtime source identity and prove downloads, generator inputs,
   and unrelated SDK inputs remain reusable while the runtime task rebuilds.

## Acceptance Criteria

- The M2 Ultra performs every build.
- Every host process is macOS/arm64 or Linux/arm64.
- No Swift compiler, LLVM, or Linux host toolchain is built.
- No Rosetta, QEMU, amd64 VM, or amd64 build machine is used.
- Linux/arm64 and Linux/amd64 runtime products come from the pinned Nucleus source graph.
- The package sysroot and published SDK expose libc++ exclusively.
- Linux arm64, Linux amd64, Android arm64, and Android amd64 are selected by exact triples.
- Target executables never run on the Mac.
- Published generations are immutable and failure-safe.
- Unchanged identities skip the complete generation and retain valid
  component-level incremental caches for the next changed identity.
