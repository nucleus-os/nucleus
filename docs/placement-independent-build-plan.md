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

Root-owned SwiftPM source dependencies declare immutable revisions equal to
their gitlink commits. SwiftPM mirrors redirect those URL identities to the
root-owned source without requiring a branch ref to exist in the checkout-local
repository. The revision and gitlink are one validated source coordinate, and
remote dependencies declare immutable revisions or versions pinned by the
lockfile. Every SwiftPM package Collider resolves from the read-only checkout,
including `collider/engine`, checks in its lockfile so resolution never needs
to mutate authoritative source.

Gate: no container command line, environment value, or mount target contains
the host checkout or store path; a Linux product built from two checkouts of
one revision is byte-identical; and Linux task identities are unchanged by
moving either checkout.

Status: the checkout half is complete. No task identity in the graph contains
the checkout, so the CI checkout and the authoritative checkout name one
identity for one revision. Every remaining host path in an identity is under
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
