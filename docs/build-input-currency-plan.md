# Build input currency

Status: active

## Invariant

Every third-party input the Nucleus build consumes is acquired from an immutable
location, is pinned at a revision the build actually compiles or links, and
tracks upstream at a version chosen deliberately rather than by drift. Three
conditions are defects independent of whether the current build succeeds: an
acquisition URL whose content can be withdrawn upstream, a pinned revision that
no task builds, and a recorded resolution that differs from the one the
supported build path produces.

## Established state

The following inputs are current against upstream and move only with the
contract that pins them. They are not in scope below.

- The Swift 6.4 source closure. `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-26-a`
  is the newest tagged 6.4 snapshot upstream, and all eight `swift-sdk/source`
  submodules sit on it consistently.
- The five React Native C++ submodules: folly `2024.11.18.00`, glog `0.3.5`,
  fmt `12.1.0`, double-conversion `1.1.6`, fast_float `8.0.0`. These match React
  Native 0.87's `gradle/libs.versions.toml` exactly and follow React Native.
- `swift-sdk/source/libxml2` at `v2.11.5`, which is the value upstream's own
  `utils/update_checkout/update-checkout-config.json` pins for every 6.x scheme.
- The AOSP source graph at `android-17.0.0_r1` with Repo 2.65.

## Phase 1: Immutable target SDK package acquisition

`swift-sdk/target-sdk-inputs.json` acquires 16 runtime and 88 SDK Ubuntu
packages per architecture from live `ports.ubuntu.com` and `archive.ubuntu.com`
pool paths. The recorded SHA256 for each package establishes integrity but not
availability: a pool path holds exactly the current version of a package and
loses the file when a new one publishes. Several pinned packages carry
stable-release-update suffixes, `libgbm-dev_26.0.8-1ubuntu0.3` among them, and
those are the ones certain to be superseded. The failure is a cold-rebuild 404
on an input whose replacement is a different version than the one every recorded
hash and every dependent task identity describes.

`collider/images/native-builder/native-builder-inputs.json` already demonstrates
the correct shape by acquiring its packages from `snapshot.ubuntu.com` under an
explicit timestamp.

The risk is no longer hypothetical. Of the 208 pinned packages,
`libssl3t64_3.5.5-1ubuntu3.3` for both architectures already returns 404 on the
live pool: the security update that superseded it removed the file. A cold
rebuild of the target SDK cannot currently succeed, and the build works only
because the builder still holds those two packages in its download cache.

Achieved state: every Ubuntu package URL in `target-sdk-inputs.json` resolves
through a `snapshot.ubuntu.com` timestamp, and the timestamp is a declared input
rather than a string repeated across 208 URLs. Package versions and hashes do
not change in this phase; only the host each is fetched from changes.

The URL rewrite is done, against snapshot `20260825T000000Z`, which is the
newest timestamp holding every pinned version: all 208 resolve there, and a
sample spanning both architectures and both package lists hashes byte-identical
to the recorded pins, including the openssl package no longer obtainable from
the live pool. Both architectures now resolve from one `snapshot.ubuntu.com`
path, so the split between `ports.ubuntu.com` and `archive.ubuntu.com` is gone.

The timestamp is now one declared field. `ubuntuSnapshot` sits beside the Swift
snapshot, matching the name the builder image inputs already use, and each
package states only its pool-relative path. Which archive this SDK is built from
was 208 decisions that could disagree; it is one. That is the drift Phase 2 has
to undo in the builder image, which installs from two snapshots at once, and it
is no longer expressible here.

Resolution is unchanged by the restructure, and the graph states so rather than
the reasoning: all 208 download tasks plan clean, which they can only do if
every resolved URL and hash is what it was. The assembly, validation, and
publication tasks do move, because they name the inputs file itself and its
bytes changed. That is one re-assembly of an SDK whose contents are identical,
and it is the cost of the restructure rather than a change in what is built.

Gate: `collider build swift-sdk --rebuild` produces both Linux target
architectures from the snapshot host, and the resulting SDK artifact hashes
match the ones the pool-fetched inputs produced. Outstanding: the rebuild is a
deliberate forced production and has not been run.

## Phase 2: Builder image input currency

`native-builder-inputs.json` declares `ubuntuSnapshot` as `20260829T000000Z` for
its apt suites while pinning the libxml2 and libicu74 package URLs at
`20260730T000000Z`. One image is assembled from two Ubuntu snapshots. The same
file pins Node 26.6.0, Bun 1.3.14, and Android NDK r30-beta2, against upstream
26.8.1, 1.4.0, and r30-beta3.

