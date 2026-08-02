# Swift target SDK and Skia fork qualification plan

**Status: active.**

**Invariant: Nucleus does not build Swift, LLVM, or Linux host tools. macOS uses Xcode, Apple-container Linux/arm64 uses the official Swift toolchain, and Collider cross-builds only Nucleus Linux/amd64 SDK overlays and Android Swift SDK artifacts. First-party Skia changes live as commits in the `nucleus-os` fork.**

The target-SDK workspace mechanics are authoritative in [swift-toolchain-incremental-workspace-plan.md](swift-toolchain-incremental-workspace-plan.md). This plan owns only source provenance and final qualification that crosses Swift SDK and Skia boundaries.

## Phase 1 — Lock source provenance

Ensure every modified Swift sibling and Skia checkout points to a genuine `nucleus-os` fork commit. Unmodified sources retain canonical upstream remotes. Collider validates exact gitlinks but never fetches, resets, patches, or materializes source.

Gate: a fresh recursive clone contains the exact source graph with no patch-application workflow.

## Phase 2 — Qualify official host compilers

Verify the selected Xcode compiler on macOS and official Linux/arm64 compiler in the Apple container against the root manifest, Swift 6.4 language mode, C++ interoperability, and required package features.

Gate: host-side package planning and the supported host build lanes succeed without a locally built compiler.

## Phase 3 — Qualify target SDK artifacts

Build the Linux/amd64 Nucleus runtime SDK overlay and Android Swift SDK artifact through Collider. Verify target triples, sysroots, runtime libraries, module interfaces, C++ standard library selection, and relocation from the user cache.

Gate: clean cross-builds consume only declared SDK artifacts and reproduce after derived-state removal.

## Phase 4 — Qualify Skia Graphite

Build the render SDK from the fork commit for macOS, Linux/amd64, Linux/arm64 where required, and Android/arm64. Exercise the root renderer link closure and confirm the Vulkan/Graphite feature set required by each platform.

Gate: render and Android host tests link without source-tree artifact reach-through.

## Phase 5 — Delete obsolete machinery

Remove compiler-builder containers, patch materializers, generated host-toolchain activation, `/opt` installation assumptions, and recipes whose only purpose was building Swift or LLVM.

Gate: repository searches find no supported path that builds a compiler or selects a generated Linux host toolchain.

## Phase 6 — End-to-end qualification

Run root build/test lanes, Android packaging verification, Linux/amd64 runtime cross-build, and native SDK provenance checks from a fresh checkout and from an incrementally rebuilt checkout.
