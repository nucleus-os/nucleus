# Swift Toolchain and Skia Fork-Commit Migration

## Invariant

Every downstream Swift toolchain and Skia source change used by Nucleus is an
ordinary source commit in a genuine `nucleus-os` fork. Production source
materialization selects exact commits and trees from authoritative source
identity. It never applies a Nucleus patch, accepts a dirty checkout, treats a
reverse-applicable patch as success, or repairs an existing source generation.

The Swift source lock records the complete repository graph consumed by the
toolchain build. Modified repositories resolve to genuine `nucleus-os` forks;
unmodified repositories resolve directly to their canonical upstreams. Skia
continues to use the monorepo submodule gitlink as its exact source selection.

Neither source identity contains a format-version field. An incompatible lock
shape or source-layout change requires a hard migration and regeneration of
affected caches.

## Current Patch Ownership

The Swift toolchain build currently applies 18 patches after
`swift/utils/update-checkout`:

| Repository | Patch count | Required fork |
| --- | ---: | --- |
| `swift` | 10 | `nucleus-os/swift` |
| `swift-driver` | 2 | `nucleus-os/swift-driver` |
| `swift-build` | 4 | `nucleus-os/swift-build` |
| `swiftpm` | 1 | `nucleus-os/swift-package-manager` |
| `swift-corelibs-foundation` | 1 | `nucleus-os/swift-corelibs-foundation` |

`indexstore-db` and `sourcekit-lsp` are currently included in Collider's
patch-capable repository list but have no Nucleus patches. They remain canonical
upstream checkouts unless Nucleus introduces source changes.

The Skia build currently applies one patch to
`src/gpu/graphite/vk/VulkanRenderPass.cpp` after dependency synchronization.
`nucleus-os/skia` is already a genuine fork of `google/skia`; the submodule
currently selects upstream-derived commit
`e14ad17c2b1bad04f06afc41beb4088fb4d74063`.

## Phase 1: Capture Qualified Source Trees

Capture the exact pre-migration source state produced by the current workflows.
The capture records:

1. the selected Swift source ref and update-checkout scheme;
2. every repository path, canonical remote, resolved commit, and tracked tree
   materialized by `update-checkout`;
3. the final tracked trees of the five patched Swift repositories;
4. the Swift build presets, host toolchain inputs, Android NDK identity, and
   Android SDK build inputs;
5. the Skia submodule commit and tree before patch application;
6. the final patched Skia tree;
7. the Skia DEPS file and every resolved `third_party/externals` dependency;
8. the qualified host and Android build artifact identities.

Resolve patch ownership during capture. A change lands in the repository that
owns the modified file. Do not fold dependency changes into the `swift`
orchestrator repository merely to reduce the number of forks.

Acceptance requires every current patch to contribute exactly its intended
tracked-tree delta. Drop patches whose delta is already present upstream or no
longer used by a qualified build.

## Phase 2: Establish the Swift Fork Source Trees

Establish genuine `nucleus-os` forks of the five modified canonical
repositories:

1. `swiftlang/swift` becomes `nucleus-os/swift`;
2. `swiftlang/swift-driver` becomes `nucleus-os/swift-driver`;
3. `swiftlang/swift-build` becomes `nucleus-os/swift-build`;
4. `swiftlang/swift-package-manager` becomes
   `nucleus-os/swift-package-manager`;
5. `swiftlang/swift-corelibs-foundation` becomes
   `nucleus-os/swift-corelibs-foundation`.

Each fork preserves its GitHub parent relationship. Its selected Nucleus source
commit has the captured upstream commit as an ancestor and reproduces the
captured patched tree exactly. Preserve the logical patch ordering as ordinary,
reviewable source changes. Squash only changes that form one inseparable source
contract; do not retain artificial patch-file boundaries.

The `swift` fork retains upstream repository mappings and schemes. It does not
silently redirect dependency repositories. Repository selection belongs to the
Nucleus source lock and materializer.

Acceptance requires every selected commit and tree to resolve from its remote,
every frozen upstream commit to be an ancestor, and every selected checkout to
be clean.

## Phase 3: Make the Complete Swift Source Lock Authoritative

Add `swift-toolchain/source.lock.json` as the sole production source-selection
input for Swift toolchain builds. It records:

1. the selected Swift release line;
2. the complete set of repositories required by the qualified build;
3. each checkout path and logical repository name;
4. each exact selected commit and tree;
5. each source remote;
6. each canonical upstream remote and frozen upstream commit for modified
   repositories;
7. the source commit whose update-checkout scheme was used to resolve the
   graph.

The lock includes unmodified repositories as exact canonical-upstream commits.
This prevents a moving release branch or scheme from changing one dependency
without changing source identity.

Collider validates the complete repository set, unique checkout paths, exact
remote ownership, full lowercase object identifiers, and required upstream
ancestry metadata. The source-generation identifier is derived from the
complete lock digest.

An explicit lock-refresh workflow may use upstream `update-checkout` to resolve
a new release graph. Production bootstrap and build never invoke it to select
source.

## Phase 4: Materialize Exact Clean Swift Source

Replace branch/tag synchronization and production `update-checkout` execution
with one exact source materializer:

1. verify or create bounded persistent object caches for every locked
   repository;
2. create a private source-generation candidate;
3. materialize each exact locked commit at its declared sibling checkout path;
4. verify every `HEAD`, tracked tree, remote, and clean worktree;
5. validate that the resulting layout satisfies `build-script` repository
   discovery;
6. write source provenance containing the lock digest and every selected
   commit and tree;
7. recompute provenance from the candidate;
8. publish the immutable generation and switch the active link atomically.

