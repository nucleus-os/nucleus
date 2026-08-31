# Build Store Retention Plan

Status: complete

## Invariant

Every byte the build store retains is reachable from a declared identity or is
collectable by a declared policy. A retention policy states what bounds a root's
growth, and a collection path finds what it collects from the declaration rather
than by scanning a guessed depth. A root that no policy bounds does not exist,
and a collection that locates nothing under a policy that promises collection is
a failure rather than an empty result.

## Current State

Phases 1 through 5 have run, and the figures below are what they left. The
store now holds 575.4 GiB: 48 persistent workspaces at 424.0 GiB of 4.5 TiB
logical, and the container store at 151.4 GiB. The state this section originally
described -- 1.4 TiB, with 156.6 GiB in one misdeclared root and 436.6 GiB of
unreachable image content -- is the state those phases removed.

The accumulation they did not remove is 78.3 GiB of image content nothing
reaches: 20.5 GiB across 116 blobs and 57.8 GiB across 11 unpacked filesystems,
against 20 snapshots and 213 blobs in total. It is collectable, and until Phase 6
no inspection run from the interactive account could see or report it.

Two roots hold one context per SwiftPM task identity while declaring
`singleWorkingSet`, whose contract is that the producer replaces one working set
in place:

| root | allocation | contexts |
| --- | --- | --- |
| `swiftpm-host-boundaries` | 156.6 GiB | 135 |
| `swiftpm-tool-host-boundaries` | 20.2 GiB | 35 |

Each context is a SwiftPM scratch directory of five to eight gigabytes, and
every identity-changing edit mints another. The oldest predates the newest by
two weeks. `pruneTargets` collects `taskIdentityContexts` and throws for
`singleWorkingSet`, so no prune reaches these roots at all.

Correcting the policy alone collects nothing. `obsoleteTaskIdentityContexts`
walks exactly two directory levels. `host-swiftpm-builds` nests its contexts as
`unsanitized/sha256-…`, which that walk reaches; the boundary roots nest them as
`linux-arm64/unsanitized/sha256-…`, one level deeper, which it does not. The
walk would report no obsolete contexts and succeed. Depth is the defect, and
silence is what makes it dangerous.

Thirty-nine of eighty-six declarations are `singleWorkingSet` against one
`taskIdentityContexts`. Two of the thirty-nine are misdeclared; the rest hold
one working set as they claim. The imbalance is that the policy meaning "this
never grows" is also the policy applied when growth was never considered.

The container store reports 454.4 GiB of images, of which 436.6 GiB are
runtime-unattached, against four active and two retained images, seven unknown,
and zero reclaimable. That figure is not held by images. It is `content` plus
`snapshots`, and reading both directly off the store shows 57 of 69 unpacked
filesystems and 614 of 720 blobs reachable from no live image: roughly 300 GiB
and 104 GiB respectively. The runtime already collects exactly that, through
`cleanUpOrphanedBlobs`, which keeps one snapshot per live image manifest and
sweeps the rest. Collider reaches that call only inside image deletion, and
deletes only images classified reclaimable, of which there have been none. The
largest accumulation in the store is held open by a conditional rather than by a
missing policy.

Classification is separately wrong in the dangerous direction. Of the seven
images no declaration names, three are live: the init image every container
boots, the builder shim every image build runs, and the digest-pinned base of
all four Containerfiles. `unknown` is what currently protects them, and the
runtime's own deletion path refuses them by name.

AOSP exists three times: a host source-input cache of 73.4 GiB, a materialized
guest source workspace of 106.5 GiB, and an output workspace of 142.7 GiB. That
is the design working — containers require case-sensitive source materialized
offline — but no residency decision states which of the three stays resident
between builds.

Reclamation cannot be previewed from the account that owns the checkout.
`collider cache reclaim --dry-run` fails with `failed to list containers`
because listing requires the container service, which runs in the builder's
launchd domain, and `collider cache prune` reports orphaned workspaces as not
evaluated for the same reason. The operations work; their previews do not.

