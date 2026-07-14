# Nucleus Toolchain and SDK CI/CD

## Invariant

Every published Nucleus Swift toolchain and Android Swift SDK is built from a
fully identified source and environment, validated from its packaged form, and
published as immutable signed bytes with provenance. Package-manager upgrades
replace the selected installation atomically, while previously published
artifacts remain immutable for auditing and rollback.

The canonical release subjects are the relocatable host-toolchain archive and
Swift SDK artifact bundle. Debian and RPM packages are first-class release
outputs and installation adapters that embed those exact canonical subjects;
neither package format is the source of truth.

The system supports these host platforms:

- Linux x86_64.
- Linux AArch64, validated natively on Fedora Asahi Remix.
- macOS arm64.

The Android SDK targets AArch64 Android and is published separately for each
supported host platform and architecture.

## Target architecture

The delivery chain is strictly ordered:

```text
identified source and environment
    -> isolated Buildkite build
    -> immutable canonical artifact
    -> clean packaged-form validation
    -> subject manifests, SBOMs, and provenance
    -> installation adapters and their metadata
    -> complete release index
    -> isolated signing and promotion
    -> generic, APT, and RPM registries
    -> clean consumer installation tests
```

Build workers never publish releases or hold signing keys. Publication workers
never compile source. The publication boundary accepts only artifacts that have
passed the packaged-form validation contract.

## Phase 1 — Define release identity and artifact contracts

Define one canonical release identity shared by `swift-toolchain` and
`swift-android-sdk`. A release is complete only when every declared host
toolchain and host-specific Android SDK subject exists and passes its required
gates. One missing or failed host leaves the release unpromotable.
`release-6.4.x` is a source channel, not a release identity, because the branch
moves.

Use a human-facing version shaped like:

```text
6.4-dev.20260713.nucleus.1
```

Give every build a unique immutable identity. Each canonical subject owns one
immutable machine-readable subject manifest. A subject manifest is never
extended by a downstream build. Record the following in each subject manifest:

- Canonical release version.
- Swift version and commit.
- LLVM commit.
- `swift-toolchain` commit.
- `swift-android-sdk` commit.
- Ordered patch list and aggregate patch-set digest.
- Android NDK version and digest when applicable.
- Host operating system, architecture, and libc baseline.
- Build-environment image or machine-image digest.
- Build configuration and relevant environment overrides.
- Buildkite pipeline, build, and job identities.
- Artifact filenames, sizes, SHA-256 hashes, and target triples.
- Parent host-toolchain artifact digest for every Android SDK.

Create a separate immutable release index after every required subject and
installation adapter exists. The release index records the canonical release
version, the complete required platform matrix, and the filename and digest of
every subject manifest, system package, SBOM, and provenance statement. Signing
and promotion operate on this index; no job mutates a producer's manifest.

Canonical filenames include the immutable version, host platform, and host
architecture:

```text
nucleus-swift-<version>-linux-amd64.tar.zst
nucleus-swift-<version>-linux-arm64.tar.zst
nucleus-swift-<version>-macos-arm64.tar.zst
nucleus-swift-android-<version>-linux-amd64.artifactbundle.tar.gz
nucleus-swift-android-<version>-linux-arm64.artifactbundle.tar.gz
nucleus-swift-android-<version>-macos-arm64.artifactbundle.tar.gz
```

The current build scripts land with explicit output parameters so CI never
writes candidates into a shared canonical path. Candidate output roots include
the Buildkite build ID. A successful build publishes its candidate exactly
once; no job repairs, augments, or overwrites an older archive.

Canonical archives are deterministic. Normalize file ordering, timestamps,
numeric ownership, permissions, archive metadata, and compression settings.
Record the bootstrap compiler and every downloaded tool by digest. Rebuilding
the same declared inputs must produce the same canonical archive bytes. Fail on
both unpacked-tree and archive-level differences.

Phase 1 is complete when two builds cannot produce indistinguishable release
identities, every output has one owning manifest, and every artifact can be
traced back to all source, patch, bootstrap, tool, and environment inputs.

