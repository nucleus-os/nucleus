# Swift Target SDK Workspace Plan

Status: active.

## Invariant

The M2 Ultra owns the complete build graph. Host execution is native arm64.
The selected Xcode 27 supplies macOS SDK tooling, the checksum-pinned Swift.org
macOS 6.4 snapshot supplies the host Swift compiler, and a native Linux/arm64
Apple container supplies the checksum-pinned official Linux bootstrap compiler.
Rosetta, QEMU, an amd64 VM, and an amd64 build machine are absent.

Nucleus never builds a Swift compiler, LLVM, LLDB, SourceKit-LSP, DocC, SwiftPM,
or Linux host toolchain. The native Linux/arm64 container cross-builds only the
Nucleus Swift runtime, Dispatch, Foundation, Swift Testing, and XCTest for
Linux/amd64. Those products contain Nucleus APIs and therefore come from the
pinned sibling source graph rather than an official Linux runtime tarball.

Every Linux and Android target uses libc++. No target sysroot or published SDK
contains a libstdc++ library, module map, header facade, dynamic dependency, or
`GLIBCXX` symbol requirement. Pure C and Swift ELF artifacts need not acquire a
spurious C++ dependency; every artifact that links a C++ runtime links libc++.

Collider assembles immutable SDK generations for Linux amd64, Android arm64,
and Android amd64 on macOS. No target executable runs on the Mac. Real x86_64
and Android workers own runtime qualification.

## Architecture

The checked-in lock pins:

- the signed Swift.org macOS host package;
- the official Android artifact bundle;
- the exact Ubuntu amd64 package closure for glibc, libc++, Foundation native
  dependencies, headers, and the ELF interpreter;
- the `swift-sdk-generator` source revision.

The Linux target pipeline is strictly ordered:

1. Collider downloads and verifies the locked inputs.
2. `prepare-linux-sysroot.sh` extracts only Ubuntu packages into a fresh
   package-only sysroot and rejects every libstdc++-shaped path.
3. Collider prepares the digest-addressed native Linux/arm64 runtime-builder
   image with the official Swift.org bootstrap compiler.
4. The builder mounts source read-only and cross-builds the Linux/amd64 runtime
   products into an external install root. It skips compiler and LLVM builds.
5. The macOS `swift-sdk-generator` consumes that install root as its sole
   target-Swift package. It never mixes in an official Linux runtime tarball.
6. Collider overlays the runtime into the generated package sysroot, installs
   the official Android bundle, and builds one behavioral consumer per target
   triple.
7. Structural validation rejects libstdc++, requires libc++ on every consumer,
   verifies ELF architecture and interpreter, and verifies Android 16 KiB load
   alignment.
8. Collider atomically publishes the immutable generation and discovery links.

## Source and Cache Identity

The complete Swift sibling graph remains a pinned submodule graph. Collider
refuses dirty or mismatched generator source before task construction. Source
gitlinks, the runtime preset, builder context, package lock, sysroot preparer,
generator source, Xcode identity, NDK identity, validation fixture, and
validator select the immutable generation.

Runtime Ninja products and ccache live outside source submodules. The runtime
task is content-addressed, so an unchanged source and build identity skips the
entire task. When an identity changes, the stable external build root and
ccache preserve valid upstream incremental work; the runtime install root is
recreated before publication so stale files cannot survive.

Downloads, sysroot preparation, builder-image preparation, generator build,
runtime build, assembly, validation, activation, and discovery are separate
tasks. Their declared inputs determine reuse. There is no legacy build-root
lookup, migration reader, dual pipeline, or cache fallback.

## Phase 1 — Establish the libc++ Target Boundary

The Nucleus Swift fork removes Linux from the libstdc++ platform set, passes
`-stdlib=libc++` to the Linux C++ overlay, and deletes the libstdc++ module-map
target and installed facade. Runtime, Dispatch, and Foundation C++ compilation
receive explicit libc++ flags.

The SDK generator writes libc++ flags into the Linux Swift and C++ tool
properties. Its Swift tool properties include `-lc++`, so ordinary SwiftPM
products retain the target C++ runtime dependency even when their immediate
source file does not import C++.

Phase gate:

1. The Nucleus Swift runtime graph completes for Linux/x86_64.
2. Every installed ELF file is free of libstdc++ and `GLIBCXX` requirements.
3. C++-using runtime artifacts require `libc++.so.1`.
4. Generator tests assert the exact libc++ tool properties.

## Phase 2 — Make the Runtime Build Native-arm64 Hosted

The runtime-builder image is Linux/arm64 and contains the exact official
Swift.org Linux/arm64 snapshot. Its wrapper translates CMake's unsupported
Swift linker spelling to the official driver's `-use-ld=lld` spelling and
supplies the just-built x86_64 `swiftrt.o` when the package-only sysroot has no
bootstrap Swift overlay.

The preset declares the x86_64 target, package sysroot, build resource
directory, module cache, lld, libc++, and only the required runtime products.
Source is read-only; build, compiler cache, and install roots are explicit
writable mounts. Network access and Linux capabilities are disabled.

Phase gate:

1. Apple `container` executes only arm64 Linux processes.
2. Runtime outputs are x86_64 ELF.
3. Foundation resolves XML and compression libraries from the x86_64 sysroot.
4. A repeated unchanged build reports no work for stable runtime components.

## Phase 3 — Assemble Without a Prebuilt Linux Runtime

Remove the Linux target package from the lock and download graph. Pass the
qualified runtime install root directly to
`swift-sdk-generator --target-swift-package-path`. The sysroot task depends
only on locked Ubuntu packages.

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
2. Run a fresh `collider toolchain rebuild`.
3. Inspect every Linux SDK ELF artifact and all three behavioral consumers.
4. Run an unchanged rebuild and prove the complete generation is reused.
5. Change one runtime source identity and prove downloads, generator inputs,
   and unrelated SDK inputs remain reusable while the runtime task rebuilds.
6. Qualify the immutable Linux artifact on a real Linux/x86_64 worker.

## Acceptance Criteria

- The M2 Ultra performs every build.
- Every host process is macOS/arm64 or Linux/arm64.
- No Swift compiler, LLVM, or Linux host toolchain is built.
- No Rosetta, QEMU, amd64 VM, or amd64 build machine is used.
- Linux/amd64 runtime products come from the pinned Nucleus source graph.
- The package sysroot and published SDK expose libc++ exclusively.
- Linux amd64, Android arm64, and Android amd64 are selected by exact triples.
- Target executables never run on the Mac.
- Published generations are immutable and failure-safe.
- Unchanged identities skip the complete generation and retain valid
  component-level incremental caches for the next changed identity.
