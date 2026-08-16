# Collider Build Storage Architecture

## Invariant

The macOS host owns authoritative source, acquired inputs, credentials,
provenance, and finished artifacts. Materialized Linux source trees that require
case-sensitive semantics, build intermediates, and compiler caches live only in
Collider-owned persistent workspaces. Container-local temporary state lives on
tmpfs. Every writable host mount is a bounded export declared as an action
output; an ordinary host input mount is always read-only.

Deleting every persistent workspace leaves the checkout capable of rebuilding
every product from its declared host inputs. A workspace is therefore
reconstructible state, never authoritative source, provenance, or a publication
boundary.

A bounded export hands a declared artifact from a build workspace to host-owned
artifact staging. Native package and repository assembly consume those staged
artifacts. The signed snapshot in the repository-metadata R2 bucket, the
Cloudflare Worker at `packages.nucleus-os.org`, and the immutable package-object
backend form the product publication boundary. GitHub Releases are the initial
package-object backend; a dedicated R2 bucket takes over at the hard cutover
defined by the Linux package distribution plan. Persistent workspaces and
Collider caches never form any part of that boundary.

Published contributor OCI inputs in GHCR form a separate build-input
acquisition boundary. Collider resolves them by immutable manifest and blob
digest into its host download cache, then mounts them read-only. They are never
persistent-workspace outputs, end-user packages, or product publication.

## Storage Classes

Collider exposes four disjoint storage classes to container actions:

- A host input is a read-only bind mount containing source, a downloaded input,
  an SDK, a lock, or a credential required by the action.
- A bounded export is a writable bind mount containing only the action's
  declared host-visible outputs. Collider models it as an output effect, not as
  scratch state.
- A persistent workspace is a named Linux filesystem owned by one logical
  component, artifact target, and role. Materialized source, build trees, and
  compiler caches use separate workspaces.
- Ephemeral state uses tmpfs. `/tmp` and the configured container home are never
  backed by writable host directories.

The type model enforces this boundary. `OCIMount` represents either a read-only
input or a bounded export. `OCIPersistentWorkspaceMount` separately represents
a named volume and carries its own read-only/read-write access. There is no
general writable host-mount mode and no action-specific host temporary
directory.

## Ownership and Lifecycle

Every host storage declaration names one owner, its producers, its storage
class, a root, a narrower deletion boundary, and one typed retention policy.
Source, identity, provenance, and publication state is `protected`.
Reconstructible host materializations use `singleWorkingSet`; their producer
replaces the current contents in place and component clean may remove the whole
set. SwiftPM scratch directories use `taskIdentityContexts`; the current
catalog supplies the retained `sha256-*` paths. Generation stores use
`keepActiveAndRollback`, compiler caches use an owner-enforced
`toolManagedLimit`, and run records use `boundedHistory`. A path that does not
match a declaration and policy is unknown, not implicitly disposable.
Diagnostic directories use the same bounded-history policy and retain their
newest declared number of immediate, non-symlink entries. Active service logs
declare the exact files the service owns. RunRegistry separately protects its
lock root and `latest` index while applying active-run-aware history retention.

Status classifies each observed object as `active`, `protected`, `retained`,
`reclaimable`, or `unknown`. Only `reclaimable` objects are deletion candidates.
Unknown objects remain visible and survive every clean and prune operation.

Catalog construction validates all writable action effects against these
declarations. One writable path must map to exactly one declaration owned by
the action's component or to an explicitly shared runtime-owned declaration.
Removable declarations require producer workflow locks, cannot overlap one
another, and cannot overlap authoritative source or identity storage.
An `unrestricted` effect is an explicit escape from Collider storage ownership
for an external installation or operating-system integration boundary. It is
still enforced by the action filesystem but is never reported or reclaimed as
Collider cache state.

Persistent workspace identity consists of its owner key, artifact target, and
role. Collider derives a checkout-scoped Apple volume name from that identity,
creates and validates the volume through Apple container's Swift API, attaches
it only for the action lifetime, and reports or removes it through Collider's
storage operations. A recipe declares capacity, filesystem, journal policy,
guest target, and access; it does not manipulate the backing image.

