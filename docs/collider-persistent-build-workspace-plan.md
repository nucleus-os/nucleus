# Collider Persistent Build Workspace Plan

Status: active.

## Invariant

The host owns source checkouts, downloaded inputs, credentials, final artifacts,
and provenance. Reconstructible Linux-native intermediates and compiler caches
live on Collider-owned persistent block volumes formatted for Linux. Ephemeral
containers attach those volumes only for the duration of one declared action.
No build keeps a host bind-mounted output tree, no container performs network
access, and no component maintains both volume-backed and host-backed build
state after its migration phase completes.

A persistent workspace is cache state, never source or an artifact boundary.
Deleting every persistent workspace must leave a complete checkout capable of
rebuilding every product from declared host inputs. Final products remain
ordinary host files with normal Collider fingerprints, retention, inspection,
and publication behavior.

## Outcome

Collider provides one backend-neutral persistent-workspace contract. The Apple
container backend implements it with named sparse EXT4 volumes created through
the Swift `ClientVolume` API and attached through Virtio Block. Recipes declare
logical workspace ownership, capacity, target architecture, role, mount point,
and access. Collider creates, validates, initializes, attaches, reports, resets,
and prunes those volumes without shelling out to the `container` executable.

The migration removes VirtioFS from high-churn output paths while retaining it
for read-only source and downloaded-input mounts. A build container reads source
from the host, writes intermediates to Linux-native storage, and copies only its
declared final artifacts to a bounded host export directory.

DiskImageKit is not part of this design. Apple container already provides the
required persistent sparse block device, EXT4 formatting, attachment, and
exclusive-use enforcement. Runtime VM disks and downloadable product images
remain separate concerns.

## Ownership Matrix

| Data | Owner | Storage | Lifecycle |
| --- | --- | --- | --- |
| Git and Repo source | Monorepo or exact source manifest | Host APFS, read-only in containers | Source-control lifecycle |
| Downloaded archives and package inputs | Collider host downloader | Host cache, read-only in containers | Existing cache retention |
| Build intermediates | Component and target workspace | Named EXT4 volume | Resettable and prunable |
| Compiler cache | Component, target, and concurrency lane | Named EXT4 volume | Independent cache retention |
| Generated source consumed by host tools | Owning package | Host package directory | Existing generated-source contract |
| Final SDKs, images, packages, symbols, and manifests | Owning component | Host artifact or cache root | Existing artifact retention |
| Credentials and signing material | Host security boundary | Host-only input mount | Existing credential lifecycle |
| Run events and logs | Collider | Host run registry | Existing run retention |

## Persistent Workspace Contract

Add a value type to `ColliderCore` representing one persistent workspace mount.
It carries:

- a recipe-owned logical key;
- the artifact target and role;
- an absolute guest mount point;
- read-only or read-write access;
- declared logical capacity;
- filesystem and journal requirements; and
- labels supplied through the runtime configuration's managed namespace.

The logical key contains no host path and no generated physical volume name.
The Apple backend derives the physical name as
`collider-<checkout-digest>-<logical-key>-<target>-<role>`, shortening only the
human-readable fields when required by Apple's 255-character limit. The full
checkout digest and logical fields remain labels. The checkout digest is the
SHA-256 digest of the canonical repository root path, which prevents unrelated
clones from sharing mutable intermediates without adding persisted identity
state. Moving a checkout creates new workspace names and leaves the old names
explicitly reclaimable.

Declare each workspace as an action effect. The scheduler serializes every
action that attaches the same physical volume because Apple volumes permit one
active container attachment. Distinct component or architecture keys remain
concurrent. A workspace declaration that is missing from action effects is a
planning error.

Physical volume name, capacity, journal size, and host placement do not become
artifact inputs. Guest mount points and commands remain part of normal action
identity. Workspace contents never satisfy an undeclared input and never make a
task clean by themselves.

## Volume Configuration

Create named volumes explicitly before container configuration rather than
relying on implicit `-v` creation. Creation uses:

- driver `local`;
- format `ext4`;
- a recipe-declared sparse logical size;
- `journal=writeback:64m` for metadata recovery after interruption;
- the Apple default cached disk attachment;
- `fsync` synchronization; and
- managed Collider ownership labels.

