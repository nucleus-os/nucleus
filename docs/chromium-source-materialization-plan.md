# Chromium source materialization

Status: active

## Invariant

The prepared Chromium tree at a given source revision is a pure function of
pinned inputs, and every consumer reads it without writing to it. It is
therefore an artifact, and the build graph must model it as one: produced once,
addressed by content, shared by every product and architecture that reads it,
and reclaimed by the same retention rules that govern every other output.

A materialized tree that is instead modeled as a mutable workspace is a defect
independent of whether the current build succeeds, because three costs follow
from the modeling and not from the work: the tree is copied once per
architecture, its freshness is tracked by a cache key the graph cannot see, and
the copy that establishes it is not atomic.

## Established state

`browser.source` produces a host directory: a gclient checkout of the pinned
revisions plus the Linux sysroot archives and a provenance record. That
directory is immutable once written and is addressed by a source id.

A persistent workspace is an Apple container volume backed by a single
`volume.img` holding an ext4 filesystem. It is a block device to the container,
not a shared host directory, which is why builds reading `/source` get native
block throughput rather than paying the host file-sharing layer per read.

## The defect

`chromiumSourceWorkspace` declared a 64 GiB read-write workspace keyed by
artifact target, and `materialize-source` filled it:

    find /source -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar -C /host-source -cf - chromium linux-sysroot-archives \
      source-provenance.json | tar -C /source --no-same-owner -xf -

Every consumer mounts that workspace read-only -- the product build, the CEF
artifact assembly, and the browser artifact assembly. The only writer is the
materialization step, and it writes the same bytes whatever target asked for
it, because nothing in the copy is target-specific.

Keying the workspace by target therefore bought nothing and cost a second full
copy. Around half a million files, read out of the host mount, with both
architectures materializing at once. On 2026-09-01 that exhausted the host's
system-wide file table and failed the sweep:

    tar: chromium/src/third_party/sqlite/src/test/analyze9.test: Cannot stat:
      Too many open files in system
    Error: Too many open files in system
      task: browser.browser.arm64.build
      command: materialize-source fd51051519b837fadac158bb

`Too many open files in system` is ENFILE, the machine-wide table, not a
per-process limit. A serial `tar` holds one file at a time, so reaching a
491,520-entry table means the host file-sharing layer retains a descriptor per
file it serves. Cost scales with files traversed, not with concurrency, which
is why halving the traversals bounds the problem without removing it.

Two further costs come from the same modeling. `.nucleus-source-id` is a cache
key maintained by hand, parallel to the content addressing the graph already
performs and invisible to it. And the wipe-and-refill is not atomic: a run
killed between the `rm -rf` and the end of the `tar` leaves a tree that is
partial and unmarked, recoverable only by another full copy.

## Phase 1: One materialized tree

Give the source workspace no artifact target, so one tree serves every product
and architecture. `PersistentWorkspaceIdentity.artifactTarget` is optional for
exactly this reason: source belongs to no single target.

Sharing the tree means the two builds can no longer materialize concurrently,
because the refill is not atomic. Both product builds therefore take one shared
source lock, which serializes them outright. That is coarse and deliberately
temporary: the lock exists only while the tree is mutable, and Phase 2 removes
the mutability rather than widening the lock.

Achieved state: one `chromium-source` workspace rather than one per
architecture, halving both the resident storage and the traversals that
exhausted the file table. `collider verify all` plans 138 tasks with no error
under protected-main and local-development authority alike.

The lock costs wall clock, and more of it than the reasoning above accounted
for. A task lock serializes whole tasks, so the Chromium builds no longer
overlap -- and there are four of them, browser and CEF for each architecture,
not the two this reasoning first counted. Measured on 2026-09-02 they were
4h04m, 4h08m, and a CEF build still running at 3h38m, against under nine
minutes for every artifact and packaging task in the sweep combined. A cold
sweep is about seventeen hours.

Serializing them is deliberate rather than merely tolerated: each build asks
for twelve jobs on a twenty-four core host, so two at a time would divide the
machine rather than double the throughput. What the serialization does require
is that a cold sweep be bounded by measurement instead of by GitHub's
360-minute default, which is what cancelled the runs on 907fa51e and 3579b208.

Status: complete.