The same gap reached the image store silently, because the prune result had
nowhere to carry the failure: an unreadable store rendered as no images rather
than as an unanswered question, which is how a store this size stayed invisible
to every inspection run from the developer account.

## Phase 1: Locate Contexts From the Declaration

A storage declaration that retains identity contexts states where those contexts
live relative to its root. Collection resolves that statement instead of walking
a fixed number of levels, so a root whose contexts sit under a target and
sanitizer prefix is reached by the same code that reaches one whose contexts sit
directly beneath it.

Discovery that finds no contexts under a context-retaining policy fails. A root
declaring that it retains contexts and containing none is either misdeclared or
newly created, and both are worth an error rather than a successful report that
nothing needs collecting.

Gate: a context root at any declared nesting reports exactly its contexts; a
declared context location matching nothing fails with the root that declared it;
`host-swiftpm-builds` selects the same targets it selects today.

Status: complete. `taskIdentityContexts` carries a `ContextLocation` stating the
levels between a root and its contexts and the name a context carries, and
collection descends exactly that far. An empty result is proved rather than
assumed: a root yielding no contexts at its declared location is searched for
contexts at any other, and one found there fails with both depths and an
example. Gate evidence: run `2026-08-26T04-56-17.832Z-60857`, in which
`repositoryPruneRejectsContextsNestedDeeperThanDeclared` places a context two
levels below a root declaring one and requires the failure, and
`repositoryPruneRetainsOnlyCurrentSwiftPMTaskIdentityContexts` selects the same
targets it selected before the location became explicit.

## Phase 2: Collect Every Target a Failure Does Not Touch

Collection removes each selected target independently. One target it cannot
remove is reported and the rest are collected, and the command exits non-zero
having said exactly what it could not do. Aborting the sequence makes a single
unremovable target a permanent hold on the whole store: at present one stale
Swift SDK generation stops collection before it reaches 212.5 GiB of correctly
selected storage, every run, forever.

A removal failure names the path that actually failed rather than the target
that contained it. `FileManager` reports the item the caller asked to remove,
so a tree of thirteen thousand entries yields one error naming the root and
nothing about which descendant refused, which is not enough to diagnose from.
Removal descends explicitly and reports the failing path, its mode, and its
owner.

Gate: a prune whose selection includes an unremovable target collects every
other selected target, exits non-zero, and names the failing path with the
reason; a prune with no unremovable target exits zero; the cause of the current
`swift-target-sdks/generations` failure is stated from that diagnostic rather
than inferred.

Status: complete. Isolation, the diagnostic, and the cause are in place.
Removal now takes each target independently, descends on failure to
remove every entry that will go, and reports the entries that refused. A prune
that previously stopped at one stale Swift SDK generation now collects the rest:
165 GiB recovered, and the three affected generations fell from 13,158 entries
each to 22.

The cause is an access-control entry that travelled with copied bytes. The
builder must never write the authoritative checkout, so provisioning places an
inheritable entry on the checkout root denying `nucleus-builder` write, delete,
and attribute changes. Every file under the checkout inherits it, including the
first-party pkg-config files in `swift-sdk/pkgconfig`. Staging copies those into
the Swift SDK artifact bundle with `ditto`, which preserves access control
lists, so the staged copies arrive in the build store still denying the builder
delete. The builder then cannot collect its own staged copy, in every generation
that holds a staged Linux SDK, on both architectures, and only for those four
files -- their upstream siblings come from the downloaded sysroot, carry no
entry, and remove normally.

Mode bits are what made this hard to see: the staged file is mode 644 owned by
the builder inside a directory mode 755 owned by the builder, and a deny entry
overrides all of it. `rm` reveals it by prompting to override a file it
considers unwritable, which is the same `access` result the removal gets.

Staging therefore copies without access control. What a file may do is a
property of where it now lives, not of where it was read from, so no copy into
the build store carries the checkout's entries with it.

Gate evidence: the refusing entry is named by the diagnostic rather than
inferred, and its entry is `user:nucleus-builder deny
write,delete,append,writeattr,writeextattr,writesecurity,chown` against a
removable sibling carrying none. Generations staged before this change retain
the entry and are cleared once.

