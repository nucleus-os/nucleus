# Build consumption identity

Status: complete.

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

Status: complete.

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

Gate evidence: the manifest identity behavior tests run in
`ColliderWorkspaceCommandsTests`, which every protected-main sweep has
executed, and [run 34076288592](https://github.com/nucleus-os/nucleus/actions/runs/34076288592)
records `manifestPackageLocationDoesNotEnterSemanticIdentity`,
`evaluatedManifestIdentitySeparatesSelectedDeclarationsAndPreservesUnknownSettings`,
`inferredSnippetTargetsUseResolvedConfigurationAndMissingDeclaredTargetsFailClosed`,
and `duplicateManifestDeclarationsAreRejected` among its results. Adding an
unrelated target or changing manifest formatting preserves an existing product
identity; changing a selected target's settings, resources, dependency
closure, product type, or package-wide compiler configuration changes it, and
preparation still completes before every invocation that needs it.

## Phase 2: Assess consumers from completed artifact content

Status: complete.

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
missing-output restoration, and explicit rebuilds.

Gate evidence: those tests live in the nested `collider/engine` package, and
that package's test target did not compile and had never executed in any
retained run log until `58d1bb1e` and `9858a62c`. The evidence was not pending
on the behavior; it was pending on a target no sweep could run.
[Run 34076288592](https://github.com/nucleus-os/nucleus/actions/runs/34076288592)
is the fourth consecutive sweep to execute it, and records
`coldConsumersDeferWithoutReadingUnproducedArtifacts`,
`artifactConsumptionStopsAtUnchangedBytesAndPropagatesChangedBytes`,
`missingCurrentOCIImageInvalidatesRecordedTaskOutput`,
`outputContractChangesInvalidatePriorTaskState`, and
`taskEngineExplainsInvalidationAndThenSkipsCleanWork`.

The same run's manifest shows the model working at catalog scale rather than
only in fixtures: 79 tasks recorded `consumed artifact content and outputs are
current`, 37 recorded `execution required after artifact assessment`, and 29
were clean without needing one. A changed producer that republishes identical
bytes did not execute its consumer, seventy-nine times.

One clause of the gate was not met and is now. `TaskPlanEntry.assessed`
forwarded `recipeIdentity` and `isForced` but dropped `isDeferred`, two lines
after the engine read that same flag to choose the explanation. Every deferred
task therefore recorded `isDeferred: false`, so a record kept what the
assessment concluded but not that it had waited for a producer -- which is the
one thing separating a consumer judged against completed content from one
judged against whatever was on disk when planning ran. Assessment answers a
deferral; it does not undo one.

[Run 34079734763](https://github.com/nucleus-os/nucleus/actions/runs/34079734763)
carries the correction and partitions cleanly: 119 tasks recorded a deferred
assessment, 60 of them reusing after it and 59 executing after it, and the 39
that recorded none carry only explanations that describe work needing no
producer wait. No deferred task carries a non-assessment explanation and no
undeferred task carries an assessment one, so the three states the gate asks
for are distinguishable in the record rather than merely present in it.

## Phase 3: Prove the protected-main boundary and resume nightly finalization

Status: complete.

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
and packaging and validates their expanded graph. Run `34043448530` passed
expanded-graph validation and executed 89 tasks before Android package assembly
reported an unavailable AppArmor policy. Packaging now explicitly mounts its
authored policy directories read-only, independent of SwiftPM preparation
mounts. Regression coverage includes shared and separate policy directories.
Full catalog verification remains pending.

Run `34047619404` then exposed a runtime-publication filesystem contract error:
its working directory still named the excluded checkout. Publication now runs
in its bounded artifact export and explicitly mounts its session-package input
read-only. Regression coverage checks both paths without a whole-checkout mount;
the other packaging actions already use their bounded exports as working
directories. The full catalog remains the acceptance gate.

Gate evidence: [protected-main run 34164726541](https://github.com/nucleus-os/nucleus/actions/runs/34164726541)
verified the full catalog with the new identity model -- 121 clean, 39
executed, 0 failed -- including `reservationRequestCannotChangeItsBinding` and
`reservationsSurviveReopeningAndRetryAcrossMidnight`, and both architectures'
package cohorts and lifecycle qualifications. The two behavior tests this phase
asks for ran on the builder account in the same sweep:
`semanticProductInputsExcludeUnrelatedDeclarationsButIncludeSelectedConfiguration`
for an unrelated target declaration, and
`artifactConsumptionStopsAtUnchangedBytesAndPropagatesChangedBytes` for an
unchanged producer output.

The one-time transition separates from steady-state invalidation because two
consecutive sweeps show them side by side.
[Run 34155852540](https://github.com/nucleus-os/nucleus/actions/runs/34155852540)
reported 41 clean and 118 executed: adding a field to `OCIExecution`'s identity
encoding changed what a container execution is, so every container task
re-derived its identity. That is the shape of a change to the model, and it is
paid once. Run 34164726541 reported 121 clean and 39 executed for a change of
comparable size to how Chromium receives its source, and the 39 are wholly
accounted for -- the tasks whose own configuration changed (four builds, four
artifact assemblies, one new image task), what consumes their outputs (both
product publications), and the tasks declared to run every time. Nothing in the
Linux runtime, the Swift SDK, Android, the compositor, or the shell re-ran.
Invalidation was proportional to the change rather than to the tool, which is
the property the model exists to provide and the one a blanket tool-revision
key would destroy.

Re-audit of nightly finalization: the contracts it rests on are held. A
consumer is keyed by the content of what it consumes, assessment is deferred
until its producers complete, and packaging inputs never become compiler
inputs, so "repackage only the exact qualified payload trees" and "do not
compile source or substitute an input" rest on enforced behavior rather than on
convention. The plan names build consumption identity as the prerequisite to
its next increment; that is now satisfied, and it is not the only one. Its own
gate requires that independently repeated assembly over the same reservation,
package set, and signing inputs produce the same release index and repository
contents, and that determinism is the placement-independent plan's outstanding
evidence rather than this plan's. The next increment is unblocked with respect
to identity and still gated on reproduction.
