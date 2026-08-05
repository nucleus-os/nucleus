# Swift target SDK and Skia qualification plan

Status: active.

## Invariant

Nucleus builds target runtimes and target SDK artifacts, never a Swift compiler,
Swift driver, LLVM, Clang, SwiftPM, SourceKit-LSP, DocC, or Linux host toolchain.
Modified Swift and Skia repositories are exact commits in genuine `nucleus-os`
forks. Unmodified repositories retain canonical upstream remotes. Collider
validates source gitlinks without selecting, fetching, resetting, cleaning,
patching, or materializing them.

The source graph, official bootstrap compilers, dual-architecture Linux Swift
SDK, official Android Swift SDK, and Linux native SDK generations are already
implemented. This plan owns only the remaining cross-boundary qualification.

## Phase 1 — Qualify the complete Skia matrix

Build the render SDK from the selected Skia fork commit for every supported
artifact target: macOS/arm64, Linux/arm64, Linux/x86_64, and Android/arm64.
Validate Graphite/Vulkan features, exported symbols, libc++ linkage, relocation,
and absence of source-tree artifact reach-through.

Gate: the renderer and Android host link only against their declared native SDK
generation for every supported target.

## Phase 2 — Qualify clean and incremental consumers

From a fresh recursive clone, run the root host build and test graph, both Linux
runtime build/test lanes, Android Gradle packaging verification, public-source
consumer builds, and native SDK provenance validation. Repeat without changing
inputs and prove that the declared Swift and native SDK outputs are reused.

Gate: clean and unchanged incremental runs pass with exact source provenance and
without building or selecting a generated host toolchain.

## Phase 3 — Close the qualification record

Record the successful run identities in the current SDK and build contracts,
remove this qualification plan, and retain the source and artifact invariants in
the runtime architecture documentation.