## Phase 3: Declare the SwiftPM Boundary Roots as Identity Contexts

`swiftpm-host-boundaries` and `swiftpm-tool-host-boundaries` become
`taskIdentityContexts` and state their nesting under Phase 1. Their 170 contexts
become classifiable, and a prune selects those no current task identity reaches.

The active set is computed the way it already is for `host-swiftpm-builds`: from
every task's Swift product and test invocation scratch path. A context reachable
from a current identity is retained regardless of age, so collection never
removes state a planned task would reuse.

Gate: both roots report their contexts; a prune immediately after a complete
build selects only contexts no task identity reaches; the build that follows
that prune re-executes exactly the tasks whose contexts it removed and no
others.

Status: complete. Both roots declare `taskIdentityContexts` at the two
intermediate levels their layouts use, `linux-arm64/unsanitized/sha256-…` and
`runtime-assembler/unsanitized/sha256-…`. Task-identity retention accepts cache
storage alongside incremental storage, because retention states how entries are
keyed while the class states what the bytes are: the build output under an
identity is incremental and the dependency closure it compiled against is a
cache under the same identity.

Gate evidence: prune selection rose from 81 targets and 54.4 GiB to 248 targets
and 212.5 GiB, and was identical before and after a complete build. Collection
took `swiftpm-host-boundaries` from 135 contexts to the 3 a current identity
reaches and `swiftpm-tool-host-boundaries` from 35 to none, all 35 belonging to
assembler identities that the container mount scope work superseded. The build
that followed reported 32 clean and 3 executed against 32 clean and 3 executed
before the prune, the three being tasks declared to run every time, so no
removed context cost a re-execution.

## Phase 4: Bound Context Count Without an Explicit Prune

Collection after the fact leaves the ceiling set by how often someone prunes.
A context costs five to eight gigabytes and an ordinary day of identity-changing
work mints several, so the bound belongs in the policy rather than in an
operator's habit. Identity-context retention carries a retained count, and a run
brings each context root within it before executing.

The bound is applied where both halves of the answer are already known. Planning
resolves every task's scratch path, which is how the reachable set is computed
today, and the storage declarations carry the count. The action that creates a
context knows neither: it sees one scratch path and no catalog, so locating the
bound there would thread component storage through the action layer to answer a
question planning has already answered. Enforcement therefore runs once per run
against the same collection the earlier phases made correct.

A root is brought within its bound per run rather than per context, so one run
minting several contexts can exceed the count until the next begins. That is the
right trade: the growth this bounds accumulates across weeks, not within a run,
and an eviction racing a build that is still using its scratch directory would
be a far worse failure than a temporary overshoot.

Retention is by reachability first and recency second: contexts a current
identity reaches are never candidates, and the bound applies to the remainder.
This keeps a bounded root from evicting state the next build would have reused.

Gate: a sequence of identity-changing builds without an explicit prune leaves
each context root at or below its declared count; no build in the sequence
re-executes a task whose context a previous build in the sequence created and
the bound did not evict; a run whose reachable contexts alone exceed the count
evicts none of them.

Status: complete. A run brings each context root within its declared count
before executing, so the ceiling is the policy rather than how often someone
prunes.

Wiring it waited on the divergence that made it unsafe. Two checkouts sharing
the store lowered one revision to two identities, so each checkout's contexts
were permanently unreachable to the other and a per-run bound would have had
them evict each other on every build. That belonged to the
[placement-independent build plan](placement-independent-build-plan.md), whose
Phase 1 found and fixed it: the placement-mapping flags were emitted in the
order the identity path map sorts its roots, which is a property of path
lengths and therefore of where a checkout sits. The values had always
canonicalized; the sequence had not.

Gate evidence: a protected-main run following the fix reused the authoritative
checkout's contexts rather than creating its own, leaving the two it had used
untouched and dead. Reachability outranks the count, so a context a planned task
will read is never a candidate however old it is, and the bound applies
newest-first to the remainder.

