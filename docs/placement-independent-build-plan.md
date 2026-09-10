# Placement-Independent Build Plan

Status: active

Execution position: the protected-main CI build is this plan's second-checkout
gate. The launcher admits only the authoritative checkout locally, and planning
another checkout requires host network resolution, so placement independence
and the first bounded CI build are one operation. The complete verification
graph now includes tests and Linux-runtime packaging. The remaining reuse
acceptance gate is the local-to-automated ordering documented in Phase 4.

## Invariant

No tool that produces a delivered artifact receives a host path. The workspace
is `/nucleus/workspace` and the shared build store is `/nucleus/cache` in every
product execution environment, and where the host keeps those trees is
Collider's private bookkeeping. A product object, task identity, persistent
workspace name, and cache entry are therefore identical whichever checkout
produced them, because none of them ever saw a location to record.

Placement independence is established by execution, not repaired afterward.
Rewriting a host path out of an identity, and mapping one out of debug
information, are corrections for a leak the execution model creates upstream;
they are incomplete by construction, because a build system that passes an
absolute source path records it once in a place no mapping flag reaches. Both
mechanisms are removed from product execution rather than maintained there.

The canonical names bind for the duration of one admitted run. The machine-wide
execution lease already admits one run at a time, so the CI checkout and the
authoritative checkout each become `/nucleus/workspace` while they hold it.
That coupling is load-bearing: canonical binding is correct only while exactly
one run executes, and any future admission of concurrent runs invalidates it.

## Phase 1: Bind Container Execution Canonically

Every OCI mount that repeats a host path as its container target takes a
declared canonical target instead. The checkout mounts at `/nucleus/workspace`,
the shared store at `/nucleus/cache`, and existing fixed targets such as
`/swift-sdk` keep the names they already have.

Collider computes container paths from host paths through one mapping at the
execution seam. Recipes stop spelling `target: someHostPath.string`, and
`OCIExecution` distinguishes the host path it mounts from the canonical path it
passes to the command, which its `hostWorkingDirectory` and `workingDirectory`
pair already anticipates. Every command argument, working directory, search
path, and toolset entry crossing into a container is canonical.

URL-based forked SwiftPM dependencies declare immutable public revisions equal
to their gitlink commits. SwiftPM resolves those revisions from the host
network; an Actions submodule checkout is a source and provenance input, not a
complete Git remote. Mirrors unify upstream Swift System URLs with the fork URL
without redirecting the fork back into the checkout. That placement-independent
mirror rule is checked in at every package root; the launcher performs no
configuration mutation. Remote dependencies declare immutable revisions or
exact versions pinned by the lockfile. Every SwiftPM package Collider resolves
from the read-only checkout, including `collider/engine`, checks in its lockfile
so resolution never needs to mutate authoritative source.

Gate: no container command line, environment value, or mount target contains
the host checkout or store path; a Linux product built from two checkouts of
one revision is byte-identical; and Linux task identities are unchanged by
moving either checkout.

Status: complete. The gate's byte-identity clause is stated by two checkouts of
one revision on this host, which is the whole of what it needs; a second
machine was once expected to state it and is not part of the supported host
matrix. No task identity in the graph contains the checkout or the store, the
lowered SwiftPM identities that contradicted that in a shared build store now
agree, and every root this workspace resolves through is declared. What follows
records how that was established, because the evidence took three forms and the
cause was none of the things the values suggested.

The store says otherwise about the identities SwiftPM lowering produces. The
authoritative checkout's test lanes use the host build contexts
`sha256-2add9db2…` and `sha256-e1a92bf0…`; a protected-main CI run of the same
revision used `sha256-dceca288…` and `sha256-7aad46c9…`, recreating both from
nothing and spending thirty-two minutes compiling in a single task before its
first assertion. Collection computed from the authoritative checkout's catalog
selects the pair CI had used minutes earlier, reproducibly, so an explicit prune
from the developer's checkout destroys the CI checkout's incremental state and
each rebuild restores it for the other to destroy again.

Which of two causes this is no longer remains open. Reading the contexts
themselves settles it: the four hold two packages built from two checkouts.

| context | package | checkout |
| --- | --- | --- |
| `2add9db2` | `collider-cli` | authoritative |
| `e1a92bf0` | `engine` | authoritative |
| `dceca288` | `collider-cli` | runner work tree |
| `7aad46c9` | `engine` | runner work tree |