## Phase 2 — Provision isolated Buildkite queues

Create these self-hosted queues:

```text
toolchain-linux-x86_64
toolchain-linux-aarch64
toolchain-macos-arm64
toolchain-publish
```

Run Linux x86_64 builds against the oldest supported glibc baseline. Building
on the oldest supported baseline prevents accidental dependencies on newer
glibc symbols. Test the resulting artifact on every supported newer
distribution.

Run Linux AArch64 builds natively on Fedora Asahi hardware. The AArch64 worker
proves that the compiler, SwiftPM, plugins, Foundation, C++ interop, and Android
SDK host tools execute correctly on the target architecture. Cross-compilation
from x86_64 is not a substitute for this host validation.

Run macOS arm64 builds on a dedicated Apple Silicon worker with a pinned Xcode
and macOS environment.

Each build runs in an ephemeral VM, container, or clean chroot. A worker may
mount only these persistent caches:

- A read-only upstream source mirror.
- `ccache` storage.
- Download caches keyed by verified source digest.
- A versioned Swift checkout cache that is reset to recorded commits before
  every build.

Build output, installed candidates, SwiftPM homes, and test homes are disposable
per job. A job never consumes `/opt/nucleus-swift/current` implicitly. It uses an
explicit bootstrap toolchain and records that bootstrap identity.

Configure agents with outbound-only network access, forced clean checkouts,
plugin allowlists or disabled plugins, command timeouts, and signed pipeline
verification. Builds for untrusted changes run without publication access.

Phase 2 is complete when each worker can execute a no-publication dry run from a
clean environment and no build worker possesses source-repository write,
publication, or signing credentials.

## Phase 3 — Build and validate host toolchains

The host-toolchain pipeline performs these steps in order for every host:

1. Resolve and record every source commit.
2. Apply the ordered patch set and record its digest.
3. Build into a job-specific candidate root.
4. Package the candidate into the canonical relocatable archive.
5. Generate the immutable host-toolchain subject manifest and artifact hashes.
6. Extract the archive into a new clean root.
7. Run compiler and runtime validation from the extracted layout.
8. Run the transactional installer against a disposable system root or VM.
9. Run live validation through the installed `current` selector.
10. Upload the validated archive, manifest, and complete logs as intermediate
    Buildkite artifacts.

Packaged-form validation covers:

- `swift`, `swiftc`, `clang`, and `clang++` execution.
- SwiftPM package build and test.
- Relocation outside the build directory.
- Foundation, FoundationNetworking, and FoundationXML.
- Swift concurrency and `swift-testing` macros.
- C and C++ interop.
- Dynamic Swift runtime linkage.
- Static Swift runtime linkage.
- Static C++ interop archives and link metadata.
- Plugin and macro host-tool execution.
- The existing package smoke suite.
- Transactional installation and replacement of a previous version.
- Rejection of incomplete or corrupted archives.
- Rejection of archive path traversal, unsafe symlinks, invalid ownership or
  permissions, and excessive decompression expansion.
- Recovery from interruption and disk exhaustion before and after selector
  exchange.

Linux artifacts undergo ABI inspection. Record the maximum required glibc and
libstdc++/libc++ symbol versions and fail when they exceed the declared
baseline. Validate the Linux x86_64 artifact on clean Ubuntu and Fedora
consumers. Validate the Linux AArch64 artifact on a clean Fedora Asahi consumer.

Phase 3 is complete when no artifact can leave the pipeline without passing all
tests from a fresh extraction and the installed tree is byte-derived solely
from the published archive.

## Phase 4 — Build and validate Android Swift SDKs

Trigger the Android SDK pipeline only after the matching host toolchain artifact
passes Phase 3. Download that exact artifact by digest, extract it into a clean
location, and pass it through `NUCLEUS_SWIFT_TOOLCHAIN`. Never use an ambient
agent installation.

For each supported host, perform these steps in order:

1. Verify the parent toolchain digest against its immutable subject manifest
   and the Buildkite artifact identity of the successful Phase 3 job.