## Phase 5: Bring the Container Store Under Collection

Collection of unreferenced image content runs whenever the store is pruned,
independent of whether any image was selected for deletion. Content is orphaned
by rebuilding an image rather than by removing one: a rebuild replaces the
reference its layers and unpacked filesystem belonged to and leaves them
reachable from nothing. A store whose every image is current is therefore the
store with the most to collect, and is exactly the store a selection-gated
collection never reaches.

Classification then stops treating an unnameable image as collectable. An image
the component catalog cannot place is not thereby unreferenced: the runtime
requires its own init and builder images to boot a container and to build an
image at all, and every first-party image is built `FROM` a digest-pinned base
that the catalog names in a Containerfile rather than in a declaration.
Reachability is drawn from three sources -- the declared image families, the
container system configuration that names the two infrastructure images, and the
base each Containerfile pins. An image none of the three names remains
`unknown`, and `unknown` remains a refusal to collect, because the failure it
represents is a catalog that cannot account for what the store holds.

What that leaves collectable as a whole image is narrow and correct: superseded
generations beyond the declared rollback count, and superseded versions of the
infrastructure and base images, which the current configuration no longer names.
The bytes come from collection, not from deletion.

Gate: a prune that selects no image still collects orphaned content and reports
what it returned; a prune whose selection is empty because the store could not be
read says so instead of reporting an empty selection; the live init, builder, and
base images are never selected; a container record no execution owns is removed
while a running one and the runtime's builder are not; the complete build and
packaging graphs then execute without rebuilding a retained image or re-pulling
a base.

Status: complete. Collection is separated from deletion and runs unconditionally,
and an unreadable image store is reported rather than rendered as nothing to do.
`deleteImages` no longer performs collection as a side effect; `prune` deletes
what it selected, then collects, and reports the two separately. A plan states
that collection runs and states no size, because what it would return is a
property of the runtime's reachability over content this command does not
enumerate -- which Phase 6 changes.

Classification now draws on all three sources. The runtime reports the builder
and init images its configuration names, keyed by repository so a store holding
several versions can be told which one is current; the base each declared
Containerfile pins is matched by digest, because a pull stores a digest-pinned
base under repository and digest and drops the tag the `FROM` line carried. An
image in a repository one of the three names, at a version none of them selects,
is superseded rather than unaccountable, which is what makes the previous
runtime versions and the previous base collectable while the current ones are
never candidates. An image no source names remains `unknown`, is never
collected, and is now listed by reference in the status report.

Container records are collected on the same pass, before images, because a
record names an image and holds it against collection for as long as it exists.
Collider deletes its own container on completion, cancellation, and failure
alike, so a record that is not running belongs to an execution none of those
paths reached; it holds an unpacked root filesystem and nothing reclaims it. The
runtime's own builder container is excluded, because the runtime creates it and
the next image build expects it. A record that is merely recorded also stops
counting as an image's active reference: treating a stopped container as active
is what let one abandoned record pin its image permanently.

Gate evidence: the first prune to reach collection returned 411.9 GiB, of which
407.1 GiB was image content no live image reached, against a predicted 404 GiB
from reading the store directly. The content store fell from 116 GiB across 720
blobs to 12 GiB across 88, and unpacked snapshots from 339 GiB across 70
directories to 36 GiB across 9. Exactly four images were selected, all
superseded: one base and three previous runtime versions. The nine that remain
are the live set, including the init image, the builder shim, and the pinned
base that the phase's earlier premise would have deleted. The abandoned
container record went with them, returning a further 13 GiB. The build graph
then executed against that store with `native.builder-dependencies` reporting
`localClean` and no image rebuilt or base re-pulled.

The packaging graph then ran against the same store with both image families
reporting `localClean`, `browser.builder-dependencies` alongside
`native.builder-dependencies`, so the Chromium family's retention is established
by a graph that consumed it rather than argued from its classification.

## Phase 6: Answer Inspection From the Store, Not the Service

