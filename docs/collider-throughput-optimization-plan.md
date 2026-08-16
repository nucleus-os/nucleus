# Collider throughput optimization plan

Status: active.

## Invariant

Collider makes expensive work concurrent only when its inputs and writable
state are independent. Performance work never weakens source validation,
content-addressed product identity, offline container execution, bounded output
ownership, package qualification, or product-store reachability. Unchanged
invocations reuse all valid build and package state.

## Current Evidence

Run `2026-08-16T17-27-41.466Z-39675` is the corrected full native package
baseline. The arm64 and x86_64 package-cohort actions took 357.380 and 400.960
seconds respectively. Both actions claimed the same writable product-store root
and publication lock, so the scheduler correctly serialized them even though
their expensive archive assembly is architecture-local. Each action also
claimed 24 CPUs, which prevents safe overlap on the M2 Ultra without first
right-sizing the lanes.

Run `2026-08-16T17-45-01.664Z-43818` is the unchanged package baseline. All
expensive package cohorts and qualifications remained clean. Executed work was
9.298 seconds in `core.sources`, 1.936 seconds in `browser.depot-tools`, 1.839
seconds in package retention, and negligible Swift SDK discovery. The run spent
9.323 seconds executing and 12.396 seconds planning. `core.sources` currently
performs a forced detached checkout and redundant Git queries for every Skia
external even when its commit, remote, and tracked state already match.

Run `2026-08-16T17-25-16.574Z-36193` is the Collider test baseline. The CLI
package test action took 105.591 seconds. Several tests independently construct
the complete production component catalog; the longest single test spent
78.845 seconds doing so while the test process was also running other catalog
construction tests.

## Phase 1: Establish the Measured Critical Paths

Status: complete.

The full-build, unchanged-build, task-graph, package-stage, store-retention, and
test-suite paths have been audited. The dominant structural costs are the
package actions' shared writable store, repeated payload copies and compression,
unconditional Skia external mutation, repeated complete catalog construction in
tests, and the broad SwiftPM target closure of the Linux assembler.

Gate satisfied: the three successful baseline runs above identify task-level
costs without a cache wipe, synthetic workload, or relaxed validation.

## Phase 2: Record Native Package Stage Costs

Status: complete.

Record package payload materialization, Debian assembly and validation, RPM
assembly and validation, Arch assembly and validation, product-envelope
construction, product-store publication, and final generation publication as
separate run observations. Include input and output byte counts. Timing data
belongs only to run records and never enters task identity, package bytes,
product envelopes, or generation digests.

Gate: a rebuilt arm64 and x86_64 package cohort exposes every declared stage in
the run record, and repeated assembly still produces the same deterministic
package and product identities.

Gate satisfied: run `2026-08-16T19-38-50.660Z-92080` rebuilt and qualified both
architecture cohorts. Each cohort persisted all ten declared observations with
duration, input bytes, and output bytes. A same-input assembly audit isolated
the only differing bytes to RPM's wall-clock header build time while confirming
identical RPM payload bytes; RPM assembly now uses fixed nonzero source epoch
`1`, because RPM treats epoch `0` as absent. Observation values remain confined
to run manifests and do not participate in task, archive, envelope, product, or
generation identity.

## Phase 3: Isolate Product-Store Publication

Make each architecture package action write only its immutable package
generation, product envelopes, and the small payloads required by those
envelopes. Remove the product-store mount, product-store effect, shared
product-store lock, and source-snapshot publication lock from expensive OCI
assembly.

Add a lightweight host publication action per architecture. It consumes the
completed immutable generation, revalidates every archive, payload, envelope,
and provenance binding, publishes them into the single architecture-neutral
`LocalProductArtifactStore`, and emits a receipt. Only these small publication
actions serialize on the product store. Lifecycle qualification consumes the
receipt and reads the immutable store without a publication lock. Retention
continues after both architecture qualifications.

Run the two architecture assembly actions together with 12-CPU OCI limits so
their combined declared budget fits the M2 Ultra. Preserve distinct package
roots and all existing artifact targets.

Gate: graph inspection proves that both expensive architecture actions can run
concurrently, only store publication and retention claim writable store state,
qualifications can overlap, and substitution or interrupted publication still
fails closed.

## Phase 4: Materialize Each Package Payload Once

Create one canonical payload tree per logical package and architecture before
family-specific metadata is added. Build Debian, RPM, and Arch views with
hard-linked regular files plus independently created directories, symbolic
links, control metadata, and maintainer scripts. Keep every view inside one
owned architecture staging filesystem so hard links never cross a mount or
storage boundary.

RPM consumes a hard-linked source view and keeps `__os_install_post` disabled so
it cannot mutate or strip the immutable cross-architecture payload.
Run the three family adapters with bounded concurrency after canonical payload
materialization. Keep package assembly serial within each family until the
stage observations prove that finer decomposition is useful.

Gate: file identities prove that runtime and browser bytes are materialized
once per architecture, format metadata remains isolated, all native package
lifecycle tests pass, and archive payload bytes match the pre-optimization
contract.

## Phase 5: Add a Non-Mutating Skia Source Fast Path

Keep `core.sources` always assessed so tracked modifications cannot hide behind
a stamp. For each Skia external, read the configured origin, current commit,
and tracked status first. Return immediately when all three match. Run those
independent read-only validations with bounded concurrency. Execute remote
repair, fetch, and detached checkout only for a checkout that is absent or does
not match, then perform the complete post-mutation validation.

Gate: the unchanged package graph does not run a checkout command for an exact
Skia external, tracked modifications still fail before mutation, missing
objects are acquired only by the host action, and the repaired checkout is
exactly the pinned commit and remote.

## Phase 6: Narrow Collider Rebuild and Test Closures

Move Linux package assembly and qualification contracts into a focused SwiftPM
target consumed by the two Linux helper executables and by
`LinuxColliderRecipe`. Keep graph construction in the recipe target. Changes to
unrelated Linux, Chromium, Shell, or workspace command code no longer rebuild a
helper unless its imported contract actually changed.

Separate immutable catalog input loading from component graph composition.
Collider workspace tests share a thread-safe fixture input snapshot for the
same repository root, environment, and host augmentation, while tests that
exercise relocation or augmentation continue to use explicit inputs. Every
assertion remains behavioral; no test inspects source shape.

Gate: dependency inspection proves the narrowed helper closure, touching an
unrelated recipe source leaves the helper build clean, and the complete
Collider suite passes with one fixture input load per distinct test context.

## Phase 7: Close the Throughput Qualification

Run the complete Collider suite, the dual-architecture native package and
lifecycle graph from changed inputs, an immediately unchanged package graph,
product-store retention, and cache-prune dry-run. Compare stage observations to
the Phase 1 baselines and retain only changes that reduce measured work without
changing package identity or qualification semantics.

Gate: both architectures assemble concurrently within the declared host budget,
payload copying is single-materialization, the unchanged graph performs no
source mutation, the product store retains exactly the active and rollback
cohorts, and every correctness gate passes.
