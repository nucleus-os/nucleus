# Container Mount Scope Plan

Status: complete

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
`SwiftPackageSourceGraph` already computes that graph, so the set is derived
rather than authored, and the native compiler configuration returns the
vendored include roots its own flags point at, so a mount and the include path
naming it come from one list.

Phase 1 measured a graph that failed early. The complete packaging graph is
larger and runs heavier work concurrently, and it still reaches the ceiling: a
full `collider package linux-runtime` exhausted the host file table once, in an
AOSP compile running alongside Swift package builds, and a lighter incremental
run of the same command peaked at 282,966 of 491,520. Fifty-seven percent is
not headroom for a graph that grows, so this phase is required rather than
merely worthwhile.

An action that declares an unrestricted read scope keeps the checkout mount and
records why, because a mount narrower than the declaration would be a
correctness change rather than a scope change.

### The package root is a view

The gate previously read that no execution names the checkout root as a mount
source. That is unachievable additively and the reason is structural: a bind
mount source must be a directory, and `Package.swift` and `Package.resolved`
are files directly inside the package root, which for this package is the
checkout root. The root is therefore mounted as a *view* — a directory holding
copies of those files and an empty directory for every mount nested inside it —
so what the container sees at the package root is what the package declares.

The view carries those empty directories because the runtime does not create a
nested bind target its parent does not contain. A nested target absent from a
read-only parent fails with `EROFS`, and a writable parent is not an escape:
Collider permits overlapping mounts only when both are read-only. Both were
established by probe rather than assumed.

The view is produced by a task rather than materialized while planning.
Planning runs in the invoking account before a command re-runs itself as the
builder, and the build store belongs to the builder, so a planning-time
materialization fails in one account and leaves state the other cannot remove.
Both directions were observed.

One view serves every lane rather than one view per lane, because the Android
package-input assembly merges two lanes into a single container, where two
views claiming the same package-root target cannot both mount.

### Manifest target paths widen

Target paths from a manifest widen to two components below the root; every
other path is mounted as given. Widening a first-party source directory costs
56 files across the package and removes four fifths of the mounts, while
widening `third-party/gfxstream/host/common/include` would mount the whole
vendored tree.

Coalescing also separates a working test suite from a hanging one. A first
attempt mounting all 230 paths exactly spun for thirty minutes at 198% CPU
where the coalesced set completes in about five. Mount count is the only
variable that changed between the two, and the mechanism behind the spin was
never isolated — recorded here as the observation it is. An earlier draft of
this plan attributed the spin to resolving package graphs against roots
carrying no manifest. That explanation was wrong: the root in question resolves
to the real checkout and does have a manifest.

Gate: no OCI execution mounts a checkout subtree its task does not declare,
and the complete packaging graph produces the same outputs. Identities change
once, because a mount is part of what an execution is.

Status: complete.

Gate evidence: no mount source in the packaging plan is the checkout root, and
the only thing mounted at the package root is the view. Exposure is 11,773
files across 78 mounts, against 248,190 through a single mount. A complete
`collider package linux-runtime` executed all 83 tasks with none failing, and
peak host open files reached 51,977 of 491,520 -- ten percent, against
fifty-seven for a lighter run of the same command before this phase, and
eighty-nine for the runs that exhausted the table.

### What a container reads that a package graph does not name

Every failure after the derivation itself was a channel through which a
container reached the checkout without the package graph describing it, each
one previously satisfied by mounting everything.

Manifest build settings are absent from `swift package describe` entirely, so a
`headerSearchPath` escaping its own target -- `TracyBridge` reaching
`swift-tracy/third-party/tracy/public` -- named a directory nothing mounted.
The resolver reads the manifest dump for them now.

A staged native SDK links to source rather than copying it, and the link
records the path a container sees, so an include path under it names a checkout
directory while not being written as one. Those paths resolve through the link
table that creates them, for every SDK that stages such links: the render SDK's
two into Skia, and the React Native SDK's nine into Hermes, folly, glog, fmt,
fast_float, double-conversion, ReactCxxPlatform, and two first-party bridges.

An include path relates to those links three ways, and only naming one of them
is a link. A path under a link resolves through it. A path naming a link
resolves to that link's stated subtrees, which for Skia is what keeps its
199,180-file vendored checkout -- 186,748 of them a `third_party` tree -- from
being mounted to reach about four thousand. A path naming the directory the
links sit in reaches every one of them, because an include that resolves
through a link never names the link: `<folly/dynamic.h>` and
`<double-conversion/double-conversion.h>` are both read against the React
Native SDK's include root, and only folly is separately named by a flag.

