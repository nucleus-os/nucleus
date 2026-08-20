# Placement-Independent Build Plan

Status: active

Execution position: this plan precedes the complete verification graph in the
root documentation inventory. That graph requires every invocation source to
produce one task identity and one artifact for the same effective source, which
is a property of how builds execute rather than a correction applied to
identities afterward.

## Invariant

No build tool receives a host path. The workspace is `/nucleus/workspace` and
the shared build store is `/nucleus/cache` in every execution environment, and
where the host keeps those trees is Collider's private bookkeeping. A compiled
object, a task identity, a persistent workspace name, and a cache entry are
therefore identical whichever checkout produced them, on whichever machine,
because none of them ever saw a location to record.

Placement independence is established by execution, not repaired afterward.
Rewriting a host path out of an identity, and mapping one out of debug
information, are corrections for a leak the execution model creates upstream;
they are incomplete by construction, because a build system that passes an
absolute source path records it once in a place no mapping flag reaches. Both
mechanisms are interim and are removed by this plan rather than maintained.

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

Gate: no container command line, environment value, or mount target contains
the host checkout or store path; a Linux product built from two checkouts of
one revision is byte-identical; and Linux task identities are unchanged by
moving either checkout.

Status: the checkout half is complete. No task identity in the graph contains
the checkout, so the CI checkout and the authoritative checkout name one
identity for one revision. Every remaining host path in an identity is under
the store, which both accounts share, so none of them divides this host's warm
state; they divide only reproduction on a second machine. They are of three
kinds: the interim prefix-mapping flags, which Phase 3 deletes; the host task
environment, where a host path is what a host command needs; and one value the
container prints back so the host learns where an export landed, which the
container never resolves.

## Phase 2: Bind macOS Execution Canonically

macOS host builds execute in a virtual machine with the workspace and store
mounted at the same canonical paths. Host execution is currently the one
environment that observes real locations, and it is where the residual
provenance record originates: a compilation records its own source file when
that file is named absolutely, and no mapping flag reaches that record.

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

Delete the file-prefix mapping applied to Swift and Clang invocations, and the
argument and path canonicalization applied while encoding identities. Both
exist to remove a leak that no longer occurs.

`IdentityPathMap` remains, inverted: encoding asserts that no declared root
appears in an identity and fails when one does, rather than rewriting it. A
host path reaching an identity is then a defect that stops a build, not a
string quietly corrected in one of the several places that must remember to
correct it.

Gate: identity encoding rejects a host path rather than canonicalizing it; no
compiler invocation carries a prefix mapping; and every task identity is
unchanged by relocating the checkout or the store.

## Phase 4: Prove Reproducibility Across Checkouts and Machines

Two checkouts of one revision at different locations produce byte-identical
products, identical task identities, and identical artifact coordinates, and
each reuses the other's warm state completely. The same holds for one revision
built on a second machine carrying the same pinned toolchain.

Byte-identity is the assertion, not identity equality. Equal identities that
name unequal artifacts is the failure this plan exists to prevent, and only
comparing the produced bytes distinguishes the two.

This phase needs a real second checkout and cannot be reached earlier. Planning
a second location resolves its package graph, which reaches the network and is
therefore not something a test performs; and the launcher admits one canonical
checkout, so a second one cannot be built locally at all. Until then the
invariant is held by two narrower guards: one identity resolves two locations
to the same bytes, and no container mount names the checkout.

Gate: an automated build followed by a local build of one revision, and the
reverse ordering, execute no compilation the other already performed and
produce identical bytes; and a second machine reproduces the same product
digests from the same source and toolchain.

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
- Do not retain prefix mapping or identity canonicalization as a safety net
  once execution is canonical. Two mechanisms for one invariant is how the two
  drift apart.
- Do not admit concurrent runs while canonical names bind per run.
- Do not relocate the authoritative checkout, the build store, or any
  persistent workspace to achieve this. Where the host keeps a tree stops
  mattering, which is the point.