Inspection stays in the invoking account, and an inspection that cannot answer
from that account is not inspection. Workspace enumeration, reclamation preview,
and image classification all read state the container service holds, which the
developer account cannot reach.

Every one of those answers is already on disk, under the build store, readable by
the group that owns it. Persistent workspace identity, capacity, and allocation
are in each volume's own entity record and image file. Whether a workspace is
active is in the mount list of each container record, which is the same fact the
service computes. The image store's references, index digests, manifests, and
unpacked filesystems are in its state record, blob store, and snapshot
directories. Collider reads these directly, and the service remains the only
thing that mutates any of them.

Reading them directly is also what lets a plan state a size. Once reachability
over blobs and snapshots is computed here, a dry run reports what collection
would return rather than reporting that collection runs.

Status: complete. Inspection and mutation are separate protocols now, because
they have separate requirements of the host rather than because they describe
separate stores: `OCIStoreInspection` reads volume entity records and their
sparse images, container configuration records, the image state record, the blob
store, and the snapshot directories, while the runtime backend keeps every
operation that writes. The three previews answer from the interactive account.
`cache status` reports 48 workspaces at 424.0 GiB where it reported `workspaces
unavailable without the container service`, and `prune --dry-run` states
`78.3 GiB collectable from orphaned image content` where it stated that
collection runs on execution.

One premise of this phase was wrong and the correction is the load-bearing part.
Whether a workspace is active is *not* in the mount list of each container
record: those records are configuration, they carry no status, and they outlive
the containers that wrote them -- the one on this host is four days older than
the last container that ran. Reading liveness out of a record's existence would
pin every workspace it mounted and every image it referenced against collection
permanently, which is the failure the runtime's own image listing already avoids
by asking which containers are *running*. Liveness is a property of the
machine's single execution admission instead: while that lease is free no
Collider container is running and every record is history, and while it is held
the records describe what is running now. The lease names the process holding
it, so the question is answered by asking whether that process exists, which is
a read -- probing the lock itself is not, because acquiring it even momentarily
can fail a concurrent non-blocking acquisition.

Gate: satisfied. `collider cache reclaim --dry-run`, `collider cache prune
--dry-run`, and `collider cache status` report complete results from the
interactive account, including orphaned workspaces, image classification, and
the allocation collection would return; none starts a container; the
group-readability they depend on is asserted by the builder doctor's build-store
prerequisite, which now requires the container application root to be readable
and traversable by the reading group.

## Phase 7: Declare Residency for Materialized Source

Every materialized source tree states whether it stays resident between builds
or is reconstructed on demand. AOSP's host source-input cache exists to
materialize the guest workspace and is reconstructible from the locked manifest,
so it is a residency decision rather than a permanent cost.

A tree declared on-demand is collectable when the store is under pressure and is
rebuilt by the task that needs it. A tree declared resident states why, so the
largest multiplier on the store's size is a recorded decision rather than a
consequence of what was built last.

Status: complete. `StorageResidency` is required of source storage and of any
persistent workspace whose role is source, and rejected everywhere else: a build
or compiler-cache workspace holds intermediates that are reconstructed by
definition, so a residency on one would be a decision about nothing.

The rule this replaces is the load-bearing part. Source storage was required to
be protected, which made "this is source" and "this can never be collected" the
same statement. They are not, and that conflation is why AOSP existed three
times with no decision behind any copy. Source now states which it is, and the
two answers carry the obligations that distinguish them: a resident tree must be
protected, and an on-demand tree must not be, or nothing may ever collect what
it promises to rebuild. An on-demand tree also names a task that actually
produces it, so "reconstructible" is checkable rather than asserted.

The four materialized trees now say what they are. AOSP's host source-input
cache is on demand, rebuilt by `android-runtime.aosp-source-inputs`; it was also
classed as a cache, which described how it is used rather than what it holds,
and left 73.4 GiB outside every decision about source. The AOSP guest workspace
is resident because that cache is the collectable half of the pair and
collecting both would start an Android build from a network hydration. The
Chromium source workspaces are resident for the opposite reason: there is no
second copy, so collecting one turns the next build into a full materialization.
Skia's materialization is resident because it is a submodule of the
authoritative checkout, which Collider materializes into but never owns.

