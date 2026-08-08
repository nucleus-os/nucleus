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

Storage declarations, APFS volume validation, cache status, pruning foundations,
and safety tests exist. Recipe-derived ownership and uniform user commands remain.

The resolved component catalog now owns the storage declarations consumed by
`collider cache status` and `collider cache prune`; `RepositoryCache` no longer
maintains a second inventory. Declarations carry typed component ownership and
typed task or runtime producers, and catalog planning rejects unknown or
cross-component producer tasks.

The coarse roots are now split into component-owned Skia, React Native, Wayland,
AOSP, gfxstream, browser, native-builder, target-SDK, and runtime-artifact roots.
Each declaration names its resolved producer tasks, while the synthetic storage
component contains only Collider runtime and toolchain state. Stale Swift platform
and build-workspace buckets with no producer were removed. Phase 1 still needs to
move declaration construction beside the recipes, derive workflow locks from the
producer declarations, add explicit rollback counts, and cover remaining
platform-conditional publication roots.

## Phase 1 — Derive ownership from task declarations

Attach storage class, safety root, producer tasks, workflow lock, clean
eligibility, prune eligibility, active link, and rollback count to the task or
component declaration that owns each root. Include SwiftPM scratch directories,
Skia/RN/CMake outputs, AOSP and Chromium outputs, Swift/native SDK generations,
browser/CEF/Android publications, downloads, and run records.

Reject workspace roots, home directories, broad cache roots, paths outside a
safety root, conflicting overlaps, source or identity descendants, and removable
roots without an owning lock.

Gate: the resolved graph enumerates every Collider-owned generated root and no
hand-maintained global cleanup inventory remains.

## Phase 2 — Apply explicit retention by storage class

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

## Phase 3 — Implement graph-owned clean and prune

Implement `collider clean <component>` for declared incremental roots and stale
candidates, plus `collider cache prune` for unreferenced downloads, snapshots,
expired runs, and excess rollback generations. Both commands present the exact
resolved targets before mutation and acquire every producer lock.

Ordinary build and test operations perform only bounded automatic candidate and
retention cleanup. They do not wipe healthy incremental state.

Gate: behavioral tests cover active, leased, overlapping, interrupted,
permission-failed, and concurrent cleanup without touching source, identity, or
unrelated user data.

## Phase 4 — Qualify lifecycle recovery

Interrupt each publication stage, terminate builds while locks are held, replace
active generations, roll back once, and run concurrent status/prune requests.
Verify APFS and default user-cache layouts with identical ownership semantics.

Gate: recovery leaves one valid active generation, bounded rollback state, no
live candidate deletion, and no stale lock or lease that requires manual repair.
