# Build consumption identity

Status: active

## Invariant

A task is identified by its own semantic configuration and the content of the
artifacts it consumes. The recipe that produced an artifact is not a substitute
for that content. Ordering and package preparation establish execution
readiness; they do not make unrelated source or manifest declarations semantic
inputs. A consumer waits for its producers before its final cache assessment.
An unchanged published artifact stops invalidation at that boundary.

## Phase 1: Resolve SwiftPM semantics at the selected target closure

Status: active

Retain the full evaluated package configuration and the full evaluated target
and product declarations. Fingerprint package-wide build settings and only the
targets and products reachable from the selection. Keep raw manifests as graph
resolution and materialization inputs. Keep package source mounts and copied
root manifests as preparation, with explicit ordering edges. They do not enter
a selected product's semantic identity merely because SwiftPM can see them.

Gate: adding an unrelated target or changing manifest formatting preserves an
existing product identity. Changing a selected target's settings, resources,
dependency closure, product type, or package-wide compiler configuration changes
it. Preparation still completes before every invocation that needs it.

## Phase 2: Assess consumers from completed artifact content

Status: active

Freeze each task's source and recipe identity during planning. Combine it with
the identities of the consumed artifact contents to form the execution cache
key. Defer assessment when a producer is pending; do not report that consumer
as a known rebuild. Reassess it after its producers complete and skip execution
when the resulting key and outputs are current. Keep explicit recipe
dependencies distinct from artifact consumption and pure ordering.

Gate: a changed producer that republishes identical bytes does not execute its
consumer; changed bytes do. Missing or corrupt outputs are never accepted.
Cold graphs, forced rebuilds, SwiftPM lowering, and failed producers preserve
the same dependency and validation guarantees. Run records distinguish deferred
assessment, reuse after assessment, and executed work.

Implementation covers content-based late assessment, conservative final-key
propagation for untyped edges, forced lowered work, and runtime OCI-image
validation. Retained run manifests receive a one-time in-place migration;
historical identities remain evidence, not replayable recipes. Source recipe
capture stays frozen while artifact hashing waits for producer completion.
Behavior tests cover cold deferral, equal-byte reuse, changed-byte propagation,
missing-output restoration, and explicit rebuilds. CI evidence remains pending.

## Phase 3: Prove the protected-main boundary and resume nightly finalization

Verify the full catalog with the new identity model, including the reservation
tests and both architectures' package cohorts. Record the one-time identity
transition separately from steady-state invalidation. Exercise an unrelated
target declaration and an unchanged producer output through behavior tests.
Re-audit the nightly finalization plan against these contracts before continuing
its next increment.