`Package.resolved` records `apple/swift-system` while the manifest declares the
`nucleus-os` fork, and only `.swiftpm/configuration/mirrors.json` reconciles
them. A view built from manifests alone omitted it and a container resolved the
recorded location literally, reaching for the network.

Two directories hold data a product is assembled from rather than source it is
compiled from: the session package's scripts, unit, and PAM template, and the
Android container's AppArmor and seccomp policies. Both were already declared
as file inputs and as checkout read effects; the derivation simply did not
consult them. Of every action across the recipes declaring a checkout read, the
rest run on the host or belong to a lane mounting its own component root.

### Coalescing stops before a package root

Widening rests on a target's siblings being more of the same, which holds in a
source directory and fails at a package root, where `.build` and `.git` sit.
Widening `collider/engine/Sources/ColliderCore` to `collider/engine` mounted
51,514 files of host SwiftPM output -- what Phase 1 removed, restored by Phase
2's own coalescing. Both offending trees arrived through the assembler graph,
which reaches Collider's engine package and a vendored container dependency.
Package roots come from the graph's manifests rather than from probing for
build output, so the mount set stays a function of what the package declares.

The graph cache records manifest settings as a required field, so a cache
predating that collection fails to decode and is rebuilt. Recording it as
optional made a correct fix appear to work while the mount set never changed:
every stale entry decoded cleanly and reported no settings.

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
checkout.

Gate: editing a path no task declares does not supersede a running build, and
editing a path a running task declares still does.

Status: complete.

Gate evidence: editing two documents six minutes into a complete `collider
package linux-runtime` run left it to execute all 114 of its tasks and succeed
after 2,884 seconds, where the same edit previously ended a run after a minute.
Editing one Collider target while `collider test collider` executed superseded
that run, which named the closure that changed.

### The plan is its own baseline

Planning digests every source closure its plan names in order to decide what is
clean, so those digests already are the run's statement of what it read, taken
at the moment it read it. Revalidation re-reads exactly those closures and
compares. Nothing is captured before the command begins, which removes a
whole-repository hash from both ends of every run and removes it entirely from
commands that execute no graph.

Taking the baseline from planning is more precise than taking it earlier, not
merely cheaper. A file edited between process start and plan freeze is consumed
consistently by the plan that read it, and the artifacts are correct for it;
only a baseline taken before planning called that run superseded.

A superseded run now names the paths that moved. "Superseded" alone left the
reader to guess between an edit they made and one they did not.

## Phase 4: Hold the Boundary

A container execution that mounts a tree no declaration names fails to
construct. The property is structural: a mount set derived from declarations
cannot drift from them, and an execution that wants more has to say so.

Gate: constructing an execution whose mounts exceed its declared scopes is a
failure with a test that exercises it.

Status: complete.

Gate evidence: an execution mounting inside its action's declaration reaches
the runtime and one mounting outside it does not, reading a tree is not writing
it, and a workspace mounted read-only under a read-write declaration is within
that declaration while the same workspace at another container path is not. A
complete `collider package linux-runtime` run then executed 114 tasks with
container executions across AOSP source materialization, compilation, signing,
image assembly and validation, both Chromium builds and browser artifact
assemblies, the Chromium and native builder dependency images, Skia, and the
whole Linux packaging lane, and no execution exceeded its declaration. The CEF
artifact actions are not in that graph and were corrected by reading their
declarations against the executions they construct; Wayland source generation
declares its pipeline's effects and runs exactly its executions, so it holds by
construction.

An action's host filesystem access was already scoped to its declared effects
while its container executions were not, so both now ask one predicate the same
question. A mount is how an action reaches the host from inside a container,
and the requirements an execution implies are already derived from its mounts:
an action that is its pipeline therefore satisfies the boundary by
construction, and an action that writes its own requirements and builds
executions by hand has to name what it reaches.

### What a container reached that its action had not said

Four kinds, each declared where it is caused rather than at every site that
inherits it.

A mounted entrypoint exposes the directory its executable sits in, because a
bind source must be a directory; eight actions declared the executable. Every
AOSP product execution mounts the object store the materialized working tree's
Git metadata points at, and none of the four actions that run one said so. A
bounded export is mounted read-write rather than write-only. The two
dependency-image actions mount their whole container context while declaring
the several files they read out of it.

### A declaration bounds an action rather than describing it

A workspace mounted read-only under a read-write declaration is within its
declaration, so the check requires the workspace and its container path to
match and treats access as a ceiling. Composing a declaration from parts can
also arrive at one effect twice without either part being wrong, which a set
rejects, so composition uniques.

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
Phase 4 makes the boundary structural rather than conventional.
