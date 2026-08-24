# Swift Target SDK Ubuntu Rebase Plan

Status: complete

## Invariant

The Linux target sysroot is built from the Ubuntu release the builder image
runs, and it is closed under dependency: a library the sysroot ships is a
library whose own dependencies the sysroot ships. What a product may link
against is decided by the pinned sysroot, and what it may import is decided by
the ABI baseline, which is a separate statement.

## Current State

The builder image is already Ubuntu 26.04:

```
FROM docker.io/library/ubuntu:26.04@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb
```

The target sysroot it builds against is Ubuntu 24.04. `target-sdk-inputs.json`
pins 63 packages per architecture at noble versions, `SwiftTargetSDKColliderRecipe`
passes `--distribution-version 24.04` and names the result `ubuntu-noble.sdk`,
and the sysroot carries glibc 2.39 while the image carries 2.43.

The sysroot is also not closed under dependency. It ships `libXdmcp.so.6` but
not `libbsd.so.0`, which that library needs, nor `libmd.so.0`, which libbsd
needs, on either architecture. ELF staging resolves every dependency to check
its architecture, so the gap stops a payload being assembled. It was invisible
while staging resolved against the builder image's own `/lib`; naming the
sysroot explicitly is what surfaced it.

The ABI baseline is a separate statement from the sysroot, but not an
independent one. `validateGlibcImports` rejects any shipped artifact importing
a GLIBC symbol newer than `NucleusLinuxABI.minimumGlibcVersion`, and that holds
below the sysroot only where the newer glibc has not re-versioned a symbol the
runtime calls. Across 2.38 to 2.39 nothing it calls moved, which is why a 2.38
ceiling over a 2.39 sysroot worked. Across 2.38 to 2.43 thirteen libm functions
moved, so the baseline follows the sysroot to 2.43.

Two facts make the rebase smaller than it looks. Every one of the 63 packages
exists in resolute under the same name, including `libgcc-13-dev` and the
LLVM 18 series, so no package is renamed and no toolchain series moves.
`swift-sdk-generator` is already a `nucleus-os` fork, so teaching it a new
release is a first-party change to a repository this project owns rather than
a divergence from an upstream it tracks.

## Phase 1: Teach the Generator the Release

The `Ubuntu` enumeration in the `swift-sdk-generator` fork gains `resolute`:
the case, the `26.04` mapping in `init(version:)`, the `version` property, and
its required packages, which are `libgcc-13-dev`, `libicu78`, and
`libstdc++-13-dev`. The fork carries the change and the source closure points
at the revision that has it.

The generator is first because nothing else can be validated without it: it
rejects an unknown release outright, so a rebased lock would fail before any
package was read.

Gate: the generator accepts `--distribution-version 26.04` and reports the
required packages for it, and the pinned source closure names the fork revision
that added it.

Status: complete. The fork carries `resolute` at `66a4e8e` on
`nucleus-ubuntu-2604`, and the source closure points at it. The release maps in
both directions and declares `libgcc-13-dev`, `libicu78`, and
`libstdc++-13-dev`; only the ICU soname moves from noble. The fork's own
distribution tests cover the new release in both directions and pass.

## Phase 2: Repin the Sysroot

`target-sdk-inputs.json` pins every package at its resolute version for both
architectures, taken from the release's own package index rather than composed
by hand. `libbsd0` and `libmd0` join the set, which closes the gap that stops
payload assembly. `SwiftTargetSDKColliderRecipe` passes `26.04` and names the
result for the release it is.

Gate: the sysroot for each architecture contains every SONAME its own contents
name, `libXdmcp.so.6` resolves `libbsd.so.0` and `libbsd.so.0` resolves
`libmd.so.0` within it, and every pinned URL matches the digest recorded beside
it.

Status: complete for the lock; the sysroot itself is produced by Phase 3. All
126 entries are repinned at their resolute versions from the release's own
package index, and `libbsd0` and `libmd0` are added per architecture. Every
package kept its name, so nothing is renamed and no toolchain series moves.
Digests were verified end to end for the added packages and for `libc6` and
`libxdmcp6` on both architectures, and the remainder are verified by the
download tasks that consume them. The recipe passes `26.04` and names its
output `ubuntu-resolute.sdk`.

