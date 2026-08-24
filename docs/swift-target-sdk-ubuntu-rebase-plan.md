# Swift Target SDK Ubuntu Rebase Plan

Status: active

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

The ABI baseline is independent of the sysroot and stays where it is.
`NucleusLinuxABI.minimumGlibcVersion` is `2.38`, and `validateGlibcImports`
rejects any shipped artifact importing a newer GLIBC symbol. The SDK already
builds against a newer glibc than that baseline, so rebasing the sysroot does
not move the floor a distribution must meet, and `sdkDirectoryName` derives
from the baseline rather than the release, so no container path changes.

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

## Phase 3: Rebuild and Hold the Baseline

The target SDK is rebuilt for both architectures and the Linux runtime payload
is assembled from it. `minimumGlibcVersion` stays at `2.38`, so an artifact
that imports a symbol newer than the baseline is a failure to fix rather than a
reason to move the baseline.

Gate: `collider package linux-runtime` assembles both architectures' payloads
from the rebased sysroot, and no shipped artifact imports a GLIBC symbol newer
than the declared baseline.

## Risk Surface

The substantive unknown is Phase 3. Compiling against glibc 2.43 headers while
holding artifacts to a 2.38 symbol ceiling is exactly the arrangement that
surfaces newer symbol versions, and each one is a real incompatibility with the
distributions the packages target rather than a validator being fussy. The
count is not knowable before the rebuild, which is why the rebuild and the
ceiling are one phase: the failures are the phase's work.

The bootstrap compiler is a Swift.org toolchain built for Ubuntu 24.04, running
on a 26.04 image. That combination is already what runs today, so the rebase
does not introduce it, but it is the thing to look at first if the rebuilt SDK
misbehaves in a way the package versions do not explain.
