# macOS Host Storage Consolidation Plan

Status: complete

## Invariant

Collider-managed macOS host storage resolves only within conventional per-user
directories on the default macOS Data filesystem. Collider does not create,
mount, reserve, quota, or require custom APFS volumes. An explicit
user-selected publication or archive destination is outside this managed
layout; no Collider default path resolves onto it.

Linux source trees, build trees, compiler caches, and other workloads that need
case-sensitive filesystem semantics live inside sparse Apple-container volumes.
Those sparse volume images are ordinary files on the default macOS Data volume.
Loose host files never emulate Linux case sensitivity.

The final host layout is:

- `~/Library/Application Support/Nucleus/Collider` for durable service metadata
  and configuration.
- `~/Library/Developer/Nucleus/Collider` for the Apple-container application
  root, persistent container volumes, incremental build workspaces, and staged
  artifacts.
- `~/Library/Caches/Nucleus/Collider` for downloaded inputs and reproducible,
  prunable host caches.
- `~/Library/Logs/Nucleus/Collider` for service and Collider logs.
- `/Library/Nucleus/checkout` for the authoritative developer checkout, whose
  root-owned parent both accounts can resolve.

Collider resolves these locations through one typed host-storage layout. Static
contracts do not contain absolute home-directory paths. No compatibility path
continues to read or write `/Volumes/Nucleus*` after the cutover.

