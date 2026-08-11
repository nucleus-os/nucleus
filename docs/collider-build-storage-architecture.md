# Collider Build Storage Architecture

## Invariant

The macOS checkout owns source, acquired inputs, credentials, provenance, and
finished artifacts. Linux build intermediates and compiler caches live only in
Collider-owned persistent workspaces. Container-local temporary state lives on
tmpfs. Every writable host mount is a bounded export declared as an action
output; an ordinary host input mount is always read-only.

Deleting every persistent workspace leaves the checkout capable of rebuilding
every product from its declared host inputs. A workspace is therefore cache
state, never source, provenance, or a publication boundary.

## Storage Classes

Collider exposes four disjoint storage classes to container actions:

- A host input is a read-only bind mount containing source, a downloaded input,
  an SDK, a lock, or a credential required by the action.
- A bounded export is a writable bind mount containing only the action's
  declared host-visible outputs. Collider models it as an output effect, not as
  scratch state.
- A persistent workspace is a named Linux filesystem owned by one logical
  component, artifact target, and role. Build trees and compiler caches use
  separate workspaces.
- Ephemeral state uses tmpfs. `/tmp` and the configured container home are never
  backed by writable host directories.

The type model enforces this boundary. `OCIMount` represents either a read-only
input or a bounded export. `OCIPersistentWorkspaceMount` separately represents
a named volume and carries its own read-only/read-write access. There is no
general writable host-mount mode and no action-specific host temporary
directory.

## Ownership and Lifecycle

Persistent workspace identity consists of its owner key, artifact target, and
role. Collider derives a checkout-scoped Apple volume name from that identity,
creates and validates the volume through Apple container's Swift API, attaches
it only for the action lifetime, and reports or removes it through Collider's
storage operations. A recipe declares capacity, filesystem, journal policy,
guest target, and access; it does not manipulate the backing image.

The Apple container service stores these volumes under
`/Volumes/NucleusBuild/apple-container-volumes`. OCI images, VM snapshots, and
the remaining service state stay under `NucleusOCI`. DiskImageKit is not part of
the build-workspace path because Apple container already owns sparse image
creation, EXT4 formatting, attachment, and exclusive-use enforcement.

The component graph is the workspace lifecycle registry. A workspace used by
exactly one component belongs to that component; a workspace intentionally used
by multiple components, such as the root Linux SwiftPM build tree, belongs to
the catalog rather than to any one consumer. `collider clean <component>`
acquires the same workspace locks as build actions and removes only that
component's inactive exclusive volumes alongside its declared host clean roots.
`collider cache prune` removes only inactive Collider-owned volumes whose
identities no longer exist in the current component graph. Dry-run reports the
same targets without deleting them, and cache status classifies owned volumes
as active, retained, or reclaimable.

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