The same package at two locations produces two contexts, so lowered identities
divide on checkout and this phase owns the defect. The reachable set enumerates
what it should; there is simply more than one identity for one package.

The mechanism is the order of the prefix-mapping flags rather than any value in
them. The identity path map sorts its roots by path length, descending, so that
a nested root is canonicalized before the root containing it; that order is
therefore a property of where a checkout sits. `filePrefixMapFlags` iterated the
map's own order and emitted the flags in it, and those flags are part of a
SwiftPM identity. The authoritative checkout's workspace path is twenty-five
characters and its cache path thirty-one, so the cache mapping was emitted
first; the runner work tree's workspace path is ninety-three, longer than
either, so the workspace mapping was emitted first.
Every value canonicalized correctly in both, which is why the values had been
checked and cleared: the sequence carried the placement instead.

The flags are now emitted in name order while canonicalization keeps its
length-descending sort, which it needs. The authoritative checkout already
emitted cache first, so its identities are unchanged and only the runner work
tree converges onto them, at the cost of one rebuild.

Lowered identities are now observable. A lowering returns the bytes its task's
name was derived from rather than reporting them, because a lowering is required
to be deterministic and free of side effects; planning already holds the observer
and reports what it is handed. Reading one requires forcing the tasks dirty,
since a lowering only expands what assessment found unclean, and a store whose
tasks are all valid lowers nothing at all.

The trace narrows the cause to one component. Every path in a lowered SwiftPM
identity resolves through the map -- the package root, both prefix-mapping
flags, and the compiler flag lists -- leaving `toolchainIdentity` as the single
opaque value, and it is opaque because it is a digest of the compiler's absolute
path taken before any canonicalizer can reach it. The compiler resolves from
`xcrun --find swiftc` rather than from the checkout, so that alone does not
explain two checkouts disagreeing, and what the other checkout encodes cannot be
read from here: the launcher admits only the authoritative checkout, and the
runner work tree is unreadable from the developer account.

The divergence is confirmed a third way in the meantime. The authoritative
checkout lowers the Collider packages to `swift.package.test.sha256:2150fdb5…`
and `…c337c2fc…`; a protected-main run of the same revision contains neither.

A run now records the components of every task a lowering produced, and
`collider runs show --explain-identity` reads them back. Only lowered tasks
carry them, because only those cannot be recovered by planning the revision
again: a lowering expands what assessment found unclean, so a task whose outputs
are valid is never constructed a second time. This is what makes the comparison
possible without either checkout reading the other -- both write into one store,
and the next protected-main run records what its own checkout encoded.

One further defect surfaced while establishing this, about inspection reaching
for permission it does not need: `collider test --dry-run` takes the exclusive
workspace verification lock although a plan mutates nothing, so planning a test
graph from the account that owns the checkout requires crossing identities.

Until it is resolved, no collection may run automatically. An explicit prune
costing the other checkout a rebuild is a choice someone made; the same
eviction on every build would be the steady state. Every remaining host path in
an identity is under the store, which both accounts share, so none of them
divides this host's warm state; they would divide reproduction between two
macOS hosts, which the supported matrix does not have. They are of three kinds:
the host task environment, where a host path is what a host command needs; one
value the container prints back so the host learns where an export landed,
which the container never resolves; and the interim prefix-mapping flags, which
now apply to host compilation alone.

Phase 3 begins here rather than waiting. A container is given the canonical
location, so mapping its recorded paths maps a prefix that never appears.
Removing it from container compilation took the graph from fifteen host paths in
identities to nine. Host compilation keeps it until Phase 2.

The remainder is now asserted rather than counted by hand. Every string in every
planned and lowered identity is scanned for a prefix only this host owns, and
each one found must live under the store both accounts share. `/usr/local` is
not treated as such a prefix: it exists inside the Linux images, where it is the
container's own and carries no placement, and this host's package prefix is
`/opt/homebrew`. What remained under the store was dominated by two roots the map
did not declare -- the package-graph scratch under `state/build`, and the
product artifact tree under `state/artifacts` -- with the signing identity path
behind them.

Those roots are now declared, by their own names rather than by the one
directory that holds them. `build`, `artifacts`, and `identity` sit under the
cache root on a host with no machine build store and move beside it, under the
store's state root, on a host with one; only their own names exist in both
layouts, so only their own names make the two agree. That is the requirement
that makes two checkouts agree, applied to one host that can be provisioned two
ways. The log root moves the same way, from inside the checkout to inside the
store, and is declared with them because lanes that name their own log
directory put it in an identity.