Inspect an existing volume before attachment. Fail if its driver, format,
capacity, journal configuration, checkout label, logical key, target, or role
does not match the declaration. Do not silently replace or reinterpret a
volume.

New EXT4 roots are owned by UID/GID 0 and mode `0755`. Initialize each volume
with an idempotent root container that changes only the filesystem root to
UID/GID 1000. Production build actions continue to run as the unprivileged
builder with all capabilities dropped and privilege acquisition prohibited.
Never recursively change ownership on an established workspace.

Container cancellation deletes and verifies the ephemeral container while
retaining its workspaces. A subsequent action attaches the same workspaces and
lets the native build system recover its own interrupted state. Volume deletion
fails while any container references it.

## Capacity and Retention

Use sparse logical capacity so volume creation does not reserve its full size.
Initial declarations are:

| Workspace | Logical capacity |
| --- | ---: |
| AOSP product output | 300 GiB |
| AOSP ccache | 50 GiB |
| Chromium/CEF output | 300 GiB |
| Chromium/CEF compiler cache | 50 GiB |
| Swift target-SDK build root per architecture | 200 GiB |
| Swift target-SDK compiler cache per architecture | 50 GiB |
| Native SDK component build root | 100 GiB |
| Native SDK component compiler cache | 50 GiB |
| Linux SwiftPM build root per architecture | 100 GiB |

Report allocated bytes, not sparse logical size, in cache status. Warn through
the existing cache-status output when an owned volume reaches 80 percent of its
logical capacity or when the APFS container lacks enough physical free space
for the active build. Capacity changes require an explicit hard migration to a
new correctly sized volume; Collider does not resize a mounted build volume.

`collider cache prune` removes only volumes carrying Collider's managed label
and selected by the existing cache-retention policy. A detached named volume is
not automatically garbage merely because no ephemeral container currently
references it. Active attachments are never deletion candidates. Cache status
distinguishes active, retained, and reclaimable owned volumes from unrelated
Apple container volumes.

## Phase 1: Add the Engine Contract

Status: complete.

Add persistent workspace declarations, mount access, logical capacity,
filesystem requirements, and target/role identity to `ColliderCore`. Extend
action requirements with a persistent-workspace effect and teach graph
validation to reject undeclared, duplicate, relative, or overlapping guest
mounts.

Extend `OCIExecution` with persistent workspace mounts separately from host
bind mounts. Keep host bind validation unchanged. Reject a physical host path in
a logical workspace declaration and reject attempts to use a persistent
workspace as an action input or artifact output.

Teach scheduling to serialize shared volume attachment while preserving
concurrency between different logical keys. Cover read/write conflicts,
cross-target independence, action cancellation, identity stability, and invalid
mount layouts with behavioral engine tests.

Gate: the engine plans generic persistent workspaces without importing Apple
container modules or embedding Nucleus component names.

## Phase 2: Implement Apple Volume Ownership and Lifecycle

Status: complete.

Extend `ColliderAppleContainer` to create, inspect, initialize, attach, and
delete named volumes through `ClientVolume`. Pass named mounts through
`Flags.Management.volumes` so `Utility.containerConfigFromFlags` produces
`Filesystem.volume` attachments. Keep the existing Swift API container creation,
bootstrap, cancellation, and verified deletion path.

Derive physical names and ownership labels from the runtime configuration,
canonical checkout digest, and logical declaration. Create volumes with their
declared size and journal options. Validate every existing configuration before
use. Run the root ownership initializer only after creation, then attach the
volume to builder actions without elevated privileges.

Extend runtime disk usage and cache retention to enumerate Collider-owned
volumes. Add explicit owned-volume deletion to the backend; do not expose a
generic command that can delete unrelated Apple container volumes. Preserve the
current image-pruning behavior separately.

Exercise persistence across two ephemeral containers, exclusive attachment,
interruption cleanup, mismatched configuration rejection, initialized builder
ownership, disk-usage reporting, and protected deletion with integration tests
using the real Swift APIs.