Phase 4 of the
[GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
supersedes the per-user placement of retained build state. Two accounts execute
on this host, so the container application root, volumes, caches, intermediates,
artifacts, and run records move to one machine-owned store outside every home.
The invariants above that concern filesystem policy rather than placement are
unaffected, and measurement since confirms them: no custom APFS volume is
created or required, and case-sensitive workloads stay inside sparse container
volumes on the default Data volume because a block device outperforms a shared
host filesystem by an order of magnitude on the metadata operations that
dominate build work. The authoritative checkout is `/Library/Nucleus/checkout`.

## Phase 1: Introduce the standard host-storage layout

Status: complete. `MacOSHostStorageLayout` resolves the standard per-user roots
through Foundation and owns every derived Collider storage class. Focused
layout coverage includes a home path containing spaces. Workspace cache
fallback uses the standard macOS cache root; explicit legacy environment values
remain in force until the hard cutover.

Add one `MacOSHostStorageLayout` value in Collider. Resolve the Application
Support, Caches, and Logs roots through Foundation's user-domain directory APIs.
Resolve `~/Library/Developer/Nucleus/Collider` from the current user's home
directory as the developer-storage root.

The layout owns every derived path used by Collider and the Apple-container
service:

- service support and generated launch-agent state;
- Apple-container application root, including its natural `volumes`
  subdirectory;
- host download cache;
- native and Android SDK caches;
- incremental host build state;
- staged artifacts;
- run and service logs.

Replace independent environment and contract path construction with this value.
Path identity remains stable for one user account and contains no machine- or
checkout-specific literals.

Gate: focused layout tests prove the exact directory mapping for an injected
home directory, including paths containing spaces. No production Collider code
constructs a `/Volumes/Nucleus*` path.

## Phase 2: Remove APFS policy from the builder contract and service

Status: complete. The builder contract and doctor contain no APFS volume,
quota, reserve, ownership, recoverability, or cleanup policy. The user-domain
installer renders the standard application, developer, cache, log, and
LaunchAgent paths, while Apple container owns its natural in-tree `volumes`
directory. The obsolete cross-volume migration helper and symlink checks are
removed. Activation remains part of the one-time data cutover in Phase 6.

Delete the builder contract's storage-volume inventory, volume ownership,
quota, reserve, recoverability, and cleanup-policy records. Delete doctor logic
that queries APFS containers or validates named mounts.

Make the login-session service installer create the standard user directories
with the current user as owner. Point the Apple-container API server at the new
application root and its in-tree `volumes` directory. Point launch-agent output
to the standard Logs directory. Apply a user-owned sticky Time Machine
exclusion to the reconstructible Developer root. Remove the cross-volume
`volumes` symlink and the migration script that exists only to maintain it.

The installer remains a user-domain operation. It does not use sudo, mutate
disks, or depend on a particular synthesized disk identifier.

Gate: the generated LaunchAgent and starter lint with standard paths, the
builder doctor resolves the same typed layout without `diskutil`, and no
service script names a custom volume. Phase 6 activates the generated service;
Phase 7 owns restart persistence and live health verification.

## Phase 3: Move case-sensitive workspaces behind container volumes

Status: implementation complete. AOSP declares independent protected source,
output, and compiler-cache volumes. Host-native preparation owns every network
operation. The host keeps a metadata-only partial-clone Repo cache, hydrates
every blob reachable from the exact locked revisions, and an offline container
copies that object store into the source volume before local-only checkout. The
migrated live workspace is qualified in Phases 6 and 7.

Declare persistent Apple-container source, output, and compiler-cache volumes
for every Linux workload that currently places a case-sensitive tree directly
under `NUCLEUS_BUILD_ROOT`.

Move the AOSP working checkout into a dedicated persistent source volume. Keep
the AOSP output and compiler cache in their existing independent persistent
volumes. Mount source read-only for ordinary builds and read-write only for the
source-materialization action.

The host owns all network access. It downloads the exact manifest, Git objects,
and repository inputs into a content-addressed cache under the standard Caches
directory. An offline source-materialization container consumes those inputs
and updates the case-sensitive source volume. The host cache is reconstructible
and prunable after the source volume contains the required locked revisions.
No container performs network access.

Apply the same invariant to future Linux source workspaces. A loose checkout on
the case-insensitive macOS Data volume is never a Linux build source merely
because the current revision happens not to contain a case collision.

Gate: AOSP source preparation succeeds with container networking unavailable,
the materialized Repo checkout matches every locked revision, and an incremental
AOSP build reuses both its source and output volumes.

## Phase 4: Convert build, cache, artifact, and log consumers

Status: implementation complete. The task graph uses the typed conventional
layout for build state, caches and SDKs, staged artifacts, and logs. macOS no
longer exports `XDG_CACHE_HOME`, and no production graph contains a custom
volume path. Phase 6 migrates the retained live state into these locations.

Move host-side build metadata and non-case-sensitive scratch state to the
Developer root. Move native SDK, Android SDK, downloaded archives, repository
inputs, and other reconstructible data to the Caches root. Move staged build
products to the Developer artifacts root and diagnostics to the Logs root.

Stop exporting a macOS-wide `XDG_CACHE_HOME`. Pass explicit cache locations to
the tools Collider owns. Preserve a tool's native cache convention when that
tool already resolves a correct macOS user cache directory.

Update every task identity and declared storage target to use logical storage
ownership rather than a volume name. The resolved absolute path participates in
an identity only when it changes the observable action result.

Gate: runtime, SDK, browser, and Android task graphs contain no
`/Volumes/Nucleus*` arguments or environment values, and clean task selection
does not change solely because the host-storage implementation moved.

## Phase 5: Simplify observation and cleanup

Status: implementation complete. Status reports default-filesystem capacity,
declared storage ownership, Apple-container disk usage, and sparse workspace
allocation without recursively measuring host trees unless requested. Source
workspaces are protected, while dry-run prune selects only declared
reconstructible storage and orphaned inactive volumes.

Replace APFS quota reporting with useful storage ownership:

- total and available space of the default Data filesystem;
- allocated size by Collider storage class;
- logical and allocated size of sparse container volumes;
- reclaimable run history, host cache entries, images, snapshots, and orphaned
  persistent workspaces.

Keep status bounded and metadata-first. Exact allocation measurement remains an
explicit operation. Prune removes only data owned by a declared reconstructible
storage class. Source volumes, active workspaces, staged artifacts, and the
authoritative checkout remain protected by ownership rather than by placement
on separate filesystems.

Gate: `collider cache status` returns promptly, `collider cache prune --dry-run`
identifies exact targets, and prune cannot cross from cache ownership into
source or artifact ownership.

## Phase 6: Perform the one-time data cutover

Status: complete. Apple-container state, persistent workspaces, host caches,
SDKs, staged artifacts, and logs operate from the conventional per-user roots.
The locked AOSP checkout is materialized into its protected persistent source
volume from host-provided offline inputs, and the former loose checkout is
retired. Each obsolete custom APFS volume contains only filesystem metadata;
none contains authoritative or uniquely expensive state.

Stop the Apple-container login agent and confirm that no Collider run or
container VM is active. Remove the incomplete `NucleusBuildNext` copy; it is not
a migration source.

Migrate data in bounded batches so the default APFS container never needs space
for a second complete copy:

1. Copy sparse Apple-container volumes into the new application root with a
   sparse-aware copy operation.
2. Verify each image's logical size, allocated block count, metadata, and
   contents before retiring its old copy.
3. Copy the remaining Apple-container application state and verify image and
   snapshot visibility through the API.
4. Move host caches, SDKs, artifacts, and logs into their standard locations.
5. Materialize the locked AOSP checkout into its new persistent source volume
   from host-provided offline inputs.
6. Retire the loose AOSP checkout and residual old build directories only after
   the source volume and incremental build state pass their gates.

This is a hard migration. Collider does not retain fallback lookup in old
locations and does not select between old and new layouts.

Gate: the old custom volumes contain no authoritative or uniquely expensive
state, and the complete retained working set operates from the standard layout.

## Phase 7: Verify the consolidated host

Status: complete. The Linux runtime suite passes against the generated Swift
6.4 target SDK, and a subsequent run reuses all native prerequisites and the
persistent SwiftPM workspace. The active Swift SDK generation is clean. The
browser source generation, dual-architecture Browser/CEF output and compiler
caches, protected AOSP source and output, and AOSP compiler cache are retained
at their conventional locations. Cache status and dry-run pruning complete
without touching retained state. Restarting the login-session Apple-container
service preserves its conventional application root and host-only network, and
the complete macOS builder doctor passes after restart.

Run the complete macOS builder doctor against the standard layout. Restart the
login-session Apple-container service and verify its application root, volume
inventory, network, logs, and restart persistence.

Verify representative incremental workflows in order:

1. Linux runtime build and tests.
2. Native and Swift SDK reuse.
3. Browser and CEF source, compiler-cache, and output reuse for both
   architectures.
4. Offline AOSP source preparation and incremental Android build.
5. Cache status and dry-run pruning.

Gate: each workflow reuses its migrated state, performs no container networking,
and emits no reference to a custom APFS mount.

## Phase 8: Remove the custom volumes and obsolete implementation

Status: complete. Collider contains no managed `/Volumes/Nucleus*` path, APFS
administration, quota model, mount repair path, or legacy storage fallback. The
obsolete internal volumes were resolved by live UUID, confirmed empty and
unused, and deleted. The internal APFS container now contains only the standard
macOS System, Data, Preboot, Recovery, and VM volumes. The explicitly
user-selected external `NucleusStorage` archive volume remains outside Collider
storage ownership.

Resolve every custom volume by live name and UUID immediately before deletion.
Delete `NucleusBuildNext`, `NucleusBuild`, `NucleusCache`, `NucleusOCI`,
`NucleusArtifacts`, `NucleusLogs`, and `NucleusDev` only after Phase 7 passes.
Never rely on previously observed `diskNsM` identifiers.

Delete migration-only code, APFS inventory models, quota documentation,
volume-oriented tests, mount repair instructions, and obsolete remote-development
storage assumptions. Update the remote-development plan so the authoritative
checkout remains in `/Library/Nucleus/checkout` and its recovery policy is independent
of build storage.

Gate: Collider resolves no managed path below `/Volumes`, the internal APFS
container contains no Collider-created volume, and a fresh setup provisions the
complete builder without sudo or disk administration. Explicit user-selected
publication and archive destinations remain outside this gate.
