# Placement-Independent Build Plan

Status: active

Execution position: the protected-main CI build is this plan's second-checkout
gate. The launcher admits only the authoritative checkout locally, and planning
another checkout requires host network resolution, so placement independence
and the first bounded CI build are one operation. The complete verification
graph expands only after that run demonstrates warm-state reuse.

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

Status: complete, except the gate's byte-identity clause, which Phase 4 owns and
which needs a second machine to state. No task identity in the graph contains
the checkout or the store, the lowered SwiftPM identities that contradicted that
in a shared build store now agree, and every root this workspace resolves
through is declared. What follows records how that was
established, because the evidence took three forms and the cause was none of the
things the values suggested.

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
costing the other checkout a rebuild is a choice someone made; the same eviction
on every build would be the steady state. Every remaining host path in an identity is under
the store, which both accounts share, so none of them divides this host's warm
state; they divide only reproduction on a second machine. They are of three
kinds: the host task environment, where a host path is what a host command
needs; one value the container prints back so the host learns where an export
landed, which the container never resolves; and the interim prefix-mapping
flags, which now apply to host compilation alone.

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

What this does not establish is a second machine. Both productions share this
host's toolchain, kernel, and container runtime, and only what a build derives
locally has been made to differ.

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

Byte-identity is the assertion, not identity equality. Equal identities that
name unequal artifacts is the failure this plan exists to prevent, and only
comparing the produced bytes distinguishes the two.

Local-to-automated reuse on an identical effective dirty tree, product-store
digest agreement across the two checkouts, and reproduction on a second machine
remain. The CI checkout is the supported second checkout on this host; the
launcher deliberately admits no other local source location.

Gate: an automated build followed by a local build of one effective source, and
the reverse ordering, execute no compilation the other already performed; the
product store resolves the same artifact coordinates and bytes from both
checkouts; and a second machine reproduces the same product digests from the
same source and toolchain.

## Phase 5: Consume Reproducibility in Delivery

Qualification and delivery verify an artifact by rebuilding it rather than by
trusting the run that produced it. A product cohort admitted for signing
carries the digest a rebuild reproduces, and a cohort that fails to reproduce
is refused regardless of which run produced it.

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