Gate: two ephemeral builder containers exchange a file through one named
volume, cancellation leaves the volume reusable, and cache pruning cannot touch
an unrelated volume.

## Phase 3: Hard-Migrate AOSP

Status: complete. The AOSP action chain declares and attaches its target-
specific output and compiler-cache workspaces, keeps the Repo checkout and
first-party product inputs read-only, and limits host writes to the artifact
generation boundary. The migrated workspaces completed the full compile,
release signing, image assembly, validation, and publication graph. The
temporary migration implementation and superseded host-backed intermediates
are removed.

Create separate `nucleus_x86_64` output and ccache workspace declarations. Keep
the exact Repo source on the host as a read-only `/src` mount. Attach the output
volume as the nested `/src/out` mount and the compiler-cache volume at
`/ccache`. Set `OUT_DIR=out`, preserving AOSP and Siso's native source-relative
output contract while keeping the mounted checkout read-only. Set
`CCACHE_DIR=/ccache` and a bounded host-mounted `DIST_DIR`. Keep signing inputs
read-only and network disabled.

Make compile, signing, image assembly, and validation attach the same output
workspace sequentially. Produce target-files, OTA tools, images, symbols, and
provenance into the host export boundary as part of the owning action. Host code
no longer traverses AOSP intermediates or executes tools from a host-mounted
`out` tree.

Source materialization owns Repo revision validation and emits the resolved
manifest provenance consumed by compilation. The compile action does not run
`repo manifest` again. Soong owns incremental output invalidation, including
configuration-triggered install cleanup; Collider never runs an unconditional
`installclean` before the real build.

Perform one hard migration of the current case-sensitive host generation and
ccache. An ephemeral migration container copies regular files, directories, and
symlinks into the initialized volumes as builder UID/GID 1000. It excludes
`.path_interposer_log`, `.ninja_fifo`, and other live IPC endpoints. Verify the
copied Ninja graph and ccache statistics in the first attached builder. Remove
the migration implementation and the old host generation after the
volume-backed build produces equivalent signed artifacts. Do not retain a
fallback bind-mounted AOSP output path.

The AOSP output and ccache keys include the target architecture. A future
arm64 product receives distinct volumes and may build concurrently with the
x86_64 product.

Use existing Collider timing, run-log, Ninja, Siso, and ccache output to compare
the migrated warm build with the recorded VirtioFS baseline. Do not add probe,
qualification, or benchmark commands. The migrated build must preserve or
improve warm task duration, eliminate VirtioFS socket/FIFO cleanup handling,
and show the expected Ninja and compiler-cache reuse after interruption.

Gate: `collider build android-image` completes from the migrated volume,
restarts incrementally after cancellation, exports the same signed product, and
leaves no AOSP build intermediates under the host checkout or build root.

## Phase 4: Migrate Chromium and CEF

Move Chromium/CEF Ninja output and compiler cache to target-specific persistent
workspaces. Keep Chromium, CEF, depot-tools inputs, downloaded archives, and
generated configuration owned by their existing host source/cache boundaries.
Export only distributable Chromium/CEF products, symbols, manifests, and
provenance.

Give arm64 and x86_64 independent output and compiler-cache volumes so their
builds remain concurrent. Every sequential packaging or validation action that
needs host tools attaches the corresponding output volume instead of importing
the build tree onto APFS.

Delete the host-backed Chromium/CEF intermediate path after one successful hard
migration. Extend the existing product build and test lanes to verify cold
reconstruction, warm reuse, interruption recovery, and final artifact equality.

Gate: Chromium and CEF products build and package without a writable host output
mount, and both architecture lanes retain their existing concurrency.

## Phase 5: Migrate Native SDK Builders

Move Skia, gfxstream, Mesa, Vulkan-loader, React Native C++, Hermes, folly, and
other CMake/GN/Meson/Ninja intermediates into component-and-target-specific
workspaces. Keep separate workspaces for components that Collider schedules
concurrently; never introduce a shared volume that serializes independent
native builds.

Keep the staged native SDK at `~/.cache/nucleus/nucleus-native-sdk` as a host
artifact boundary. Each native builder exports only installed headers,
libraries, pkg-config metadata, tools, digests, and provenance into its owning
SDK candidate. Generated source that SwiftPM consumes remains under the owning
first-party package.

