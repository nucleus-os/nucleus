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

The workspaces this phase replaced are still resident. Retiring the per-target
identity left `chromium-source-linux-arm64-glibc-source` and
`chromium-source-linux-x86-64-glibc-source` claimed by no declaration, holding
38 and 39 GiB beside the 45 GiB of the shared tree that replaced them. Nothing
reclaims them on its own: a `StorageDeclaration` governs a host directory, and
these are container volumes, which `collider cache prune` collects once no
declared identity claims them. That is deliberate -- discarding forty gigabytes
should not be a side effect of a build -- so it is a step to be taken, not a
defect to be fixed.

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
pays none, because the host reads its own filesystem natively, and that is the
only variant that retires the open-file exposure rather than bounding it.

The host variant needs no `e2fsprogs`. `ContainerizationEXT4` is already
vendored and formats an ext4 image from Swift, without a mount and without
root, so the host build has no tooling prerequisite the container build avoids.
`SourceImageAssembly.SourceTreeImage` is that builder: entries are visited
shallowest first and sorted within a depth, so the shallowest name for a
multiply linked file holds the inode, and every timestamp is fixed at the
epoch, because a checkout stamps its own mtimes and preserving them would give
two builds of identical content two addresses.

Three things the first implementation established, none of which the plan
anticipated:

The image is byte-reproducible, through a fork. `ContainerizationEXT4` stamped
a fresh filesystem UUID and read its own wall clock, so two images of one tree
differed. `nucleus-os/containerization` adds a `Formatter.Reproducibility` that
supplies both, reaching every value the formatter invents rather than the
obvious ones: leaving the root inode, `lost+found`, and filled-in parent
directories on the wall clock still left thirty-two differing bytes. Every
addition is optional and defaults to the existing behaviour, so it is
upstreamable and the fork is meant to be temporary.