Both corrections land together because each rebuilds the heavyweight builder
image, and the image is the input whose identity the largest number of
downstream tasks carry.

One snapshot now governs every package the image installs. The two `.deb`
archives were fetched through the older view for a reason worth stating: they
are Ubuntu 24.04-era packages, deliberately older than the resolute base,
because the Swift toolchain tarball the image installs is built for 24.04 and
links `libxml2` 2.9 and `libicu74`. Unifying the timestamp does not change which
versions are installed and cannot: a snapshot is a view over one pool, both
files resolve at either timestamp, and both hash byte-identical across the two.
What it removes is the second view, not a second version.

Node moves 26.6.0 to 26.8.1 and Bun 1.3.14 to 1.4.0, each verified against the
publisher's own checksum file and then against the downloaded bytes. Both the
inputs file and the Containerfile carry the version and hash, so both change
together; the Containerfile's version assertion is what makes a mismatch fail
the image build rather than ship.

The NDK bump is held, and the reason is a fact the plan did not have. The NDK is
pinned twice: `native-builder-inputs.json` names the archive the image unpacks,
and `core/android/gradle/libs.versions.toml` names the SDK component Gradle
resolves on the host. r30-beta3 is `30.0.16138531` and r30-beta2 is
`30.0.15729638`, so bumping one leaves the container toolchain and the Gradle
toolchain on different NDKs. No task provisions the host component -- it is an
out-of-graph prerequisite under the builder-owned Android SDK root -- so
planning fails outright on a version that is not installed. Both pins move
together once `30.0.16138531` is installed there.

Achieved state: one Ubuntu snapshot timestamp governs every package the builder
image installs, and the Node and Bun archives sit at the newest published
versions with refreshed hashes. CMake stays at 3.30.2; see Non-goals.

Gate: `collider bootstrap native-builder` rebuilds the image and the SwiftPM
overlay artifact against it, followed by `collider build linux`. Outstanding
with the NDK bump: installing NDK `30.0.16138531` under the builder's Android
SDK root, then moving both pins in one change.

## Phase 3: Remove the unbuilt libxkbcommon vendoring

`core/third-party/libxkbcommon` is pinned at `xkbcommon-1.9.2` and nothing
builds it. No literal or computed reference to that path exists outside the
submodule itself; `core/third-party` is reached only for Skia. The compositor
and window client link xkbcommon through `pkgConfig` at `Package.swift:1574`,
which resolves against `libxkbcommon-dev 1.13.1` staged from the target SDK.
The vendored copy is therefore unbuilt source four minor versions behind the ABI
the products actually link, and it exists only to be mistaken for the source of
that ABI.

Status: complete. The submodule and its `.gitmodules` entry are gone, and
`core/third-party` now holds only Skia. Re-audited against the tree before
removal: no reference to the path exists outside the plan text itself, and the
only references to `core/third-party` at all are the two that reach Skia's
vendored ICU and the one that reaches Skia's sources. xkbcommon has exactly one
source, the target SDK package set, and its version is visible only where that
set declares it.

Gate: `collider build linux` links the compositor and window client, confirming
the pkg-config path never depended on the removed tree. It runs as part of the
protected-main verification sweep.

## Phase 4: Continuous integration action currency

`.github/workflows/ci.yml` pins `actions/checkout` at `11d5960a`, which is
v4.4.0. Upstream is v7.0.1. The pinned commit is three major versions behind and
carries a runner runtime that GitHub deprecates on its own schedule, which makes
this the one input in this plan whose failure arrives without a Nucleus change.

The bump is not a repository-tree change alone. This repository restricts
Actions to a selected list, requires SHA pinning, and allows neither
GitHub-owned nor verified publishers by default. The allowlist holds exactly one
pattern, `actions/checkout` at the v4.4.0 commit, so a workflow naming any other
revision fails before a job starts: the run reports `startup_failure` with no
job, no annotation, and a zero-second duration, which reads as a malformed
workflow rather than as a policy refusal. An attempt to bump the pin alone
produced exactly that and was reverted.

Status: complete. The allowlist was widened to the v7.0.1 commit first and the
workflow then pinned `3d3c42e5aac5ba805825da76410c181273ba90b1`, in that order,
which is the ordering the failure mode requires: the reverse produces a
`startup_failure` with no job and no annotation. The allowlist entry is a
repository settings change rather than a tracked file, so this phase is the one
place in this plan where the change does not live entirely in the tree.

Gate: satisfied. Protected-main sweeps check out on the upgraded action -- run
33344723864 completed its checkout step in 19.0 seconds against the v7.0.1
commit -- and no Node 20 deprecation warning appears in the run.