2. Resolve and verify the pinned Android NDK.
3. Build all configured Android target architectures and API levels.
4. Assemble the Swift SDK artifact bundle into a job-specific candidate path.
5. Generate its immutable subject manifest and checksum, including the parent
   toolchain subject-manifest and artifact digests.
6. Install the artifact bundle into a clean temporary user home.
7. Run `test-installed-sdk.sh` against the installed bundle.
8. Build both dynamic-stdlib and static-stdlib consumer packages where both
   contracts remain supported by the SDK.
9. Build `nucleus/platform-android` using the static Swift runtime contract.
10. Run `tools/nucleus android verify` against the resulting Android library.
11. Assemble the Android AAR and inspect its ABI, JNI exports, page alignment,
    native dependencies, Java classes, and metadata.
12. Upload the validated artifact bundle, manifest, and logs as intermediate
    Buildkite artifacts.

The Android SDK artifact remains NDK-agnostic. Consumer setup wires the installed
SDK to a verified local NDK through the existing setup script. The manifest
records the NDK version used for validation.

Phase 4 is complete when every Android artifact bundle is proven from a clean
installation using the exact host toolchain artifact it declares.

## Phase 5 — Generate SBOM and provenance

Generate an SPDX 3.0 SBOM for each canonical subject. Include:

- Installed toolchain and SDK files.
- Swift and LLVM source identities.
- Bundled runtime libraries.
- Third-party source dependencies.
- Android NDK identity.
- Licenses and license-file locations.

Generate a DSSE-wrapped SLSA v1.0 provenance statement for each canonical
subject, binding:

- The artifact digest.
- The complete source identity.
- The Buildkite pipeline and job.
- The builder queue and environment identity.
- The invoked build entry point.
- Declared and resolved dependencies.

Treat Buildkite artifacts as intermediate transport, not durable release
storage. Canonical subjects, subject manifests, SBOMs, and provenance move
together through the remaining phases. Bind every SBOM digest into its
provenance statement and the release index without mutating the subject
manifest.

Phase 5 is complete when each canonical subject digest has one corresponding
subject manifest, SBOM, and provenance statement and validation rejects any
mismatched set.

## Phase 6 — Package the canonical artifacts

Create system packages for each supported Linux architecture:

```text
swift-toolchain
swift-android-sdk
```

Each system package embeds the exact canonical archive or artifact bundle bytes
identified by its subject manifest. Package installation never fetches release
payloads from the network.

The host-toolchain package installs the canonical archive under:

```text
/opt/nucleus-swift/<immutable-version>/usr
/opt/nucleus-swift/current
```

Package installation validates and fully extracts the archive before changing
`current`. The selector is a temporary symlink renamed atomically into place.
Before selector exchange, interruption leaves the old version active. After
selector exchange, interruption leaves the new complete version active.

The unversioned package owns one selected immutable-version tree. A successful
upgrade changes `current` and then removes the superseded tree. Controlled
rollback reinstalls a retained older package from repository history; it does
not depend on an older local tree. Removal deletes the package-owned version and
removes `current` only when it resolves to that version. Maintainer scripts are
idempotent and explicitly handle disk exhaustion and interrupted transactions.
They do not modify or rewrite the embedded canonical archive.

The Android SDK package depends on the exact matching host-toolchain package
version. It installs the canonical artifact bundle system-wide under:

```text
/opt/nucleus-swift/sdk-bundles/<immutable-version>/
```

Package scripts never write into arbitrary user home directories. Provide a
user-facing command:

```text
nucleus-swift sdk install-android
```

That command installs or replaces the matching bundle in the invoking user's
SwiftPM SDK directory and runs NDK setup. It validates signatures and hashes
before installation and never repairs an older installed bundle.

Build `.deb` packages for Ubuntu and Debian and `.rpm` packages for Fedora.
Package metadata declares runtime dependencies explicitly rather than relying
on the build host's installed packages. Generate a package manifest, SPDX SBOM,
and SLSA provenance statement for each package. Each binds the package digest to
the digest of its embedded canonical subject.