The Apple container service stores its application state and natural `volumes`
subdirectory under `~/Library/Developer/Nucleus/Collider/apple-container`.
These sparse image files live on the default macOS Data filesystem; Apple
container owns EXT4 creation, formatting, attachment, and exclusive-use
enforcement. DiskImageKit is not part of the build-workspace path because it
would duplicate that ownership.

The component graph is the workspace lifecycle registry. A workspace used by
exactly one component belongs to that component; a workspace intentionally used
by multiple components, such as the root Linux SwiftPM build tree, belongs to
the catalog rather than to any one consumer. `collider clean <component>`
acquires the same workspace locks as build actions and removes only that
component's inactive exclusive volumes whose declarations permit explicit
cleaning, alongside its declared host clean roots. Durable source workspaces
are protected from both component cleaning and cache pruning.
`collider cache prune` removes only inactive Collider-owned volumes whose
identities no longer exist in the current component graph. Dry-run reports the
same targets without deleting them, and cache status classifies owned volumes
as active, retained, or reclaimable.

The same prune operation also removes expired run records, interrupted and
superseded generations, SwiftPM task-identity contexts absent from the current
catalog, and obsolete references in declared local OCI image families. It
deletes no unknown path and no foreign image repository. Mutating prune runs
under host execution admission, reacquires the affected workflow and workspace
locks, recomputes candidates, and revalidates every deletion boundary.

Each generation declaration supplies the exact naming contract for its durable
generations and, separately, any interrupted candidates. Retention therefore
handles legacy content IDs, full artifact digests, and product-specific names
without a global filename assumption. Native package publication adds a
reachability pass after both architecture qualifications: it retains the active
and one rollback cohort per lane, derives the exact product/archive live set
from those manifests, and removes only known unreferenced store objects. The
reachability pass is always assessed because generic cache pruning can remove a
generation and thereby change the live product set without changing the package
task identity. The product-store root remains protected from generic clean and
cache-prune logic.

OCI retention belongs to the catalog rather than the runtime backend. Each
Collider-owned local repository family retains its active digest and declared
rollback generations. The backend lists parsed runtime state and removes only
the exact inactive references selected by Collider; it never performs a global
dangling-image sweep or infers ownership from tag spelling alone.

A recipe never derives another OCI image merely to copy in an operational
entrypoint. Specialized AOSP build and artifact processing, gfxstream,
Chromium build and artifact processing, and Swift target-runtime construction
reuse their owning dependency image. Each action declares the entrypoint script
as a hashed input, mounts it read-only, and selects its absolute container path
through the OCI execution contract. Changing one of these scripts invalidates
only its consuming task closure; it does not stream, import, unpack, or retain a
second copy of the dependency image's layers. The native builder's common
dispatcher remains part of its single stable image contract. Its separately
mounted SwiftPM overlay does not create a bootstrap-to-production derivative.

Recorded image-ID output is not sufficient evidence that a local OCI image
still exists. Before accepting a clean image-producing task, Collider compares
the recorded repository and digest with the runtime's current image state. A
missing or mismatched image makes the task dirty and reconstructs it through
the normal graph instead of attempting a registry fallback.

Default `collider cache status` reads only bounded metadata and shallow owned
roots. Apple Container usage, images, and persistent-workspace queries run
independently with bounded timeouts; an unavailable owner does not hide other
storage. `--measure-allocations` is the explicit recursive measurement mode.
Prune reports selected allocated bytes separately from post-operation physical
space recovered, because sparse files, hard links, and shared container layers
make those values semantically different.

## Recipe Rules

A recipe mounts source and host-acquired dependencies read-only, performs
high-churn compilation in persistent workspaces, and copies only final products
into bounded exports. Architecture-specific work never shares an intermediate
workspace. Compiler caches are separate from build trees so their retention and
reset behavior remains explicit.

Containers do not acquire dependencies or access external networks. Host
actions finish resolution and acquisition before the container action begins.
Run logs remain host-owned observations and are not build storage.

No recipe may retain a second host-backed intermediate path after it adopts a
persistent workspace. Socket and FIFO paths used by a running product are
runtime session state and do not become build intermediates.

## Reproducibility Boundary

Persistent workspaces may be reset or deleted at any time without losing an
authoritative input or output. A cold build after deleting all Collider-owned
volumes must reproduce the same declared artifacts. A warm build may reuse
workspace state, but task identity, host input fingerprints, and artifact
validation remain authoritative; volume contents never decide whether an action
is current.
