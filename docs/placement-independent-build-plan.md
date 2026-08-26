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

Status: the checkout half is complete for declared task identities, and the
shared build store contradicts that for lowered SwiftPM ones. No declared task
identity in the graph contains the checkout, so the CI checkout and the
authoritative checkout name one identity for one revision.

The store says otherwise about the identities SwiftPM lowering produces. The
authoritative checkout's test lanes use the host build contexts
`sha256-2add9db2…` and `sha256-e1a92bf0…`; a protected-main CI run of the same
revision used `sha256-dceca288…` and `sha256-7aad46c9…`, recreating both from
nothing and spending thirty-two minutes compiling in a single task before its
first assertion. Collection computed from the authoritative checkout's catalog
selects the pair CI had used minutes earlier, reproducibly, so an explicit prune
from the developer's checkout destroys the CI checkout's incremental state and
each rebuild restores it for the other to destroy again.

Which of two causes this is remains open, and they need different fixes. Either
lowered identities still divide on checkout, which is this phase's subject, or
the reachable set does not enumerate the lowered tasks it should, which is the
build store retention plan's. Distinguishing them requires the lowered
identities a plan resolves, and planning `test all` from the interactive account
fails on a verification lock it may not write, so this is recorded as the
measurement it is rather than attributed.

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
location, so mapping its recorded paths maps a prefix that never appears, and
the mapping flag carries the host's own directory into the identity because a
root followed by `=` is not a path boundary to canonicalize. Removing it from
container compilation took the graph from fifteen host paths in identities to
nine. Host compilation keeps it until Phase 2.

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

Protected-main CI plans the whole catalog clean against the developer-warmed
store and executes only the three tasks declared to run every time. A developer
dry run plans the same revision identically, with no identity mismatch and no
failed validation. Six discriminators were found and removed, each one a name
for something other than the source:

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

Remaining for a second machine: dependency checkouts are named beneath the host
build root, which is not a declared placement root, so their prefix is still
this machine's. Declaring it also declares a container mount target, so anything
beneath it that crosses into a container needs a matching mount.

Identity agreement is not this phase's gate. The byte comparison is now
possible and it does not pass.

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

That result is the reason the byte clause exists. The two checkouts agree on
every identity in the catalog and still do not agree on the bytes for one
target, which is exactly the failure equal identities cannot detect.

Discarding a working set remains impossible and is no longer in the way. It is
declared with a runtime as its producer rather than a task, so no workflow lock
resolves for it, and cleaning will not remove storage it cannot serialize
against whatever is producing it. Storage produced by a runtime is therefore
unreachable, which is also why the component holding it cannot be cleaned as a
whole. That is cleanup correctness now rather than a blocker.

Remaining for a second machine: dependency checkouts are named beneath the host
build root, which is not a declared placement root, so their prefix is still
this machine's. Declaring it also declares a container mount target, so anything
beneath it that crosses into a container needs a matching mount.

Identity agreement is not this phase's gate, and the byte comparison it needs
cannot be performed. Nothing forces an artifact to be produced a second time.
Rebuild invalidates task state while the package manager inside the task stays
incremental, and the host working set that holds its build survives both that
and a component clean, so the next build reuses it and never has an opportunity
to disagree with itself.

Discarding that working set is refused, and the refusal is the defect: it is
declared with a runtime as its producer rather than a task, so no workflow lock
resolves for it, and cleaning will not remove storage it cannot serialize
against whatever is producing it. Storage produced by a runtime is therefore
permanently unreachable, which is also why the component holding it cannot be
cleaned as a whole. Naming one declaration is now possible and reaches it; the
lock is what remains.

That capability is Phase 5's, which verifies an artifact by rebuilding it rather
than by trusting the run that produced it. This phase's byte clause depends on
it, so the phases are ordered backwards: the mechanism has to exist before
either can be gated on bytes. The reverse ordering, in which a local build
consumes what an automated one produced, remains outstanding and needs no new
mechanism.

The protected-main CI checkout and the authoritative checkout produce identical
product task identities and artifact coordinates for one effective source, and
each reuses the other's warm state. CI is the real second checkout: the local
launcher cannot admit another location, and planning that location locally
would require network resolution.

Byte-identity is the assertion, not identity equality. Equal identities that
name unequal artifacts is the failure this plan exists to prevent, and only
comparing the produced bytes distinguishes the two.

The first bounded workflow lane invokes the ordinary `collider build all`
catalog entrypoint and nothing broader. Its first watched run is the experiment:
the clean checkout's executed-versus-cached task count measures whether the
developer-warmed store is placement-independent. A broad rebuild is a failed
gate, not a baseline to accept. The workflow expands to tests, packages,
qualification, and delivery only after this lane reuses the warm state.

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