Move compiler caches into the same component concurrency partition. Remove
`core/.skia-build`, `react-native/.rn-build`, `react-native/.cxx-build`, and
equivalent host intermediate directories after their volume-backed owners pass
the existing build and test lanes.

Gate: the complete native SDK reconstructs from empty volumes, warm rebuilds
reuse native intermediates, and concurrent component builds never contend for
one volume.

## Phase 6: Migrate Swift Target-SDK Builders

Create independent arm64 and amd64 Linux target-SDK build and compiler-cache
workspaces. Keep the pinned `swift-sdk/source` closure on the host and mount it
read-only. Keep the official bootstrap compiler and downloaded Android Swift SDK
in host-owned caches. Build standard libraries, overlays, Dispatch, Foundation,
XCTest, and Swift Testing inside their architecture workspace.

Export only the assembled Linux Swift SDK components and provenance needed by
the host-side SDK assembly boundary. Preserve concurrent arm64 native and amd64
cross builds by never sharing an attached volume between them. Delete the
replaced host build roots after both target slices assemble into the same SDK
artifact and pass existing consumers.

Gate: `collider swift-sdk rebuild` succeeds from empty volumes, repeats with
warm reuse, and still produces one relocatable dual-architecture SDK artifact.

## Phase 7: Migrate Linux SwiftPM Product and Test Builds

Move architecture-specific Linux SwiftPM `.build` state into persistent
workspaces. Keep package sources, manifests, generated first-party source, and
resolved dependency inputs host-owned and read-only. Run compilation, linking,
and tests against the attached workspace, then export only declared executables,
libraries, test records, symbols, and package artifacts.

Use separate workspaces for arm64 and amd64 so SDK validation and product tests
remain concurrent. Do not move the macOS SwiftPM build directory into a Linux
volume and do not add a second SwiftPM package graph.

Gate: all Linux product and test lanes pass from empty and warm workspaces, host
source edits invalidate the correct SwiftPM work, and no Linux `.build` tree is
writable through VirtioFS.

## Phase 8: Apply the Boundary to Remote Development

Keep a remote developer's editable checkout in its declared source boundary.
Attach persistent Linux build workspaces for native, SwiftPM, browser, and AOSP
intermediates rather than storing them beside source. Reuse the same logical
workspace contract locally and on a future remote builder backend; backend
storage mechanics may differ, but ownership and artifact export do not.

Do not move editor state, user home data, credentials, or runtime VM disks into
Collider build workspaces. Those remain under their own remote-development and
virtualization lifecycle contracts.

Gate: deleting a remote development environment's build workspaces preserves
source and user state while forcing a complete reproducible rebuild.

## Phase 9: Complete the Cutover

Remove replaced host intermediate declarations, bind mounts, socket/FIFO host
cleanup, and storage-retention rules. Update Collider cache status, storage
ownership documentation, builder setup, and agent guidance to state the final
host-versus-Linux boundary.

Retain host bind mounts only for read-only source/download inputs, bounded
artifact export, credentials, and run logging. Audit every writable container
mount and require it to be either a declared persistent workspace, a bounded
artifact export, or ephemeral tmpfs.

Delete migration-only code and completed migration state. Move the durable
persistent-workspace invariant into Collider architecture documentation, mark
this plan complete, and remove it after architecture consolidation.

Gate: repository-wide container planning exposes no writable host build-
intermediate mount, every persistent volume has one declared owner and target,
and deleting all owned volumes leaves every product reproducible from host
source and declared inputs.

## Explicit Non-Goals

- Do not move Git or Repo source into container volumes.
- Do not permit network access inside build containers.
- Do not expose Apple volume administration as a general Collider CLI surface.
- Do not add a daemon, observer protocol, probe, qualification, or smoke command.
- Do not add remote execution or distributed caching as part of this migration.
- Do not fork Apple container or containerization for volume support already
  present in their public Swift APIs.
- Do not adopt DiskImageKit for build workspaces.
- Do not retain compatibility with the replaced host-backed intermediate paths.
