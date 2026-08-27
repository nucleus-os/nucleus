# Build Store Retention Plan

Status: active

## Invariant

Every byte the build store retains is reachable from a declared identity or is
collectable by a declared policy. A retention policy states what bounds a root's
growth, and a collection path finds what it collects from the declaration rather
than by scanning a guessed depth. A root that no policy bounds does not exist,
and a collection that locates nothing under a policy that promises collection is
a failure rather than an empty result.

## Current State

The store holds 1.4 TiB against a 1.8 TiB disk: declared roots 485.1 GiB,
48 persistent workspaces 511.9 GiB of 4.3 TiB logical, and the container store
467.2 GiB. Returning every workspace's freed blocks to the host recovers
37.2 GiB, and an explicit prune selects 54.4 GiB. Neither reaches the two
largest accumulations, because neither is expressible as a thing to collect.

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

Status: active, and deliberately not wired. The bound and its retention order
are implemented and tested, and nothing calls them, because reachability is
computed from one checkout while the build store is shared with another. Each
checkout's host build contexts are permanently unreachable to the other: a
prune from the authoritative checkout selects the contexts a protected-main CI
run used minutes earlier, and that run spent thirty-two minutes in one task
rebuilding what a previous prune had taken. A per-run bound turns that from
something an operator chooses into what every build does, in both directions.

The divergence itself belongs to the
[placement-independent build plan](placement-independent-build-plan.md), whose
Phase 1 records it, and its cause is not yet established: either lowered SwiftPM
identities still divide on checkout, or the reachable set does not enumerate
the lowered tasks it should, which would be this plan's defect rather than that
one's. This phase completes when a bound cannot evict a context another checkout
sharing the store still reaches.

## Phase 5: Collect Orphaned Image Content, and Name the Images That Stay

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
base images are never selected; the complete build and packaging graphs then
execute without rebuilding a retained image or re-pulling a base.

Status: active. Collection is separated from deletion and runs unconditionally,
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

One gate clause is outstanding: that the complete build and packaging graphs
execute after a prune without rebuilding a retained image or re-pulling a base.
That requires a prune that actually collects, which has not yet run.

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

Gate: `collider cache reclaim --dry-run`, `collider cache prune --dry-run`, and
`collider cache status` report complete results from the interactive account,
including orphaned workspaces, image classification, and the allocation
collection would return; all three report what the builder identity reports;
none starts a container; the group-readability every one of these reads depends
on is asserted by provisioning rather than assumed.

## Phase 7: Declare Residency for Materialized Source

Every materialized source tree states whether it stays resident between builds
or is reconstructed on demand. AOSP's host source-input cache exists to
materialize the guest workspace and is reconstructible from the locked manifest,
so it is a residency decision rather than a permanent cost.

A tree declared on-demand is collectable when the store is under pressure and is
rebuilt by the task that needs it. A tree declared resident states why, so the
largest multiplier on the store's size is a recorded decision rather than a
consequence of what was built last.

Gate: every materialized source root declares its residency; deleting an
on-demand root and building the task that consumes it reproduces the identical
workspace; a resident root records the reason it is resident.

## Phase 8: Record Allocation Rather Than Walking For It

Allocation is currently answered by recursively measuring 1.4 TiB, which is why
it is behind a flag and off by default, and why the store's total is invisible
in the ordinary report. A producer knows what it wrote, so allocation is
recorded as roots change and the report reads that record.

The recursive measurement remains as the way to verify the record, not as the
way to answer the question.

Gate: `collider cache status` reports every root's allocation and the store's
total against the physical disk without a flag; `--measure-allocations` produces
the same totals within the tolerance of concurrent writes.