Declaring the residency was not enough on its own, and the gap is worth
recording because the declaration read as true. AOSP's object store was declared
as scratch, so nothing validated it: deleting it left `aosp-source-inputs` clean,
and the materialization that mounts it read-only would have run against an empty
directory. Running this phase's gate as written would have destroyed 73.4 GiB
that nothing then rebuilt. The store is now a declared output of the task that
hydrates it, validated as a non-empty directory -- what it contains is already
established by the locked revisions, and digesting a tree that size to learn it
exists would cost more than the hydration it guards.

An on-demand root must therefore be covered by a declared output of its
reconstructing task. Two weaker readings were tried and rejected by the
codebase: checking only `outputs` made the rule vacuous, because a task states
outputs as slots through the builder call that also returns an artifact
reference; and accepting any output *under* the root let two small manifest
files vouch for the object store beside them. That second reading is why the
declaration is now rooted at the object store itself, with the lock and
provenance state declared separately -- one root could carry only one residency,
and these two answer differently.

Gate: every materialized source root declares its residency, a resident root
records why, and an on-demand root is observable as missing -- all enforced by
the catalog rather than by review, and confirmed by removing the output
declaration and watching catalog construction reject it. Outstanding: deleting
the on-demand root and rebuilding it is a 73.4 GiB re-hydration over host
networking and has not been run. It is now a safe thing to run.

## Phase 8: Record Allocation Rather Than Walking For It

Allocation is currently answered by recursively measuring 1.4 TiB, which is why
it is behind a flag and off by default, and why the store's total is invisible
in the ordinary report. A producer knows what it wrote, so allocation is
recorded as roots change and the report reads that record.

The recursive measurement remains as the way to verify the record, not as the
way to answer the question.

Status: complete. A record under the store holds what each declared root was
last measured to hold. The report reads it; the walk writes it. Merged rather
than replaced on each write, because a caller measures the roots it touched
rather than all of them -- a prune that collected from three roots knows three
numbers, and rewriting the file with only those would erase every other root's
last known allocation and send the next report back to walking the store. A
declaration the catalog drops is dropped from the record, so a removed root
stops contributing bytes nothing owns.

The record is written by the builder into the store and read by the group that
inspects it, which is the same boundary Phase 6 established: the account that
walks is the account that may write, and the account that asks is not.