Provide the same transactional installer for macOS canonical archives. It
installs immutable versions under `/opt/nucleus-swift`, verifies signatures and
hashes before extraction, and exchanges `current` atomically. The Android SDK
command uses the package-matched or explicitly selected host-toolchain version
on every host.

Phase 6 is complete when clean Ubuntu, Fedora x86_64, and Fedora Asahi AArch64
systems can install, upgrade, validate, and remove both packages without manual
filesystem changes, and macOS can perform the equivalent transactional archive
installation, upgrade, validation, and removal flow.

## Phase 7 — Isolate signing and promotion

The `toolchain-publish` queue accepts only validated intermediate artifacts. It
does not check out or build arbitrary source. Promotion requires an approved
release identity and verifies all of the following before signing:

- Artifact and package hashes match their subject and package manifests.
- Manifest inputs match the approved source identity.
- Host toolchain and Android SDK parent-child digests match.
- All required Buildkite validation jobs succeeded.
- SBOM and provenance statements bind the same artifact digests.
- The release index names the complete required platform matrix and binds every
  subject, package, SBOM, and provenance digest.
- The version has never been published before.

Use Buildkite OIDC to obtain short-lived cloud credentials scoped to the
publication pipeline, immutable pipeline identity, trusted branch or release
event, and publication queue. Use those credentials to invoke a KMS- or
HSM-backed Nucleus signing key. No private signing key exists on disk or in a
long-lived Buildkite secret.

Sign:

- Every canonical artifact digest.
- Every subject and package manifest.
- Every SBOM.
- Every provenance statement.
- The release index.
- Every RPM.

Publish the public verification key and its fingerprint through a separately
controlled Nucleus channel. Define key rotation and revocation metadata before
the first public release.

Phase 7 is complete when a compromised build worker cannot publish or sign an
artifact and the publication worker cannot substitute different bytes without
detection.

## Phase 8 — Publish generic, APT, and RPM registries

Create five registries:

```text
nucleus-toolchain-artifacts
nucleus-toolchain-deb-candidate
nucleus-toolchain-deb-stable
nucleus-toolchain-rpm-candidate
nucleus-toolchain-rpm-stable
```

Use Buildkite Package Registries initially for generic files, Debian packages,
and RPM packages. Restrict writes with an OIDC policy that admits only the
publication pipeline. Make read access public when the toolchains are ready for
public consumption.

The generic registry stores:

- Canonical toolchain archives.
- Android SDK artifact bundles.
- Checksums.
- Signed manifests.
- SBOMs.
- Provenance statements.
- Detached Nucleus signatures.
- Signed release indexes.

The candidate and stable Debian repositories expose separate signed APT views
and packages for `amd64` and `arm64`. Installation uses a dedicated key under
`/etc/apt/keyrings` and a source entry with `Signed-By`; `apt-key` is not used.
Buildkite generates and signs each repository metadata snapshot, including
`InRelease`, only from packages admitted by the publication pipeline.

The candidate and stable RPM repositories expose separate signed views for
`x86_64` and `aarch64`. Fedora consumers enable repository and package
signature verification. Buildkite generates and signs the repository metadata;
the Nucleus signature on each RPM remains independently verifiable.

Keep the canonical Nucleus signatures independent of Buildkite's registry
signing so artifacts remain verifiable after download or migration. Before
public launch, decide whether registry-provider URLs are acceptable. If Nucleus
must own its distribution URL and repository trust root, publish the same
signed artifacts through object storage behind `packages.nucleus.dev`, generate
APT metadata with `aptly` or `reprepro`, and generate RPM metadata with
`createrepo_c`.

Phase 8 is complete when every registry view serves outputs bound to the same
release index, clients verify repository and artifact signatures, and each
repository-metadata update is atomic from the consumer's perspective.

## Phase 9 — Define release channels and replacement behavior

Expose two channels as distinct repository views without creating two build
pipelines:

- `candidate` contains every fully validated mainline build selected for wider
  testing.
