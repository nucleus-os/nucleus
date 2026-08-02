# Swift target SDK and Skia fork qualification plan

**Status: active.**

**Invariant: Nucleus does not build a Swift compiler, Swift driver, LLVM, Clang, or Linux host tools. macOS uses Xcode, the native Apple-container Linux/arm64 builder uses the official Swift.org compiler as a bootstrap compiler, and Collider builds only Linux target runtimes and Swift SDK artifacts. First-party Swift and Skia changes live as commits in `nucleus-os` forks.**

The target-SDK workspace mechanics are authoritative in [swift-toolchain-incremental-workspace-plan.md](swift-toolchain-incremental-workspace-plan.md). This plan owns only source provenance and final qualification that crosses Swift SDK and Skia boundaries.

## Phase 1 — Lock source provenance

Retain only the target-runtime source closure declared in the authoritative
workspace plan. Ensure every modified Swift source and Skia checkout points to
a genuine `nucleus-os` fork commit. Unmodified sources retain canonical
upstream remotes. Collider validates exact gitlinks but never fetches, resets,
patches, or materializes source.

Gate: a fresh recursive clone contains the exact source graph with no patch-application workflow.

## Phase 2 — Qualify official host compilers

Verify the selected Xcode compiler on macOS and official Linux/arm64 compiler in the Apple container against the root manifest, Swift 6.4 language mode, C++ interoperability, and required package features.

Gate: host-side package planning and the supported host build lanes succeed without a locally built compiler.

## Phase 3 — Qualify target SDK artifacts

Build the Linux/arm64 runtime natively, cross-build the Linux/amd64 runtime, and
assemble both into one Linux Swift SDK through Collider. Install the official
Android Swift SDK artifact. Verify target triples, sysroots, runtime libraries,
module interfaces, C++ standard library selection, and relocation from the
user cache.

Gate: clean cross-builds consume only declared SDK artifacts and reproduce after derived-state removal.

## Phase 4 — Qualify Skia Graphite

Build the render SDK from the fork commit for macOS, Linux/amd64, Linux/arm64 where required, and Android/arm64. Exercise the root renderer link closure and confirm the Vulkan/Graphite feature set required by each platform.

Gate: render and Android host tests link without source-tree artifact reach-through.

## Phase 5 — Delete obsolete machinery

Remove compiler-builder containers, patch materializers, generated host-toolchain activation, `/opt` installation assumptions, and recipes whose only purpose was building Swift or LLVM.

Gate: repository searches find no supported path that builds a compiler or selects a generated Linux host toolchain.

## Phase 6 — End-to-end qualification

Run root build/test lanes, Android packaging verification, both Linux runtime
builds, and native SDK provenance checks from a fresh checkout and from an
incrementally rebuilt checkout.
