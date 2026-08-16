# Swift target SDK and Skia qualification plan

Status: active.

## Invariant

The Nucleus target-SDK graph builds target runtimes and target SDK artifacts,
never a Swift compiler, Swift driver, LLVM, Clang, SourceKit-LSP, DocC, or Linux
host toolchain. Before that graph executes, the native-builder prerequisite
graph compiles only the pinned Nucleus `swift-package-manager` host executable
and its SwiftBuild dependencies natively for arm64 with the exact official Swift 6.4
compiler. It uses host-materialized dependencies, offline container execution,
a persistent Collider workspace, and a bounded read-only overlay artifact
mounted separately from the single stable builder image. Overlay changes never
rebuild or unpack that heavyweight image. It does not build or replace
the compiler toolchain, and no remote release artifact or GitHub-hosted overlay
build participates.
Specialized container entrypoints are hashed read-only mounts over reusable
dependency images rather than entrypoint-only child images. Their edits do not
reimport the heavyweight image layers.
Modified Swift and Skia repositories are exact commits in genuine `nucleus-os`
forks. Unmodified repositories retain canonical upstream remotes. Collider
validates source gitlinks without selecting, fetching, resetting, cleaning,
patching, or materializing them.

The source graph, official bootstrap compilers, dual-architecture Linux Swift
SDK, official Android Swift SDK, and Linux native SDK generations are already
implemented. This plan owns only the remaining cross-boundary qualification.

## Phase 1 — Qualify the complete Skia matrix

Status: active.

Build the render SDK from the selected Skia fork commit for every supported
artifact target: macOS/arm64, Linux/arm64, Linux/x86_64, and Android/arm64.
Validate Graphite/Vulkan features, exported symbols, libc++ linkage, relocation,
and absence of source-tree artifact reach-through.

Gate: the renderer and Android host link only against their declared native SDK
generation for every supported target.

Linux arm64 and x86_64 render SDKs are qualified through the complete native
package graph. Android Skia now uses arm64 Clang with the NDK sysroot and the
complete Android Swift/C++ package succeeded in run
`2026-08-16T15-54-54.335Z-81451`. Collider run
`2026-08-16T16-49-28.204Z-20638` revalidated both Linux render SDKs and built
both root Linux consumers. The macOS render/consumer gate remains.

## Phase 2 — Qualify clean and incremental consumers

From a fresh recursive clone, run the root host build and test graph, both Linux
runtime build/test lanes, Android Gradle packaging verification, public-source
consumer builds, and native SDK provenance validation. Repeat without changing
inputs and prove that the declared Swift and native SDK outputs and local OCI
image digests are reused. Delete one reconstructible image between repetitions
and prove that Collider invalidates the recorded image task and recreates the
exact local image without a registry fallback.

Resolve every SwiftPM dependency from an empty host dependency cache before the
offline builds. The canonical Swift System identity resolves through the pinned
mirror to the exact `nucleus-os` fork commit; no manifest names an unavailable
upstream ref, no duplicate source identity enters the graph, and Swift
Subprocess imports the selected `SystemPackage` module in both Linux lanes.

Gate: clean and unchanged incremental runs pass with exact source provenance and
without building or selecting a generated host toolchain; dependency resolution
from an empty cache selects the recorded fork closure without an identity
warning, unavailable ref, or missing module.

The active target-SDK generation now publishes SwiftPM discovery through stable
`current` paths behind an explicit repair barrier. Empty-cache resolution selects
the pinned `nucleus-os` Swift System and Swift Subprocess forks without a
duplicate identity, and the complete dual-architecture package graph consumes
the repaired SDK discovery. Fresh-clone, root host, image-reconstruction, and
remaining public-consumer gates remain.

## Phase 3 — Close the qualification record

Record the successful run identities in the current SDK and build contracts,
remove this qualification plan, and retain the source and artifact invariants in
the runtime architecture documentation.
