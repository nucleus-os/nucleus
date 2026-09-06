# Build consumption identity

Status: active

## Invariant

A task is identified by its own semantic configuration and the content of the
artifacts it consumes. The recipe that produced an artifact is not a substitute
for that content. Ordering and package preparation establish execution
readiness; they do not make unrelated source or manifest declarations semantic
inputs. Swift product and test requirements declare their own compilation
artifacts; a consuming action's packaging inputs never become compiler inputs.
A consumer waits for its producers before its final cache assessment.
An unchanged published artifact stops invalidation at that boundary.

## Phase 1: Resolve SwiftPM semantics at the selected target closure

Status: active

Retain the full evaluated package configuration and the full evaluated target
and product declarations. Fingerprint package-wide build settings and only the
targets and products reachable from the selection. Keep raw manifests as graph
resolution and materialization inputs. Keep package source mounts and copied
root manifests as preparation, with explicit ordering edges. They do not enter
a selected product's semantic identity merely because SwiftPM can see them.

Persist raw evaluated manifests and reapply semantic projection on every graph
cache read. Package-location metadata is excluded; inferred snippet targets
use their resolved declarations. CI compiled the implementation and identified
both boundaries during catalog planning; their regression gates are included.

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

Status: active

Protected-main run `34041675293` reported the expanded dependency cycle instead
of crashing: AOSP image assembly requires a signing identity, which requires
the Android assembler compiler task, which incorrectly consumed the AOSP image
from another owner of that same product. The [CI diagnostic artifact contract](ci-diagnostic-artifacts-contract.md)
provides independent, bounded collection of run records and crash evidence.

Execution startup now records separate durable phases for loading task state,
loading the artifact digest index, and validating/prioritizing the expanded
execution graph. Owner-completion edges are included in graph validation, and
priority calculation uses the resulting topological order instead of unchecked
recursion. A regression fixture makes an acyclic declaration graph cyclic only
after lowering and requires a concrete cycle error. CI verified that the
scheduler-safety correction exposes the cycle as a normal diagnostic.

SwiftPM lowering now consumes only invocation inputs and explicit compilation
artifacts, with preparation and dependency resolution as ordering prerequisites.
It never walks owner dependencies to guess compiler prerequisites or suppress
cycles. Recipes supply native SDK artifacts to runtime compilation while
assembler tools remain independent of payloads. Android package declarations
follow native SDK preparation so they carry the complete compilation contract.
A regression models shared signing-tool compilation, signed-image production,
and packaging and validates their expanded graph. Full CI verification of this
correction remains pending.

Verify the full catalog with the new identity model, including the reservation
tests and both architectures' package cohorts. Record the one-time identity
transition separately from steady-state invalidation. Exercise an unrelated
target declaration and an unchanged producer output through behavior tests.
Re-audit the nightly finalization plan against these contracts before continuing
its next increment.