Declaring them exposed one further leak, which the check turned from an
invisible difference into a hard failure. A container command's arguments were
encoded as opaque strings while the environment values beside them were
canonicalized, so a path a recipe spelled by its host location survived into
identity; commands now canonicalize as every other argument does. Container
paths canonicalize to themselves, so nothing already placement-free changed.

The assertion is an absence rather than a containment. No string in any planned
or lowered identity carries a prefix this host owns, in any task reachable from
any public entrypoint, and the scan that once reported a list reports nothing.

Two consequences follow from one declaration serving identity and execution
alike. Every identity in the graph changes, so the store's warm state is
superseded in one sweep and each product is produced once more. And container
mount targets move with it: a products directory that crossed as
`/Library/Nucleus/Collider/state/build/swiftpm/…` now crosses as
`/nucleus-build/swiftpm/…`. A deep target with no mounted parent already
worked, because that host path was itself one.

## Phase 2: Bind macOS Execution Canonically

Status: deferred

macOS host builds execute in a virtual machine with the workspace and store
mounted at the same canonical paths. Host execution is currently the one
environment that observes real locations, and it is where the residual
provenance record originates: a compilation records its own source file when
that file is named absolutely, and no mapping flag reaches that record.

Host execution produces Collider and other build tools, not delivered product
artifacts. A virtual machine is therefore not justified merely to remove a
provenance record from tooling. Revisit this phase when macOS host execution
first produces an artifact that enters delivery; until then its prefix mapping
and path-bearing provenance remain outside the product reproducibility
contract.

A symbolic link is not the mechanism. Any tool resolving it observes the
physical path, and Collider itself resolves paths deliberately in its own
launcher, so an advisory canonical name is defeated by the discipline the rest
of the system already exercises correctly. A mount namespace cannot be seen
through.

Gate: a macOS host product and its recorded source paths are identical from two
checkouts of one revision; no host-side compiler invocation names a physical
location; and Collider's own build is reproducible across machines carrying the
same toolchain.

## Phase 3: Remove the Interim Corrections

Status: complete

Delete the file-prefix mapping applied to container Swift and Clang invocations,
and the argument and path canonicalization applied while encoding product task
identities. Both exist to remove a leak that canonical product execution no
longer creates. Host-tool compilation retains its mapping while Phase 2 is
deferred.

`IdentityPathMap` remains, inverted: encoding asserts that no declared root
appears in an identity and fails when one does, rather than rewriting it. A
host path reaching an identity is then a defect that stops a build, not a
string quietly corrected in one of the several places that must remember to
correct it.

The prefix-mapping half is done. Container Swift and Clang invocations carry no
mapping and the reason sits beside the switch that omits it: a container is
already given the canonical location, so a mapping there would map a prefix that
never appears and would put the host's own directory into the identity through
the flag itself. Host-tool compilation keeps its mapping, as this phase says it
should while Phase 2 is deferred.

The encoding boundary now accepts semantic arguments unchanged and rejects an
absolute host path during manifest validation. Neither the manifest initializer
nor the artifact builder accepts a placement map. The portable-value validator
performs validation only; the rewriting API is removed. Tests cover identity
stability across payload and archive locations and reject checkout, cache, home,
output, include, and file-URL paths.