Gate: satisfied. `collider cache status` reports every root's allocation and the
store's total with no flag -- `873.9 GiB accounted: declared roots 310.7 GiB ·
48 workspaces 424.6 GiB of 4.5 TiB logical · container store 138.6 GiB`, where
it previously reported `declared roots not measured; pass
--measure-allocations`. Reclaimable bytes stay with the measurement that
computes them, because what a prune would select is a property of now rather
than of when a root was last measured.

## Phase 9: Declare and Enforce Workspace Capacity

Every persistent workspace is a sparse image provisioned at a nominal size
chosen once: 100 GiB for most build roots, 300 GiB for the AOSP source and
output roots, 150 GiB for the Chromium outputs, 50 GiB for the SwiftPM overlay
and the AOSP compiler cache. Nothing states why a workspace has the size it has,
nothing reports how close it is to that size, and a workspace that reaches it
fails the task inside it with ENOSPC rather than with a statement about
capacity.

Allocation inside these images does not return to the host on its own, so a
workspace's cost to the host is its high-water mark rather than its live
contents. `core-skia-intermediates-linux-arm64-glibc-build` holds 0.3 GiB
against a 100.1 GiB image and `nucleus-swiftpm-linux-arm64-glibc-build` holds
97.5 GiB against the same size. Capacity is therefore stated against the mark,
and headroom is the number that predicts failure.

That workspace has already failed a protected-main sweep. The run verifying
`d13b57c1` stopped at 58 of 71 tasks with `No space left on device (28)` from
`mkdtemp`, and with `ld.lld` taking SIGBUS on an mmap'd output in the same
workspace, which is what a full filesystem looks like to a linker. The volume
measured 98.75 GiB of 100.12 GiB afterward.

Nothing had accumulated improperly. Phase 4 bounds context count, and it is
working. The sweep's own reachable set is simply larger than the volume.
Planning a full verification reports fourteen SwiftPM invocations, and eight of
them resolve against `linux-arm64-glibc`: one build and seven test products. The
remaining six are one x86_64 build and five that execute natively on the host.
Eight contexts against the ninety-eight gigabytes the workspace held is roughly
twelve gigabytes each, so this workspace was provisioned at exactly its own
working set with nothing left over. Phase 4 evicts by reachability first and
explicitly never evicts a context a planned task will read, so every one of
those eight is unevictable by design while the run that needs them is planned.
The bound cannot save a root whose single-operation working set does not fit.

The same split explains the sibling. `linux-x86-64-glibc` resolves one of the
fourteen rather than eight, and holds 23.1 GiB rather than 98.75, because that
lane builds without running the Linux test products.

Capacity is therefore sized against the reachable working set of the largest
single operation that mounts the workspace, and that operation is the
verification sweep. A nominal size below that number is not a budget, it is a
scheduled failure.

Raising a ceiling used to be unreachable. A declared capacity that disagreed
with the volume holding it was a configuration mismatch that refused the mount,
and no command could resolve it: `clean` removes a workspace only for the
component that is its sole consumer, and a shared one like `nucleus-swiftpm` is
excluded because cleaning it from one component would pull state from under the
others, while `prune` removes only workspaces no identity claims and this one is
claimed. The declaration was authoritative everywhere except where it mattered,
and the only resolution was deleting a volume by hand outside Collider.

Workspace shape now reconciles to its declaration. A persistent workspace holds
rebuildable intermediates by construction, so when the capacity, filesystem, or
driver options of the volume disagree with the declaration that claims it, the
volume is recreated to match and initialized like any freshly created one. This
is the same principle Phase 4 applied to context count: the ceiling belongs in
the policy rather than in how often an operator remembers to intervene.
Ownership is settled first and is never reconciled, so a volume whose name or
labels disagree still refuses rather than being destroyed by a declaration that
does not own it, and a workspace a running container holds refuses too rather
than having its filesystem pulled out from under a live build. Recreation
discards everything the workspace held, which is the declared outcome rather
than a surprise, so each one is reported on standard error.

Achieved state: each workspace declares its nominal capacity beside the role
that justifies it. A run reports allocation against capacity for every workspace
it mounts, and a workspace crossing its declared threshold fails the run naming
the workspace and its remaining headroom, rather than surfacing ENOSPC from
inside a container where the message describes a write instead of a store.
Enforcement reads what the builder already has and does not wait on Phase 6;
reporting the same headroom from the interactive account arrives with it.

Status: complete. Capacity is declared beside the role that justifies it, and
the threshold is one policy rather than a number repeated across forty-eight
declarations: four fifths of capacity, because what remains has to hold one more
operation rather than one more file. The sweep that filled this workspace was
writing roughly twelve gigabytes per SwiftPM context, so a ceiling reached at
ninety-five percent would have been reported for the first time by the failure
it exists to replace. Resolving a mount measures the workspace and refuses it
past that threshold, naming the workspace, its allocation, its capacity, and the
threshold, rather than letting the run reach ENOSPC inside a container where the
message describes a write.

The arm64 Linux SwiftPM workspace is below its threshold: 24.3 GiB allocated
against a 200 GiB ceiling, with 135.7 GiB of headroom. The reason it exceeded
its sibling is recorded beside the declaration rather than absorbed -- that lane
resolves eight SwiftPM contexts to the sibling's one, because it runs the Linux
test products and the sibling only builds.

Gate: satisfied. `collider cache status` reports capacity, allocation, and
headroom for every workspace; headroom is measured against the threshold
enforcement acts on rather than against a ceiling nothing may reach, so the
number a reader sees is the number that stops the run.