## Phase 5: Apple container stack currency

`collider/Package.swift` and `collider/engine/Package.swift` both pin
`containerization` at `exact: "0.40.2"` against upstream 0.43.0, and the
`third-party/container` fork sits at 1.2.0 against upstream 1.3.1. This is the
substrate every Linux task executes on, so it moves as its own phase with the
full container-executing surface as the gate.

This phase also settles the swift-crypto resolution. The root package declares
no swift-crypto dependency; it arrives transitively and resolves to 4.5.1 when
the root package is resolved alone. `collider/engine/Package.swift` declares
`exact: "3.15.1"`, and because `collider/Package.swift` includes the root
package by path, the graph that builds delivered products resolves 3.15.1.
The root's own `Package.resolved` therefore records a version the supported
build path never produces. Upgrading containerization does not converge them:
0.43.0 still declares `swift-crypto` as `from: "3.0.0"`, which excludes 4.x.

Achieved state: containerization sits at 0.43.0, the container fork is rebased
onto 1.3.1 with its Nucleus changes replayed, and the swift-crypto resolution
recorded for the root package is the one the Collider graph produces. Where the
two cannot agree, the reason is stated beside the pin rather than left to be
rediscovered from two `Package.resolved` files.

Gate: `swift test --package-path collider` for Collider's own host Swift code,
then `collider build linux` and `collider test linux` for the container
execution path.

## Phase 6: Source-built native dependency currency

Two dependencies are compiled from vendored source and are behind upstream.
`swift-wayland/third-party/wayland` is at 1.25.0 against 1.26.0 and is built by
`WaylandColliderRecipe`, which also generates protocol bindings from
`protocol/wayland.xml` in that tree, so the upgrade moves generated sources as
well as a library. `swift-tracy/third-party/tracy` is a fork at 0.13.1 against
upstream 0.14.1 and is rebased rather than repinned.

Achieved state: wayland is at 1.26.0 with regenerated protocol bindings, and the
tracy fork is rebased onto 0.14.1 with its Nucleus changes replayed.

Gate: `collider build linux`, then `collider test linux`, which exercises the
compositor's Wayland runtime against the regenerated bindings.

## Phase 7: Swift host tooling alignment

`third-party/swift-syntax` is pinned at the `2026-07-23-a` snapshot while the
compiler that builds it is `2026-08-26-a`. swift-syntax backs the macro plugins
the root package compiles, and its snapshot is the one host-tooling input that
should track the compiler rather than lag it. `swift-sdk/source/swift-sdk-generator`
is a fork at `swift-6.3-RELEASE` against upstream `swift-6.3.3-RELEASE`.

Achieved state: swift-syntax is at `2026-08-26-a`, matching the compiler
snapshot, and the SDK generator fork is rebased onto `swift-6.3.3-RELEASE` with
its Nucleus changes replayed.

Gate: `collider build linux` and `collider build swift-sdk --rebuild`, the
first covering macro expansion under the moved swift-syntax and the second
covering the generator.

## Phase 8: React Native and Hermes point release

The React Native gitlink is at `v0.87.0` against `v0.87.1`, and the Hermes
submodule is at `hermes-v250829098.0.16` against `.0.17`. The Hermes revision,
the `overrides.hermes-compiler` entry in `react-native/package.json`, and the
React Native gitlink move together. The five C++ submodules move only if React
Native's version catalog changed between the two point releases; they are
otherwise already correct and are not touched.

Achieved state: React Native is at 0.87.1, Hermes at `.0.17` with the package
override matching, and the C++ submodules reconciled against 0.87.1's catalog.

Gate: `collider build linux` and the React Native test surface.

## Non-goals

- CMake stays at 3.30.2. Upstream 4.4.3 removed compatibility with
  `cmake_minimum_required` below 3.5; the LLVM and Swift trees the SDK builds
  declare 3.20 and 3.19.6 at top level with subprojects declaring lower. The
  upgrade carries real breakage and no benefit.
- The five React Native C++ submodules are not upgraded independently of React
  Native, including fmt 12.2.0. Their versions are React Native's contract.
- `swift-sdk/source/libxml2` is not moved off `v2.11.5`. It tracks upstream's
  update-checkout configuration, not the newest libxml2.
- The Swift 6.4 snapshot is not moved. It is already the newest tagged.
- containerization is not forked to widen its swift-crypto range. The supported
  build path already resolves one swift-crypto for the whole graph; the
  divergence is confined to the root package's standalone resolution, which
  Phase 5 aligns. A fork would buy nothing but the fork.