- `stable` contains explicitly promoted releases.

A channel is mutable repository metadata selecting immutable releases.
Candidate and stable have separate APT and RPM repository endpoints. Advancing
a channel publishes a complete new metadata snapshot atomically; it never
overwrites artifact bytes or reuses a package version.

On clients, a package-manager upgrade replaces the active toolchain and updates
`/opt/nucleus-swift/current`. The Android SDK user command replaces the prior
installed bundle with the package-matched bundle. The default experience shows
one selected version. Repository history remains available for controlled
rollback and audit.

Do not publish two different artifacts with the same version. Do not repair a
published archive. A broken release is superseded by a new version and the
affected channel advances only after the replacement passes the full pipeline.

Phase 9 is complete when promotion and rollback change only channel/package
selection and no operation mutates a published release.

## Phase 10 — Run clean end-to-end consumer gates

Before advancing `stable`, publish the complete release to the candidate views,
provision clean consumers, and exercise those public-shaped installation paths
exactly as documented. Stable promotion copies the already tested package bytes
into the stable views and atomically publishes new stable repository metadata;
it never rebuilds or repackages them.

Ubuntu and Debian gates:

1. Install the repository key and source definition.
2. Install `swift-toolchain` through APT.
3. Install `swift-android-sdk` through APT.
4. Run the Android SDK user installation command.
5. Build representative Nucleus host and Android packages.
6. Upgrade from the previous stable package version.
7. Verify `current`, installed package ownership, and removal behavior.

Fedora Asahi gates:

1. Install the repository key and DNF repository definition.
2. Install the AArch64 toolchain and Android SDK RPMs.
3. Run the Android SDK user installation command.
4. Build and test a SwiftPM package natively.
5. Build the Android host library.
6. Upgrade from the previous stable package version.
7. Verify signatures, architecture, runtime linkage, selection, and removal.

macOS gates install through the transactional installer from the signed
canonical archive and artifact bundle, validate relocation, upgrade from the
previous stable version, and build the same representative SwiftPM and Android
consumers supported on macOS.

Phase 10 is complete when the only way to publish `stable` is through successful
clean installation, build, upgrade, and removal tests on every declared host.

## Phase 11 — Operate and audit the delivery system

Retain:

- Immutable canonical releases.
- Signed manifests, SBOMs, and provenance.
- Publication audit logs.
- Complete build logs for the retention period.
- Source and dependency mirrors required to reproduce supported releases.

Monitor:

- Buildkite agent and queue health.
- Cache integrity and hit rates.
- Artifact and registry availability.
- Signing and OIDC failures.
- Repository metadata expiry.
- Host ABI baseline drift.
- Upstream Swift, LLVM, NDK, and runtime security advisories.

Define and exercise procedures for:

- Revoking a signing key.
- Removing a compromised channel pointer without mutating evidence.
- Superseding a broken release.
- Reproducing an artifact from its manifest.
- Restoring registries from canonical object storage.
- Rotating worker images and bootstrap toolchains.

Phase 11 is complete when a release can be traced, verified, reproduced,
superseded, and revoked without relying on mutable worker state or undocumented
operator knowledge.

## Final acceptance contract

The CI/CD system is complete when all of these statements are true:

- Linux x86_64, Fedora Asahi AArch64, and macOS arm64 artifacts build on native
  workers.
- Every artifact has a unique immutable release identity.
- Every Android SDK names the exact host toolchain artifact that produced it.
- Validation runs from packaged artifacts in clean environments.
- Build workers cannot sign or publish releases.
- Publication uses short-lived identity and hardware-backed keys.
- Canonical artifacts, manifests, SBOMs, and provenance are independently
  signed.
- Ubuntu/Debian users install through a signed APT repository.
- Fedora Asahi users install through a signed RPM/DNF repository.
- macOS and unsupported distributions can install signed canonical archives.
- Package upgrades replace the active installation atomically.
- Published bytes are never repaired, overwritten, or reused under one version.
- Stable promotion requires clean consumer installation and upgrade gates on
  every supported host.