Gate evidence: [protected-main run 34083694012](https://github.com/nucleus-os/nucleus/actions/runs/34083694012)
verified `95fabbe3` and passed `twoImagesOfOneTreeAreByteIdentical` on the
builder account, which is a stronger result than the one that motivated it:
reproducibility holds across accounts and caches, not only across two runs in
one shell. The stale-scratch recovery this required locally did not recur
there, so a resolution that has never seen the old URL needs no repair.

Keying the artifact by source id instead was the alternative and was rejected.
That is the same hand-maintained key this phase exists to delete, relocated
from `.nucleus-source-id` into a task declaration, and it would exempt the
image from the content-based consumer assessment every other artifact obeys.

Repointing a dependency at a fork is a one-time cost the graph resolver does
not absorb. A resolution scratch records the URL each identity resolved to, and
`--only-use-versions-from-resolved-file` forbids the re-resolution that would
correct it, so a machine that has already resolved reports a clone failure for
a URL that is reachable. Recovering means re-resolving once in an environment
that can clone. Every package in the closure must also name the same URL:
`third-party/container` depends on containerization too, and one identity
resolving to two URLs is a conflict.

Fidelity is proven for files, permissions, symbolic links, and hard links.
Proving the last needed a reader that could be asked. `EXT4Reader.export`
answers by writing an archive, and an archive keeps a hard link's two names
only if its format and extractor agree on ordering, so a lost link and a lossy
export look identical -- which is what the first attempt saw. The fork adds
`EXT4Reader.entries()`, reporting each name with the inode it names, so two
names for one file are visible as two entries sharing an inode rather than as
two files with equal contents.

Writing that found a second omission worth naming: a name reusing an inode the
reader has already seen is given no tree node, because the tree models the
filesystem's shape and a hard link adds a name rather than a shape. An
enumeration walking only the tree reproduces exactly the blindness it exists to
remove, so it merges the reader's hard-link table as well.

A container attaching the image is still required, but for consumers rather
than for this gate; what it would add is that the guest kernel agrees, not
that the image is right. It also answers a question only a container can:
several consumers attach one image at the same time -- two artifact
assemblies, two test runs -- so the attachment task reads the image from two
containers concurrently and requires them to agree. Whether a read-only image
can be shared is a property the mechanism has to have, and finding out four
hours into a build is the expensive way to learn it.

Gate evidence: [protected-main run 34087038233](https://github.com/nucleus-os/nucleus/actions/runs/34087038233)
verified `3eeb3b62` with every source-image behaviour passing on the builder
account, which completes the fidelity proof this phase requires before any
consumer moves to the image.

Building the real tree costs 315 s. That is the whole prepared source
generation -- 29.1 GiB across 1,197,620 entries, more than twice the file count
this plan estimated -- written on the host by
`sourceTreeImageScaleMeasurement`, which is opt-in behind
`COLLIDER_MEASURE_SOURCE_IMAGE`. Five minutes per source revision, paid once
for every product and architecture that reads it, is a cost this phase can
carry.

Measure it in release. The same tree takes 1,478 s built by a debug binary, a
forty-two-fold difference, and a profile puts two thirds of that debug time in
`FilePath.ComponentView._invariantCheck` -- swift-system re-validating a path
on every construction. `ColliderSelfComponent` already records the same effect
for the test bundles. Any host-side measurement of path-heavy work in this
repository is meaningless in debug, and this one would have concluded the host
build takes seven hours and abandoned the phase.

The formatter's four-kilobyte transfer buffer is not the cost, and `create`
takes a `fileBuffer` to replace it. Supplying four megabytes measured 35.5 s
against 31.9 s without on the same subtree, so the parameter is left alone.

Consumers attach the image as a read-only block device. The runtime carries
that primitive already: `Filesystem.block(format:source:destination:options:)`
builds a `Filesystem` whose `FSType` is `.block`, `ContainerConfiguration`
exposes `mounts` as a public array of them, and the guest receives it over
virtio-blk. An ext4 image built anywhere on the host is therefore mountable as
it stands, with no volume, no service change, and no copy.

The first attempt did not find that, and the reason is worth recording because
it is a mistake this plan could make again. Collider composes container
requests as command-line strings -- `name:/target:ro` -- and hands them to
`Utility.containerConfigFromFlags`, which parses them with `Parser.mounts`.
That parser accepts `virtiofs`, `tmpfs`, and `volume`, and rejects everything
else as an unsupported mount type. Read from there, a named volume looks like
the only way to give a container a filesystem, and the work turns into finding
a way to smuggle an image into one: adopting a prebuilt image in the volume
service, which cannot run because the service is an installed root-owned
binary and Collider links only the client; or writing the image into the
volume's block file behind the service's back, which couples Collider to an
on-disk layout it does not own. The restriction is in the command-line
grammar, not in the runtime. A capability should be looked for in the API
before the surface that happens to be in use is taken for the boundary.

So the execution declares the image and the runtime mounts it, and none of the
following is needed: a `source` driver option, a workspace established from an
image, or a fork of the volume service. What a source image is stops being a
workspace with capacity, residency, and reconciliation semantics -- which is
why declaring one dragged four retention invariants into a task that wanted to
read a file -- and becomes what it always was: an artifact, mounted.

`test.source-image.attachment` qualifies that on every revision. It builds a
fixture tree, writes an image from it, mounts the image read-only as a block
device, and requires the guest to report one inode under both of a hard link's
names, the modes, the symbolic link's target and the file's contents. The tree
is a fixture rather than the prepared Chromium source, because what is in
question is the mechanism and a fixture that fits in a second exercises it as
completely as one that takes five minutes.

The first guest to read an image reported four of five facts and
`cat: /source/readable: Permission denied`. The image was right: it carried
the mode the tree had, and the tree had 0600 because a written file takes the
writing process's umask and nothing had said otherwise. A guest runs as the
builder rather than as the owner an image records, so a fixture that does not
state what it grants is one the container cannot read. The fixture states its
modes now and the guest confirms them, which is the difference between a test
that assumes a permission and one that checks it.

Gate evidence: [protected-main run 34155852540](https://github.com/nucleus-os/nucleus/actions/runs/34155852540)
verified `355ff322`, and the guest reported all six facts -- inode 14 under
both of the hard link's names, 755, 644, the link's target, and the contents.
The mechanism this phase rests on is qualified end to end: an image built on
the host, addressed by its content, mounted read-only as a block device, and
read correctly by a kernel other than the library that wrote it. What remains
is to point it at the prepared Chromium tree.

Pointing it there found a defect this plan had no reason to expect, and it is
the reason the tree alone was never enough. The Linux sysroots are Debian roots
carrying names that differ only in case -- `xt_CONNMARK.h` beside
`xt_connmark.h`, `ipt_ECN.h` beside `ipt_ecn.h`, and a `sys` directory beside
`SYS` -- and the host volume is case insensitive APFS. The copy `gclient
runhooks` leaves in the tree is therefore already missing twenty-four entries
of the arm64 archive's 20,824, and nothing noticed, because `materialize-source`
deleted that directory and re-extracted the archive onto a filesystem that can
hold both names:

    rm -rf "$sysroot" && mkdir -p "$sysroot" && tar mxf "$archive" -C "$sysroot"

That repair was load bearing, and an image built by walking the tree would have
carried the damage instead -- a build compiling against a sysroot missing eight
netfilter headers, failing somewhere unrelated hours later, or worse succeeding.
So the image writer performs the repair rather than inheriting it: an overlay
reads the archive and writes its entries into the image directly, and the
tree's copy of that directory is not walked at all. Nothing is staged, so no
name has to survive a round trip through a filesystem that cannot represent it.
Extracting on the host before imaging was the obvious design and is the wrong
one for exactly this reason.

Ownership is the second thing the tree alone does not settle. An ext4 image
records an owner per inode; the copy this replaces untarred with
`--no-same-owner`, leaving every file owned by the builder that extracted it. A
root-owned image would grant a consumer only what the mode grants everyone, and
the tree is not uniformly world readable -- `source-provenance.json` is 0640 and
the sysroot's own `./debian/` is 0750. The image therefore records the identity
a container runs as, stated with the type an execution states it with so the
two cannot drift apart, and the attachment task proves it by reading a file
only its owner may read.

Timestamps interact with the build tool in a way worth stating. Every entry is
written at one fixed time, because the image is addressed by its content and a
checkout stamps mtimes of its own; that is what makes two preparations of one
revision agree. Siso caches an input's digest against the mtime it last saw, so
across two source revisions an unchanged mtime could let it keep a digest for
content that changed. The build entrypoint already learns that the source
identity moved -- it re-runs `gn gen` when it does -- so that is where Siso's
filesystem state is dropped, which makes it read the tree again rather than
remember it.

Every pin bump on the fork repeats the resolution cost above, not only the
first repoint. A scratch that has resolved a revision cannot fetch a newer one
under `--only-use-versions-from-resolved-file`, and the recovery is the same
single re-resolve in an environment that can fetch.

An image written under the tree it reproduces makes the walk read the image it
is still writing. The first attempt grew past 128 GiB from a two-file fixture
before the formatter refused it, so the builder now rejects that arrangement by
name.

If the container stack cannot attach one image read-only to several containers
at once, clone the image per consumer. On APFS that is a copy-on-write clone:
metadata only, no file traversal, and the clones share storage. The vendored
containerization stack already clones block images.

Deleted: `materialize-source`, the `.nucleus-source-id` protocol, the `rm -rf`
wipe-and-refill, the writable source workspace, `chromiumSourceWorkspace` and
its residency justification, and the source lock. A reproducible
content-addressed artifact needs none of them, and each consumer -- the four
product builds, the CEF and browser artifact assemblies, and the two ozone test
runs -- now attaches the image read-only where it used to mount the workspace.

The source lock and the serialization it caused are not the same thing, and
only one of them is gone. The lock existed because a shared tree was refilled
in place and the refill was not atomic; an image is written once, never
rewritten, and opened read only, which leaves that lock nothing to guard. What
remains is capacity, which Phase 1 recorded as deliberate: each build asks for
twelve jobs of twenty-four cores, so four at once would divide the machine
rather than multiply it. That claim is now made under its own name,
`chromium-build-capacity.lock`, so removing it later is a scheduling decision
made on measurement rather than an accident of renaming. The wall clock that is
actually recoverable is in the compiler cache and in Phase 3.

The workspace this phase retires is still resident, exactly as Phase 1's were:
`chromium-source` holds about 45 GiB claimed by no declaration now, and nothing
reclaims a container volume on its own. That is a step to be taken with
`collider cache prune`, not a defect to be fixed.

Fidelity was the risk worth naming, and it is settled for files, permissions,
symbolic links, hard links, ownership, byte reproducibility, and the
case-colliding names only the overlay path can carry. What is not yet settled
is the tree at full scale: the attachment task proves the mechanism on a
fixture, and only a Chromium build proves that 1.2 million entries and 29 GiB
arrive intact and readable.

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