Gate evidence: [protected-main run 33985000262](https://github.com/nucleus-os/nucleus/actions/runs/33985000262)
verified revision `9fd675f0df53274830a0244d1ff7ed3bfeb87992` with 76 clean
tasks, 81 executed tasks, no failures, and no cancellations. The seven absolute
path rejection cases, semantic-input identity tests, and payload/archive
relocation test passed. Linux-runtime packaging and both architectures' package
lifecycle qualification passed in the same sweep. The broader checkout/store
relocation acceptance remains owned by Phase 4.

Gate: product identity encoding rejects a host path rather than canonicalizing
it; no product compiler invocation carries a prefix mapping; and every product
task identity is unchanged by relocating the checkout or the store.

## Phase 4: Prove Reproducibility Across Checkouts and Machines

Status: active

Protected-main CI and the authoritative checkout resolve the same task
identities and machine-store coordinates. Revision
`e4a3962a39893be41715ca5f7a38fd01aa8fe8ed` passed the complete protected-main
verification selection. Planning that exact revision afterward from the
authoritative checkout found every one of the 41 cacheable tasks valid and
selected only fourteen declared always-run or SwiftPM-incremental test tasks.
This establishes automated-to-local warm-state reuse without repeating the
verification sweep. Six placement discriminators were removed to reach this
state:

- the SwiftPM dependency task's own name, which takes the lockfile's absolute
  path as an argument and encoded it through an empty placement map;
- the invoking account, reaching identity through `HOME`, `USER`, and
  `LOGNAME`, which name who started a build rather than what it produces and
  now join `PATH` and `TERM` outside identity;
- a package-wide invocation naming its root as a directory tree, so the digest
  counted the repository database and everything Git ignores beneath it, and
  one commit hashed differently depending on how its checkout was materialized;
- the Swift SDK discovery links, written into the invoking account's home and
  consumed by the tasks that publish the active generation, which put a home
  directory in the identity of every product built against that SDK;
- acquired inputs landing in the store readable only by their owner, so the
  account that inspects reported intact files as failed validations;
- the SwiftPM resolution scratch, named by the digest of a package root's
  absolute path, which resolved one revision into two scratches and gave every
  dependency checkout a different path while describing identical source.

Several of these are one mistake in different clothes: an identity that names
how a tree arrived rather than what it contains. A repository database, a home
directory, and a resolution scratch are all placement, and none was reachable by
the placement invariant, because none is a declared root.

Two inspections made this tractable and belong to the contract now.
`--explain-identity` reads an identity's components back out of the encoder's
own framing, so two plans that disagree report where rather than only that.
`--as-builder` plans as the identity that would execute, taking no admission and
recording no run, because a plan is a property of that identity and no other
account can be asked what it computes.

Producing twice needs no deletion. Where a package manager builds is not part of
what it builds, so a verifying invocation produces the same identity into a
sibling of the location it would otherwise have replaced, and the retained
result stays intact to compare against. `--verify-reproduction` does that and
fails when the two disagree.

Against that, both Linux products reproduce. Two productions of one identity
that share nothing they derive locally, each with its own scratch, its own build
workspace, and its own materialization of the pinned dependencies, are identical
in every file.

Reaching it took making the comparison honest first and then removing two
timestamps. A verifying production originally took only its own scratch, which
changed where products were copied while both builds still compiled in one
workspace, so the second built on what the first left behind and reported reuse
as reproduction. Ownership of a workspace is placement and never reaches an
identity, so a verifying production now owns its own.

Measured that way, products carried the times their sources happened to be
written or fetched. Dependency materialization now gives every checked-out file
one fixed time, because a pinned dependency is identified by its revision rather
than by when it was fetched. First-party source times could not be answered the
same way, because they belong to a working tree that a build has no business
rewriting; instead products no longer record them. Source info exists for
reaching source from a debugger or an editor, which the host builds serve, and a
product compiled in a container is not read that way. Its absence is why a
product is now fifty-four files rather than seventy.

Both productions share this host's toolchain, kernel, and container runtime,
and only what a build derives locally has been made to differ. That is the
whole of what reproduction has to mean here: this host is the sole builder of
anything delivered, so there is no second macOS machine whose agreement a
product depends on.

Discarding a working set remains impossible and is no longer in the way. It is
declared with a runtime as its producer rather than a task, so no workflow lock
resolves for it, and cleaning will not remove storage it cannot serialize
against whatever is producing it. Storage produced by a runtime is therefore
unreachable, which is also why the component holding it cannot be cleaned as a
whole. That is cleanup correctness now rather than a blocker.

Dependency checkouts are now named beneath a declared root. They sit in the
package-graph resolver's scratch, and that scratch had to move for a second
reason: resolving writes, the machine build store admits one writer, and a
resolver rooted there could only be driven by the builder -- every other account
failed the moment SwiftPM opened the scratch or the manifest cache for writing,
which is what made the documented local iteration path stop working. It is now
per-account and declared as `package-graphs`, so two accounts resolve into two
directories and identity cannot tell them apart.

Per-account alone was not enough, and the first attempt proved it: an undeclared
home-directory root put paths like
`/Users/…/swift-package-graphs/…/checkouts/swift-crypto/Package.swift` into the
identities of tasks that name them, and the placement assertion rejected it.
Declaring the root is what makes a per-account location safe, which is the same
conclusion the per-checkout SwiftPM scratch reached.

Automated-to-local warm-state reuse measures 38 of 55 tasks clean on a revision
the sweep had just verified, with 14 declared to run every time, 2 declared to
leave incrementality to SwiftPM, and one that genuinely diverges:
`swift.package.dependencies` for the root package plans a different input digest
locally than the sweep recorded, deterministically across repeated runs. Its
identity is not the problem -- every path in it canonicalizes to a declared
root, `${workspace}` and `${cache}` and nothing else -- so what differs is the
digest of what the task reads rather than the encoding of what it is.

That distinction is where the tooling stopped. `--explain-identity` exists
because two plans that disagree should report where rather than only that, and
it did that for one side only: a task's state record kept its identity as a
single digest, so the plan that disagreed with it had nothing to disagree
against.

An executed task now records what its identity was computed from, and a plan
that rejects that record reports where the two stop matching -- the component,
not the digest. Recomputing an identity answers what the inputs are now, which
is the one question that was never in doubt; the record is the only account of
what they were when the task last ran, and it is exactly that which is gone
once they change. Records written before this decode without it and are simply
unexplainable.

That divergence is closed. It needed no sweep to read: planning the same
revision on this machine as the builder found all three tasks clean while the
interactive account found them dirty, which places it in the account rather
than in the checkout, the machine, or CI. Rendering the encoding a lowered task
is assessed by -- rather than the one it is named from, which is what an
explanation showed and is identical across accounts by construction -- reduced
it to three components:

    string "HOME"      "/Users/nucleus-builder"  vs  "/Users/maddy"
    string "LOGNAME"   "nucleus-builder"         vs  "maddy"
    string "USER"      "nucleus-builder"         vs  "maddy"

The account variables were already excluded from the environment an action's
identity records. They were not excluded from the host command encoded beside
it, which carried its own list of what counts as volatile, and that list had
been written down separately and drifted. One definition serves both now, and
both accounts plan identical digests for all three tasks.

This is the sixth placement discriminator and the same mistake as the other
five: an identity naming how a build arrived rather than what it contains. It
outlived them because it was the one they could not see -- `/Users/maddy` is
not a declared root, and `maddy` is not a path at all, so the placement
assertion had nothing to reject.

The sweep that executed under the corrected encoding rewrote those records,
and the two accounts now plan the complete verification selection identically:
every one of its 160 tasks reaches the same state from the builder and from the
interactive account, the three dependency tasks among them.

What still separates the two plans is not an identity. Two Android tasks are
assessed from outputs the inspecting account may not read, and fifteen tasks
downstream of them wait on artifacts that assessment never confirms. One is by
design and the storage layout says so: the identity that executes is the
identity that signs, so local-development signing material is readable by the
builder and by no one else, and an account that inspects without ever executing
is asking a question it was deliberately denied. The other is a repo launcher
fetched before the store had a read mode for its group, which the
content-addressed check reports satisfied forever because content is all it
compares. Acquisition now adopts the store's mode on the path that already
found the file, so a store heals as it is used; and a denial is now reported as
a denial rather than as a failed validation, because "output validation failed"
claims a result went bad and sends whoever is comparing two plans looking for
an input that differs. Nothing about the task differs. The reader does.

The remaining divergence is deliberate and belongs to neither category.
`linux.package-source-snapshot` plans differently from the sweep's record in
both accounts and by the same three components:
`NUCLEUS_PRODUCT_SOURCE_AUTHORITY`, `_COMMIT`, and `_REF`, which the sweep held
as `protected-main`, the verified revision, and `refs/heads/main`, and which a
local build does not have at all. These are the protected-main provenance
assertions rather than placement. A package built locally must not be
identity-equal to one a protected-main run published, because only one of them
carries provenance that was verified, and an identity that could not tell them
apart is precisely the confusion this plan exists to prevent. The reuse clause
of the gate below therefore covers compilation and stops where provenance is
stamped; the publication tail is expected to execute on both sides and is not
evidence of a discriminator.

Reading that took extending the explanation once more. A composite component
reported only its header, so a value present on one side and absent on the
other rendered as `optional` against `optional none`: the two shapes, when the
value the present side held is the whole of the difference. Carrying the
payload into the report, elided by depth rather than dropped at the header, is
what named the three variables instead of locating three anonymous positions.

Measuring the reuse pair found a seventh discriminator, and it is the first
that has nothing to do with placement. A local build after a protected-main
sweep reused thirty-three of the build closure's forty tasks and executed
seven: five declared to run every time or their discovery children, and two
Swift package builds. Running it again immediately executed five and compiled
nothing, so the always-run roots are output-stable and a build reuses its own
predecessor exactly. The reverse ordering re-executed the same two tasks, and
comparing the two records showed every consumed artifact digest and every
dependency identity agreeing; only the recipe differed.

The cause was the command. A lowering merges its consumers' expected outputs
into the postconditions of the task it produces, and those postconditions were
encoded into that task's identity. Which consumers exist depends on what the
selection reached, so `collider build all` and `collider verify all` computed
two identities for one compilation whose every input, argument, and operation
agreed -- differing only in `expectedOutputs`, a sequence of one against a
sequence of two -- and each invalidated what the other had just built. Neither
the checkout, the machine, nor the account was involved; the measurement had
been comparing two selections and reading the result as a property of the two
sides.

A postcondition is an assertion about a result, not an input that determines
one. It is now checked rather than keyed. `TaskOutputValidator` runs the
postconditions on every execution and on every reuse, so a postcondition the
retained outputs do not satisfy still refuses the record -- by checking rather
than by keying, which is what makes reusing across selections safe, and which a
weakened assertion no longer pays for with a rebuild. Declared output slots
stay in identity: a slot is the contract other tasks reference by name.

With that removed the pair measures, and it measures the same in both
orderings. A protected-main sweep followed by a local verification of one
revision reuses 130 of the selection's 160 tasks and executes 30; the reverse
ordering reuses 130 and executes 30. Neither side executes a compilation the
other performed -- no Swift package build, no Skia or native SDK, no React
Native, no browser or AOSP compile appears on either list -- and the sweep that
follows the other falls from twenty-six minutes to five and a half.

The thirty are the same thirty each way, and each belongs to a category this
gate already excludes: eight declared to run every time or discovered directly
from one, two whose incrementality SwiftPM owns, two always-run test lowerings,
the provenance-stamped source snapshot with the seven publication tasks beneath
it, and the tests and release gates. What remains of Phase 4 is product-store
digest agreement across the two checkouts.

Byte-identity is the assertion, not identity equality. Equal identities that
name unequal artifacts is the failure this plan exists to prevent, and only
comparing the produced bytes distinguishes the two.

Product-store agreement across the two checkouts is established, and the store
established it rather than a measurement. Thirty-six of the eighty-four
products it holds carry provenance from both `local-development` and
`protected-main` against one manifest -- the authoritative checkout at
`1b32889d` and a protected-main run at `f1fb3d9b`, two revisions whose
difference is documentation and therefore not a product input. Publishing an
identity that already exists compares the whole incoming manifest against the
stored one, archive digest and every file digest included, and refuses a
mismatch as an artifact that "already exists with a different manifest". A
second provenance can only attach where the bytes agreed, so those thirty-six
are receipts rather than observations. The remaining forty-eight were produced
by one side only.

The dirty tree resolves to the same thing. A Linux product build's identity was
read with an edit uncommitted, then with that identical content committed: 1505
components, byte for byte the same, while the edit itself moved exactly one
source-checkout digest against the unedited tree. Identity follows content and
not the state of the index, so a revision built by a sweep is reusable by a
working tree holding the same content, and the reverse.

What a dirty tree contributes is bounded, and it was worth measuring rather
than assuming. An edited document, and an untracked file anywhere outside a
declared source root, leave every product identity untouched. An untracked file
that Git ignores does too, even inside a source root. An untracked file that
Git does not ignore, inside a source root, changes the identity -- which is
correct rather than a leak: a package manager compiles what is on disk, and a
source file someone has not committed yet is source. The boundary is the
content of declared source roots, and it is the same boundary whether that
content is committed.

The CI checkout is the supported second checkout on this host; the launcher
deliberately admits no other local source location.

Cross-machine reproduction was carried here as an acceptance clause and does
not belong to this plan. This host is the sole CI builder and the primary
development host, reached locally or remotely; Linux hosts develop, build, and
test the graph they support and never execute CI. Nothing delivered is produced
anywhere else, and qualification consumes no cache namespace, so no product
depends on a second machine agreeing with this one.

Where two hosts do meet is the shared content-addressed store the [Linux x86_64
development host plan](linux-x86-64-development-host-plan.md) describes, and
identity agreement there is a cache-hit property rather than a correctness one.
A miss executes locally, a mismatched digest or inconsistent toolchain claim is
quarantined and fails the action, and protected-main never consumes a developer
mapping. That plan gates it, because that is where it first has consequences.

Gate: an automated build followed by a local build of one effective source, and
the reverse ordering, execute no compilation the other already performed,
excluding the provenance-stamped publication tail, which is expected to differ
because only one of the two carries verified provenance; and the product store
resolves the same artifact coordinates and bytes from both checkouts.

## Phase 5: Consume Reproducibility in Delivery

Qualification and delivery verify an artifact by rebuilding it rather than by
trusting the run that produced it. A product cohort admitted for signing
carries the digest a rebuild reproduces, and a cohort that fails to reproduce
is refused regardless of which run produced it.

Status: partly established, and by a mechanism that was not built for it.

Thirty-six of the eighty-four cohorts the product store holds -- eighteen per
architecture -- carry provenance from two independent producers against one
manifest. That is a reproduction result rather than a coincidence of storage:
publishing an identity that already exists compares the entire incoming
manifest against the stored one, archive digest and every file digest included,
and refuses a mismatch as an artifact that "already exists with a different
manifest". Two productions of one cohort identity have therefore agreed byte
for byte, and a third that disagreed would already be refused. The remaining
forty-eight were published by one producer, so nothing has checked them.

Two things separate that from the gate. The first is that the check is
incidental: it fires only where a second producer happens to publish the same
identity, so a cohort is verified by luck of scheduling rather than because
anything asked. A single run cannot verify one deliberately, because
`--verify-reproduction` compares productions under the SwiftPM scratch roots
and stops there -- it reaches compiled products and never the packages
assembled from them, which is what a cohort is.

The second is that nothing yet refuses. Signing and release publication belong
to the [Linux package distribution and update
plan](linux-package-distribution-and-update-plan.md) and do not exist, so the
clause about what cannot reach them has nothing to attach to. Recording a
reproduction qualification before there is a consumer for it would be
scaffolding, and the qualification record already carries a role, a capability,
an evidence digest and a qualifier trust domain, so the shape is there when the
consumer arrives.

What this phase needs next is therefore the first gap and not the second:
reproduction verification that reaches through packaging, so that one run can
establish what two runs currently establish between them by accident.

Two ways of reaching it were tried and neither works, for reasons worth
keeping. Producing into a sibling, which is how the scratch roots are verified,
cannot be applied to the packaging roots: `${artifacts}/package-work/...`
appears in the cohort's identity, so a moved root is a different cohort, and
the second production would be published beside the first rather than compared
against it. That is not a defect in the roots -- a declared output slot is the
contract other tasks reference by name, and belongs in identity for the same
reason the scratch does not.

Forcing the tail to re-run in place does not reach it either. The packaging
entrypoint's roots are the storage assertion and the storage retention, and
`--rebuild` forces the tasks a selection names rather than everything beneath
them, so the cohort upstream of those roots is reused however often it is asked
for. No surface today re-assembles a cohort at an unchanged identity, which is
exactly why the store's comparison has only ever been reached by a second
producer arriving on its own.

The mechanism that is needed is therefore narrow: something that re-runs the
packaging tail in place at its existing identity, so that publication meets the
retained manifest and adjudicates. The comparison itself needs no new code --
the store already refuses an identity whose manifest differs -- and it is the
forcing, not the comparing, that is missing.

Gate: rebuilding an admitted cohort from its recorded source and toolchain
reproduces its exact digests; a cohort whose rebuild diverges cannot reach
signing or publication.

## Explicit Non-Goals

- Do not make the canonical path a symbolic link, a search path, or a
  convention that tools are asked to honor. It is a mount.
- Do not retain prefix mapping or identity canonicalization as a product-build
  safety net once product execution is canonical. The deferred macOS host-tool
  boundary retains only the correction its noncanonical execution still needs.
- Do not admit concurrent runs while canonical names bind per run.
- Do not relocate the authoritative checkout, the build store, or any
  persistent workspace to achieve this. Where the host keeps a tree stops
  mattering, which is the point.
- Do not gate this plan on a second macOS machine reproducing a product. One
  host builds everything delivered, and cross-host reuse is gated where it is
  consumed rather than proven in advance here.
