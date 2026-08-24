# Container Mount Scope Plan

Status: active

## Invariant

A container sees what its task declares and nothing else. No execution mounts
the checkout root to reach a subtree of it, so what a container may read is a
statement about that task rather than a property of where it happens to run.

## Current State

Every Swift build that executes in a container mounts the whole checkout:

```swift
OCIMount(source: root, target: placement.executionPath(root), access: .readOnly)
```

That tree holds 696,026 files. Two thirds of them cannot be inputs to any Swift
build:

| tree | files | why a product build never reads it |
| --- | --- | --- |
| `.build` directories | 234,135 | host SwiftPM output; containers build into `/swiftpm-workspace` |
| `swift-sdk/source` | 235,115 | the Swift toolchain source closure, built only by the target-SDK graph |
| everything else | 226,776 | the package graph, its submodules, and device trees |

The cost is host file descriptors. Collider caps container executions at two,
and with two running the host open-file table climbs from a 9,589 baseline to
436,059 against a `kern.maxfiles` of 491,520. `collider package linux-runtime`
failed twice with `Too many open files in system`, a host-side `ENFILE` rather
than anything the container reports.

The climb is a ramp rather than a step. Descriptors reach 436,000 within
twenty-five seconds of the first two containers starting, then oscillate as
reclamation runs against continued growth.

Containers are not the only consumer of this magnitude, and measuring one
without isolating the other is how this was first misread. A host Swift Build
of the `collider` package reaches 329,639 descriptors on its own, with no
container and no task graph. The two accounts keep separate build stores, so a
Collider source change rebuilds that package twice — once for the interactive
account and once for the builder, the latter peaking at 423,810. Those spikes
are serial with the task graph rather than concurrent with it, but each alone
is most of the table.

The AOSP lane is the contrast that isolates the cause. Its containers mount
source and output as persistent workspace volumes and reach the host only for a
bounded Git object cache, and a seven-hour two-product build never approached
the limit. A volume is a filesystem the guest kernel drives; a bind-mounted host
directory is one the host shares file by file. Only the second kind is paid for
in host descriptors.

## Phase 1: Establish What the Exposure Costs

The two trees above stop being exposed to Swift builds, and the host open-file
table is sampled across an identical build before and after.

They are first because they are the largest, because neither can be an input —
one is output, the other belongs to a different graph — and because removing
them is the measurement. If descriptor use falls in proportion to the files no
longer exposed, cost follows exposure and the remaining phases are worth their
scope. If it does not, cost follows access, and this plan stops here with that
recorded.

Gate: an identical `collider package linux-runtime` run reports peak host open
files before and after, the exposed file count falls from 696,026 to about
226,776, and the run reaches container execution without exhausting the table.

A mount is encoded in the execution's identity, so narrowing one invalidates
the tasks that carry it. That is correct: what a container may read is part of
what it is. The gate is that identities change once and the outputs they
produce do not.

Status: complete. The two trees are covered by an empty directory mounted over
them, because the package root is the checkout root and neither can be excluded
by mounting something narrower.

Gate evidence: peak host open files across a full `collider package
linux-runtime` run fell from 436,059 to 77,920, sixteen percent of the limit,
against a sixty-seven percent reduction in exposed files. Cost follows
exposure. No run since has reported `ENFILE`, and the run reached eighteen
tasks where the unmasked runs failed at five and seven.

The first measurement of this phase reported no reduction and was wrong. It
sampled a run that never reached the task graph, spending its whole window in
the host Swift Build described above. A second measurement made the same
mistake against the builder account's copy of that build. Both are why the
current state now names that consumer: an experiment that cannot tell its
intervention from its confound reports the confound.

## Phase 2: Mount What the Task Declares

A container execution composes its mounts from the task's declared inputs and
effect scopes rather than from the checkout root. A task naming
`.sourceCheckout(core/third-party/skia)` mounts that tree; a task naming a
package root mounts the packages its resolved source graph names.
`SwiftPackageGraphResolver` already computes that graph, so the set is derived
rather than authored.

An action that declares an unrestricted read scope keeps the checkout mount and
records why, because a mount narrower than the declaration would be a
correctness change rather than a scope change.

Gate: no OCI execution names the checkout root as a mount source unless its
action declares an unrestricted read scope, and the complete packaging graph
produces byte-identical task identities.

## Phase 3: Revalidate the Source a Run Consumed

A run detects that its source changed underneath it by capturing the whole
repository, because `ProductArtifactSourceSnapshot.capture` defaults its
`sourcePaths` to the repository root and the command layer passes nothing else.
Editing a document therefore supersedes a build that no document can affect: a
fifteen-line change to a plan file ended a packaging run that had been
executing for a minute, and would have ended one that had been executing for
hours.

Revalidation names the source closure the plan consumed, which the graph
already declares through `.sourceCheckout` inputs, so a run is superseded by a
change to something it read rather than by a change to anything in the
checkout. The parameter for this exists and is unused.

Gate: editing a path no task declares does not supersede a running build, and
editing a path a running task declares still does.

## Phase 4: Hold the Boundary

A container execution that mounts a tree no declaration names fails to
construct. The property is structural: a mount set derived from declarations
cannot drift from them, and an execution that wants more has to say so.

Gate: constructing an execution whose mounts exceed its declared scopes is a
failure with a test that exercises it.

## Risk Surface

The load-bearing unknown is whether host descriptor cost follows exposed files
or accessed files. The ramp shape and the AOSP contrast both point at exposure,
and 400,000 descriptors is far more than two Swift builds plausibly open by
hand, but neither is proof. Phase 1 is arranged so that the first change
answers the question and banks the largest win at the same time, and so that a
negative answer costs one phase rather than three.

Raising `kern.maxfiles` would clear the immediate failure without touching what
causes it, and would have to be raised again as the checkout grows. It stays
available as an unblock and is not a substitute for this plan; whether it
remains necessary is answered by the Phase 1 measurement.

Narrowing what a container may read is a containment property as well as a
resource one. A Swift build that cannot see the Swift toolchain source or
another product's build output is a smaller thing to reason about, which is why
Phase 3 makes the boundary structural rather than conventional.