## Phase 2: The prepared tree becomes an artifact

Produce the prepared tree as a content-addressed read-only ext4 image keyed by
source id, containing exactly what `/source` holds today: the chromium tree,
the extracted sysroots, and the provenance record. Consumers attach it
read-only.

Where the image is built is the decision this phase makes. Building it inside a
container, reading the host tree through its mount once, reuses the existing
mechanics and pays one traversal per source revision. Building it on the host
with a pinned e2fsprogs -- `mke2fs -d` populates an ext4 image from a directory
without mounting it or requiring root -- pays none, because the host reads its
own filesystem natively. Take the container first, because it is a strict
improvement over Phase 1 and it settles the fidelity question; treat the host
as a follow-on once the image is trusted.

If the container stack cannot attach one image read-only to several containers
at once, clone the image per consumer. On APFS that is a copy-on-write clone:
metadata only, no file traversal, and the clones share storage. The vendored
containerization stack already clones block images.

This phase deletes `materialize-source`, the `.nucleus-source-id` protocol, the
`rm -rf`, the source lock Phase 1 introduced, and the residency justification
below, because a reproducible content-addressed artifact needs none of them.
Retiring the lock makes concurrent product builds possible again, though on a
twenty-four core host that is a scheduling choice rather than an automatic
gain. The wall clock that is actually recoverable is in the compiler cache and
in Phase 3: a cold sweep is four full builds, and almost every sweep should be
finding most of its objects already compiled.

Fidelity is the risk worth naming: the Chromium tree carries symlinks,
hardlinks, and executable bits that the image must preserve exactly. Prove the
image against the tree Phase 1 materializes before moving any consumer to it.

## Phase 3: Build each generation from its predecessor

Phases 1 and 2 reduce how many times the tree is materialized and what it
costs to read each file. Neither reduces how many files are read, which stays
at the whole tree for every source revision.

That is the dominant cost in practice, because the common revision is small.
Rolling one dependency changes a handful of files and produces a new source id,
and the id is what selects the tree: generation `fd51051519b837fadac158bb`
became `10255f992ea45e6120f7966e` for a one-line change to a single Dawn
source file, and the whole tree was checked out and materialized again for it.
During a milestone bring-up that is the normal iteration, not an unusual one.

Content-addressed identity does not require wholesale construction. A new
generation can be cloned from the previous one and then reconciled: on APFS
`clonefile` copies a tree copy-on-write without reading it, so only the files
that actually differ are written. The identity stays derived from content; only
the construction becomes incremental.

This composes with Phase 2 rather than competing with it. An immutable image
resists patching in place, so the delta belongs in construction: the new image
is built from a cloned predecessor and the differing files, not from a fresh
walk of the host tree. Where no predecessor exists the full path from Phase 2
still applies.

The property to hold onto is that a generation built incrementally must be
indistinguishable from one built whole. Reconciliation has to account for
deletions and mode changes, not only content, and it is worth proving by
building one generation both ways and comparing them before trusting the fast
path.

## Non-goals

- The build does not read the source through the host mount. AOSP references
  its git object store that way because the store is read during checkout and
  rarely after. Chromium's source is read continuously by the compiler for
  hours, so the copy into block-backed storage is what buys build throughput.
  The defect was never that the tree is copied; it was that an immutable tree
  was copied twice into mutable per-target volumes.

## Risk surface

Sharing one source workspace also widened what a leaked container costs. A
cancelled run could leave its container alive and reparented to init, still
holding every workspace it mounted, because container cleanup is deferred to an
asynchronous call that a killed process never makes. With a workspace per
target that stranded one architecture; with one shared tree it strands
everything, and the symptom is an invalid storage attachment several minutes
into the next run rather than anything naming the cause. Reclaiming containers
when a run takes the machine's execution admission is what bounds this, since
holding the admission means any container that exists was left by a run that is
already over.

The host's `kern.maxfiles` is 491,520 and a desktop session already holds
around nineteen thousand descriptors. Phase 1 halves the traversals but a
single cold materialization still approaches that ceiling, so the limit is
worth raising independently of this plan. The retention of a host descriptor
per file served is worth measuring directly rather than inferred from the
failure, because every estimate of remaining headroom depends on it.