## Phase 3: Rebuild and Hold the Baseline

The target SDK is rebuilt for both architectures and the Linux runtime payload
is assembled from it. `minimumGlibcVersion` is `2.43`, matching the sysroot,
because the symbols that forced the question are in the Swift runtime itself
rather than in Nucleus code that could avoid them.

Gate: `collider package linux-runtime` assembles both architectures' payloads
from the rebased sysroot, and no shipped artifact imports a GLIBC symbol newer
than the declared baseline.

Status: complete. `collider package linux-runtime` assembles and qualifies both
architectures' complete cohorts from the rebased sysroot, and the highest GLIBC
version any of the 33 shipped objects per architecture imports is 2.43, which
is the declared baseline exactly. The same scan at the former 2.38 floor still
reports ten runtime libraries, so the baseline moved because it had to rather
than because the check was weakened.

The baseline moved because the symbols are the Swift runtime's own. SDK
validation reported `libFoundation.so imports GLIBC_2.43, newer than
GLIBC_2.38`; reading every built library rather than the first to fail showed
fifteen distinct symbols, thirteen of them libm functions glibc 2.43
re-versioned, across twenty runtime libraries including `libswiftCore`,
`libFoundation`, and `libswiftGlibc`. Nucleus code cannot avoid them.

Closing the sysroot took three distinct repairs, and the durable one is that
closure is a property of two graphs rather than one.

The sysroot had a second definition. Two checked-in meson cross files wrote it
as a literal, so moving the baseline moved only the paths Collider derives and
gfxstream compiled with `--sysroot` naming the old sysroot and `-isystem`
naming the new one. A command-line `-D` option replaces a machine file's
`[built-in options]` rather than merging with them, so the half naming the
sysroot was the half that lost. Both files are now generated where they are
used, from the constant the rest of the toolchain paths derive from.

The pkg-config graph was open. PAM 1.7.0 ships a `pam.pc` that 1.5.3 did not,
declaring `Requires.private: audit`, and `audit.pc` declares
`Requires.private: libcap-ng`. SwiftPM resolves `.pc` files itself and treats a
missing one as a warning, so it dropped every flag `pam.pc` would have
contributed and the PAM helper linked with no `-lpam`, failing on undefined
symbols rather than on the configuration that caused them.

The ELF graph was closed only one level deep, which predates the rebase.
Assembly walks the whole dynamic closure and requires every undefined symbol in
it to be defined somewhere in it, so it descends into host-provided libraries
too: their exports are what satisfy the artifacts, which is why the walk cannot
stop at a library the target supplies. The pinned set is now that transitive
closure — 88 packages per architecture, computed by resolving each unresolved
SONAME against the release's own file index, fetching it, and rescanning until
nothing was missing, with every digest verified against the downloaded package.
`dri_gbm.so` names a Gallium library the closure excludes, correctly: it is a
GBM backend loaded by name at runtime, and no dependency in the graph declares
it.

They are not avoidable by changing Nucleus code: the Swift runtime calls them,
and the sysroot it links against binds them. Holding the ceiling below the
sysroot would require forcing older symbol versions when linking the runtime
and maintaining that list as glibc re-versions more. The baseline moves to
2.43 instead, and Nucleus supports Ubuntu 26.04 and newer.

## Risk Surface

The unknown in Phase 3 resolved against the rebase's original premise. The
count was fifteen and the symbols were in the Swift runtime rather than in
Nucleus code, so there was nothing to fix short of a compatibility layer, and
the baseline moved. The cost is stated rather than hidden: Ubuntu 24.04,
Debian 13, and RHEL 10 no longer run a Nucleus payload.

The bootstrap compiler is a Swift.org toolchain built for Ubuntu 24.04, running
on a 26.04 image. That combination is already what runs today, so the rebase
does not introduce it, but it is the thing to look at first if the rebuilt SDK
misbehaves in a way the package versions do not explain.
