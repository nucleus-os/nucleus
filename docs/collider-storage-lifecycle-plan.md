# Collider storage lifecycle plan

Status: active.

## Invariant

Collider deletes only generated data that a resolved task declaration owns and
that the runtime proves inactive. Source, identity material, active outputs, and
leased rollback generations are never cleanup candidates. Underlying build
systems retain ownership of their incremental databases; Collider selects their
bounded roots but does not reproduce their dependency graphs.

Publication validates a complete candidate before one atomic activation.
Interrupted candidates are recoverable generated data. Downloads, published
generations, incremental roots, and run records participate in one ownership
inventory without forcing unrelated components into one storage implementation.

Storage declarations, APFS volume validation, cache status, graph-owned cleaning,
pruning, and safety tests exist. Phases 1 through 3 are complete. Lifecycle recovery
qualification remains.

The resolved component catalog now owns the storage declarations consumed by
`collider cache status` and `collider cache prune`; `RepositoryCache` no longer
maintains a second inventory. Declarations carry typed component ownership and
typed task or runtime producers, and catalog planning rejects unknown or
cross-component producer tasks.

The coarse roots are now split into component-owned Skia, React Native, Wayland,
AOSP, gfxstream, browser, native-builder, target-SDK, and runtime-artifact roots.
Each declaration names its resolved producer tasks, while the synthetic storage
component contains only Collider runtime and toolchain state. Stale Swift platform
and build-workspace buckets with no producer were removed.

Component-owned declarations now live beside the recipes that construct their
tasks. Removable task-owned storage derives its complete lock set from those
producer declarations; separately maintained cleanup lock paths no longer exist.
Cache pruning receives the full resolved catalog and acquires those locks through
the same runtime path as task execution.

Generation declarations now carry an explicit rollback-generation count, and
directory retention counts only inactive generations rather than accidentally
counting the active generation. Browser storage is split into source, build, CEF,
browser-product, installation, tool, diagnostic, and lock roots with distinct
retention. Linux catalogs additionally declare shell runtime and package-manifest
generations, Tracy build state, and Android add-on packaging and publication
roots. The final Phase 1 audit added protected AOSP source and signing-identity
boundaries, generated AOSP tooling, host SwiftPM and package-graph state,
language-server publication, and benchmark results. Catalog validation now rejects
removable storage that overlaps declared source or identity and rejects active links
outside their safety root.

Phase 2 aligns declared policy with execution. AOSP, browser, shell, and assembled
Linux runtime generations retain exactly their active generation plus their declared
inactive rollbacks. The Linux runtime assembler receives its retention count from its
own recipe instead of inheriting the shell installation policy. Linux runtime and
package-manifest generations and AOSP generations now describe their exact versioned
directories; AOSP builder metadata is a separate cache. Chromium build trees are
incremental state retained until explicit clean, while automatic Chromium retention
also removes only abandoned content-identity candidates under the publication locks.
Swift target SDK generations remain explicitly pruned. Source, identity, downloads,
published SDKs, and incremental state are not automatically removed. Every symlink
activation now uses the durable atomic activation path.

## Phase 1 — Derive ownership from task declarations (complete)

Attach storage class, safety root, producer tasks, workflow locks, clean
eligibility, prune eligibility, active link, and rollback count to the task or
component declaration that owns each root. Include SwiftPM scratch directories,
Skia/RN/CMake outputs, AOSP and Chromium outputs, Swift/native SDK generations,
browser/CEF/Android publications, downloads, and run records.

Reject workspace roots, home directories, broad cache roots, paths outside a
safety root, conflicting overlaps, source or identity descendants, and removable
roots without an owning lock.

Gate: the resolved graph enumerates every Collider-owned generated root and no
hand-maintained global cleanup inventory remains.

Complete. The resolved component graph is the sole storage inventory, source and
identity boundaries are structural, and every task-produced generated root found by
the Phase 1 audit has an owning declaration.

## Phase 2 — Apply explicit retention by storage class (complete)

Keep source and identity data indefinitely. Keep each active published
generation and its declared rollback generations. Keep incremental build roots
until explicit component cleaning. Keep downloads while referenced by the current
graph or retention policy. Keep run records under the existing run-retention
policy.

Use a common candidate/activation helper only for components that share the same
validated-generation lifecycle. Preserve specialized source materialization and
underlying build-system state instead of forcing them through a generic
transaction abstraction.

Gate: retention is deterministic, active links never dangle, and interrupted
publication cannot expose a partial generation.

Complete. Catalog validation permits automatic retention only for versioned
generations with active links and run records. Publication and interruption tests
cover durable cutover, exact inactive rollback counts, candidate cleanup, and refusal
to replace non-symlink data with an activation link.

## Phase 3 — Implement graph-owned clean and prune (complete)

Implement `collider clean <component>` for declared incremental roots and
`collider cache prune` for expired runs, interrupted candidates, explicitly
prunable generations, and dangling Collider-managed OCI images. Both commands
resolve targets from the component catalog and acquire every declared producer
lock before mutation.

The download manager does not keep a second artifact cache: verified bytes move
to component-owned destinations, while its content-addressed directory contains
only resumable transfer metadata. Invalid or terminal transfer state is removed by
the download manager itself. That state remains protected from broad pruning
because resolver-discovered package downloads are not all knowable while the task
graph is planned. The graph declares no general snapshot cache.

Ordinary build and test operations perform only bounded automatic candidate and
retention cleanup. They do not wipe healthy incremental state.

Gate: behavioral tests cover active and interrupted generations, overlapping
declarations, dry-run and locked mutation, and selected-component isolation without
touching source, identity, or unrelated user data. Filesystem failures propagate
without broad fallback deletion.

Complete. `clean` accepts canonical component names and aliases, reports its exact
declared roots, rejects cleanable runtime state without producer locks, and removes
only the selected component's `explicitClean` roots while holding the union of its
producer locks. `cache prune` no longer identifies the Swift SDK by a hard-coded
storage identifier: any `explicitPrune` generation declaration supplies its active
link, rollback count, and interrupted-candidate naming. Target discovery happens
inside those producer locks so activation cannot change the protected generation
between selection and deletion. Dry-run and mutation tests cover selected-component
isolation, source protection, interrupted candidates, inactive generations, active
generation protection, and unrelated directory preservation. Catalog and lifecycle
tests cover unsafe roots, overlaps, producer ownership, exact rollback retention,
atomic activation, and interrupted publication.

## Phase 4 — Qualify lifecycle recovery

Interrupt each publication stage, terminate builds while locks are held, replace
active generations, roll back once, and run concurrent status/prune requests.
Verify APFS and default user-cache layouts with identical ownership semantics.

Gate: recovery leaves one valid active generation, bounded rollback state, no
live candidate deletion, and no stale lock or lease that requires manual repair.