Never clean, reset, patch, or reuse a mismatched generation. Delete an invalid
candidate and materialize a new one. Persistent object caches may be reused
only as object stores; they never define source selection.

Update Collider task identity so every host toolchain and Android SDK build
depends on the source-lock digest and validated source provenance.

## Phase 5: Qualify the Commit-Backed Swift Toolchain

Qualify the commit-backed workflow before deleting the old patch architecture:

1. materialize a cold Swift source generation;
2. repeat bootstrap and prove exact generation reuse;
3. build and validate the Linux Swift 6.4 host toolchain;
4. run the compiler, SwiftPM, driver, macro-plugin, Foundation, dispatch, and
   Swift Testing validation currently required by Nucleus;
5. build every supported Android Swift SDK architecture;
6. compile, link, load, and run representative Android packages through each
   SDK;
7. validate Android resource-directory, NDK toolchain, API-level triple,
   Foundation, dispatch, macro-plugin, and Swift Testing behavior addressed by
   the former patches;
8. build and validate the macOS-hosted toolchain and Android SDK path affected
   by the Darwin-host CMake changes;
9. compare artifact structure and required runtime contents with the captured
   qualified outputs;
10. inspect source provenance and prove that all checkouts remain clean after
    every build.

Failure in any formerly patched behavior is a missing or incorrectly owned
source commit. Correct the owning fork and replace the exact lock atomically.
Do not restore a patch fallback.

## Phase 6: Delete the Swift Patch Architecture

After Phase 5 passes:

1. delete `swift-toolchain/patches/`;
2. delete the ordered patched-repository list from the Swift Collider recipe;
3. delete toolchain source-clean and per-patch tasks;
4. delete reverse-patch and already-applied behavior from the Swift workflow;
5. update toolchain documentation to describe exact lock-backed source;
6. replace patch-oriented tests with behavioral materialization, provenance,
   task-ordering, and product-validation tests;
7. audit the workspace for stale Swift patch paths and patch-application
   references.

The Swift workflow ends this phase with one source path and no compatibility
route to the removed patch stack.

## Phase 7: Land the Skia Change in Its Existing Fork

Reproduce the qualified Skia tree as an ordinary change in
`nucleus-os/skia`. The selected fork commit has
`e14ad17c2b1bad04f06afc41beb4088fb4d74063` as an ancestor and changes only the
owned Graphite Vulkan render-pass dependency contract.

Move `core/third-party/skia` to the selected fork commit. The monorepo
submodule gitlink remains the authoritative Skia source identity; do not add a
second Skia lock file.

Synchronize Skia dependencies from the selected clean checkout and record:

1. the selected Skia commit and tree;
2. the DEPS digest;
3. the resolved external dependency graph;
4. clean Skia worktree status after dependency synchronization.

Acceptance requires the selected remote tree to equal the captured patched
tree exactly.

## Phase 8: Qualify the Commit-Backed Skia Build

Qualify Skia from a fresh submodule checkout:

1. synchronize the exact DEPS graph;
2. build the host Graphite/Vulkan libraries;
3. build the Android ARM64 Graphite/Vulkan libraries;
4. run the Core Swift and C++ bridge tests;
5. run renderer tests with Vulkan validation enabled;
6. exercise consecutive Graphite render passes separated by text-atlas or
   resource uploads;
7. verify color attachment load/store and layout transitions across the
   render-pass boundary;
8. run the Nucleus renderer integration tests and inspect validation output for
   dependency, access-mask, and layout hazards;
9. prove the Skia checkout remains clean after dependency synchronization and
   all builds.

A failure is corrected in `nucleus-os/skia`. Do not reintroduce the monorepo
patch.

## Phase 9: Delete the Skia and Generic Patch Pipeline

After Phase 8 passes:

1. delete
   `core/third-party/patches/skia-graphite-vulkan-render-pass-dependencies.patch`;
2. remove the patch input and patch operation from `core.sources`;
3. make dependency synchronization consume the exact clean submodule directly;
4. delete the generic `GitPatchApplication` task model and execution support
   when the workspace audit confirms no remaining consumers;
5. delete patch-specific task hashing, diagnostics, and tests;
6. update Core and bootstrap documentation to state that Skia changes live in
   the fork;
7. audit the complete workspace for patch discovery, `git apply`, reverse
   checks, and already-applied behavior.

The final audit permits no first-party source patch stacks. Any remaining
`.patch` files must be upstream-owned test fixtures or external data that
Collider never applies.

## Phase 10: Verify the Unified Final State

Run final acceptance in this order:

1. materialize the Swift source graph from an empty generation cache;
2. repeat Swift bootstrap and prove verified reuse;
3. build and validate the host toolchain;
4. build and validate every supported Android Swift SDK;
5. synchronize Skia dependencies from a fresh exact submodule checkout;
6. build and validate host and Android Skia;
7. run all Collider, Core, renderer, and source-workflow tests;
8. inspect Swift and Skia provenance against their selected remote objects;
9. verify every modified repository is a genuine GitHub fork of its canonical
   parent;
10. verify every selected tree is clean and remotely resolvable;
11. verify no Nucleus build task discovers or applies source patch files;
12. verify cold and repeated builds produce the same source identities.

## Final State

The monorepo owns Swift and Skia orchestration, exact source selection,
build configuration, artifact validation, and atomic publication. It owns no
downstream Swift or Skia patch files.

The five Swift forks own all Swift-family source changes. The Swift source lock
selects the complete modified and unmodified repository graph. The existing
Skia fork owns the Graphite Vulkan dependency change, and the monorepo gitlink
selects it exactly. Collider consumes clean source trees and contains no generic
first-party patch application pipeline.
