# Linux x86_64 Development Host Plan

Status: active

Execution position: Phase 1 runs first to remove unsupported Linux-host claims.
Phases 2 through 10 follow the production artifact, package, CI, publication,
distribution-qualification, and development-deployment sequence in the root
documentation inventory. The contributor workflow reuses portable identity
primitives without becoming a production artifact, release path, or CI cache.

## Invariant

Nucleus supports two complementary development workflows. The M2 Ultra remains
the primary development host, full arm64 and x86_64 builder, CI executor, and
artifact publisher. An x86_64 Linux contributor host independently clones,
provisions, builds, tests, and runs the supported x86_64 first-party graph
without access to that Mac.

The Linux workflow is containerized and distribution-independent. Collider
acquires all network inputs on the host, verifies them, and mounts them read-only
into offline rootless containers. The contributor's distribution supplies only
Collider's host prerequisites and the rootless container runtime; it never
becomes the runtime or link dependency baseline for Nucleus products.

Collider resolves a small declared set of published contributor build inputs by
exact content identity. A matching published input is materialized locally. A
changed or unpublished input is built locally by its owning component. There is
no build profile, prebuilt-selection flag, generic remote task cache, or fallback
to a merely similar version.

Linux x86_64 contributors build and execute x86_64 products and tests. The M2
Ultra continues to own arm64 products, arm64 tests, dual-architecture release
cohorts, signing, and publication. Linux arm64 development hosts and foreign-
architecture test execution on Linux are outside this plan.

## Boundaries

This plan does not replace the
[macOS remote-development plan](macos-remote-development-plan.md). That plan
governs the primary M2 Ultra workflow and its authoritative working checkout.
This plan adds an independently usable contributor checkout.

The [Linux package distribution and update
plan](linux-package-distribution-and-update-plan.md) exclusively owns end-user
APT, DNF, and pacman packages. Its protected publication identities own the
Cloudflare Worker repository origin, signed R2 repository snapshots, and final
native package objects in immutable GitHub Releases or the post-cutover R2
object bucket.

Declared contributor build inputs use public OCI artifacts in GHCR. They are
keyed by build-input identity rather than release channel and cannot be installed
as Nucleus products. The allowed set is:

- the x86_64 native-builder image;
- the x86_64 slice of the Nucleus Linux Swift target SDK;
- the x86_64 `render`, `rn`, `wayland`, and `android/gfxstream` native SDK
  partitions;
- the x86_64 Chromium/CEF product; and
- the signed x86_64 AOSP generation.

The third-party application SDK is a separate external compatibility boundary.
Its versioning, API documentation, source-compatibility policy, and SwiftPM
distribution do not belong to this plan.

The translated amd64 Swift compiler on the M2 Ultra is also separate. Replacing
it with a genuine arm64-hosted cross-compile is a macOS build optimization, not
a prerequisite for native x86_64 Linux development.

## Current State

Collider currently builds only on macOS arm64:

- `ColliderCLI` installs `AppleContainerRuntimeBackend` only on macOS and uses
  `UnsupportedOCIRuntimeBackend` elsewhere;
- Doctor deliberately rejects every Linux OCI runner and includes `xcrun` and
  `pkgutil` in the Swift SDK prerequisite set;
- build recipes and `SwiftPMOCIExecution` assume an arm64 Linux guest;
- `tools/host-env.sh` names a Linux host toolchain path that no producer writes;
- the Linux branch of `collider-setup.sh` invokes a removed `swift-sdk rebuild`
  command; and
- the current self-hosted Linux workflow invokes build and test commands that
  cannot pass with the available backend.

Most x86_64 C and C++ work is already a conventional cross-compile in the
arm64 guest. Skia, Wayland, gfxstream guest libraries, and the React Native C++
stack use arm64 host tools while producing x86_64 objects. Hermes alone runs its
newly built x86_64 `hermesc` for `InternalBytecode`; upstream Hermes already
provides `IMPORT_HOST_COMPILERS` for this case.

Chromium/CEF, AOSP, and the Linux Android NDK ship x86_64-only Linux host tools.
They require translation on the M2 Ultra but run natively on an x86_64 Linux
host. The translated x86_64 Swift lane remains an intentional macOS execution
path until the independent Swift cross-compilation work replaces it.

Collider produces build inputs locally but cannot resolve finished build inputs
from a publisher. Its action identities canonicalize the checkout and cache
roots, but portability has not been demonstrated for every identity admitted to
the contributor-input boundary. Persistent-workspace declarations also expose
Apple-oriented EXT4 capacity and journal policy as if those were portable
executor requirements.

## Phase 1: Make Current Platform Claims Truthful

Remove the dead Linux toolchain-selection branch from `tools/host-env.sh` and
the nonfunctional Linux bootstrap path from `collider-setup.sh`. Until Phase 8
lands, setup rejects Linux immediately with one accurate unsupported-host error.

Remove workflow jobs that invoke unsupported Linux build or test paths. Keep the
self-hosted CI plan deferred; a contributor host is not a trusted runner or
gateway. Update current documentation to distinguish the supported M2 Ultra
workflow, the future Linux contributor workflow, Linux presentation targets,
and trusted CI identities.

Gate: no executable path, workflow, generated skill, or current-state document
claims that Collider can build on Linux before a Linux backend exists.

## Phase 2: Define Portable Published-Input Identity

Reuse the canonical identity, platform, and digest primitives established by
Phase 1 of the
[GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md).
Introduce a typed `PublishedBuildInput` contract for only the allowlisted inputs
in this plan. It remains distinct from a CI product bundle, package release
index, qualification record, and development generation. Its manifest records:

- artifact kind and producing task identity;
- source and submodule closure identity;
- producer runner and container guest platforms;
- artifact operating system, architecture, ABI, and Android API when present;
- compiler, Swift SDK, native SDK, and builder-image identities;
- build configuration and semantic tool identities;
- archive and file-tree digests; and
- provenance and publisher signature.

Audit every admitted action identity. Canonicalize placement-only checkout,
cache, toolchain, workspace, and output roots before encoding. Retain semantic
relative paths and file contents. Reject an identity containing an unrecognized
absolute host path instead of publishing an input that another clone can never
resolve.

Add behavioral identity tests that plan the same representative tasks under two
different checkout, cache, and home roots. The resulting published-input
identities must match. Changing source, toolchain, configuration, target, or a
semantic build input must change the identity.

Gate: every allowlisted input has one machine-independent identity and manifest,
and no non-allowlisted task can request publication or remote resolution.

## Phase 3: Model Executable Architecture Per Action

Build host-native Hermes `hermesc` and `shermes`, publish their
`ImportHostCompilers.cmake` inside the native build graph, mount that host-tools
generation separately from the target build, and configure every cross-built
Hermes target with `IMPORT_HOST_COMPILERS`.

Delete `NativeLinuxTarget.intelBinaryTranslationPolicy`. Replace
`OCIIntelBinaryTranslationPolicy` with an executor-neutral declaration of the
executable architectures an action requires. Keep guest architecture, executed
tool architecture, runner capability, and produced artifact target as distinct
values. The executor selects native execution when possible and translation
only when a declared executable cannot run natively.

Declare the remaining translated M2 Ultra actions explicitly: the x86_64 Swift
build and test lanes, Chromium/CEF host tools, AOSP host tools, and the Linux
Android NDK used by the Android Skia build. Pure C and C++ cross-compiles do not
request translation.

Gate: the native SDK builds both architectures with host-native Hermes tools;
translation is absent from pure cross-compiles; and every translated action
names the foreign executable requirement that justifies it.

## Phase 4: Make Execution and Workspace Contracts Backend-Neutral

Replace scattered `.linuxARM64OCI` and `.macOSARM64Native` constants with a
typed build-executor context. It carries runner platform, container guest
platform, available executable architectures, and backend capabilities. Recipes
continue to declare artifact targets independently.

Remove filesystem type and journal mode from the portable persistent-workspace
declaration and its task identity. The declaration retains logical identity,
owner, artifact target, role, retention, and storage budget. Backend policy owns
physical representation:

- Apple container uses sparse EXT4 volumes with its selected journal policy;
- Linux uses Collider-owned workspace directories below the XDG cache root; and
- every backend reports allocated size and applies the declared budget as a
  diagnostic and pruning threshold.

Do not require loopback devices, privileged mounts, or a particular Linux host
filesystem to reproduce Apple container's implementation.

Gate: the existing M2 Ultra graph retains its artifact targets and persistent
state, while backend-independent tests exercise the same lifecycle with a
directory-backed workspace implementation.

## Phase 5: Produce the x86_64 Native-Builder Image

Add an x86_64 variant of the native-builder input manifest and image. Acquire
the official x86_64 Swift 6.4 toolchain, CMake, Node, Bun, and all other archives
on the host with exact digests. Assemble the same pinned Ubuntu package-snapshot
closure used by the arm64 image.

The x86_64 image contains no arm64 multiarch compatibility layer. Chromium,
AOSP, the Android NDK, Swift, and all generator tools execute natively. Publish
the image to `ghcr.io/nucleus-os` by immutable OCI digest and associate it with
this repository. Tags are discovery aliases and never enter task identity.

Gate: an x86_64 Linux host pulls the image by digest and completes a
network-disabled representative Swift, C, and C++ build with the declared
glibc and libc++ contracts.

## Phase 6: Publish and Resolve Contributor Build Inputs

Publish each allowlisted non-image input as an OCI artifact in GHCR with
component-specific media types and the Phase 2 manifest. Split large payloads
only at natural independently verified component boundaries; no OCI layer may
exceed [GHCR's 10 GB layer
limit](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).
A dedicated contributor-input publisher signs the manifest after trusted build
evidence exists. It receives only GitHub `packages:write`; it receives no
GitHub `contents:write`, R2, Worker-deployment, package-signing, or release
credential. Public consumers pull each artifact anonymously by digest.

Add a host-side Collider resolver. It requests the exact manifest identity,
downloads blobs into the normal content-addressed download cache, verifies the
manifest signature and every digest, and atomically publishes the finished
local generation. Containers remain offline and consume the local generation
through read-only mounts.

Resolution is part of the ordinary graph. A matching artifact makes its
producer clean. An absent artifact leaves the producer runnable locally. A
signature, digest, platform, or identity mismatch is a hard failure and never
falls through to a different artifact.

Gate: a fresh host cache materializes every allowlisted input exactly once,
offline consumers reuse it, corruption and substitution fail, and modifying an
owned source input selects the local producer without a command-line mode.

## Phase 7: Implement the Rootless Linux OCI Backend

Implement `OCIRuntimeBackend` over rootless Podman. Collider owns image
inspection and build, offline process execution, cancellation, logs, isolated
network state, bind mounts, persistent workspace directories, disk reporting,
and declared pruning. The backend uses Podman's rootless service boundary and does
not introduce a second task graph or shell-script orchestration layer.

Enforce the existing execution policy: no network, all capabilities dropped,
privilege acquisition prohibited, bounded process count, bounded writable
mounts, read-only source and acquired inputs, and no host Docker socket. A
container receives no registry credential; host acquisition completes before
execution.

Gate: backend lifecycle and cancellation tests pass without sudo, privileged
containers, loopback mounts, container networking, or leaked processes and
volumes.

## Phase 8: Add the Linux Builder Host Role

Replace operating-system-driven host augmentation with explicit roles:

- macOS builder;
- Linux x86_64 builder;
- Linux presentation target; and
- trusted runner or qualifier roles owned by the CI plan.

Add Linux x86_64 builder environment resolution, Doctor prerequisites,
conventional XDG cache and state paths, Podman health checks, official Swift 6.4
validation, Java and Android tool discovery, and the host downloader
requirements. Reintroduce Linux support in `collider-setup.sh` as a clean path
that builds the optimized Collider binary and installs the normal launcher. It
does not source `tools/host-env.sh` or install Nucleus products.

Linux presentation commands remain available only under the presentation-target
role. Building on Linux does not pull the shell runtime-publication component
into every graph merely because the host operating system is Linux.

Gate: a fresh supported x86_64 Linux installation completes setup and `collider
doctor` without macOS tools, custom volumes, sourced environment scripts, or
product installation.

## Phase 9: Cut Over the Linux x86_64 Graph

Run the x86_64 SwiftPM, native SDK, browser, and Android graphs through the
native x86_64 builder. Materialize published inputs lazily when their identities
match. Preserve local source rebuilds for each owning component, including
native Chromium/CEF and AOSP builds when their source identities change.

The Linux host never schedules arm64 builds or tests and never installs QEMU,
FEX, Rosetta, or another foreign-execution layer. Commands that request an
unsupported arm64 lane fail during planning with the owning M2 Ultra lane named
in the diagnostic.

Gate: a fresh x86_64 Linux clone builds, tests, and runs the complete supported
x86_64 first-party graph without the M2 Ultra, a pre-warmed cache, or container
network access; changing every allowlisted component once selects and completes
its local producer.

## Phase 10: Complete the Platform Contract

Regenerate the Collider skill, update the documentation inventory, and revise
the package, remote-development, storage, and CI documents to describe the final
roles. Delete superseded Linux scaffolding, platform constants, translation
names, and temporary unsupported-host diagnostics.

Keep the Linux contributor host separate from trusted self-hosted runners. The
CI plan owns any x86_64 runner provisioned with the same backend, including its
trust-domain storage, authorization, credentials, and native release evidence.

Gate: CLI grammar, Doctor, setup, task planning, generated skill, workflows, and
all plan invariants describe the same supported host matrix and contain no dead
Linux path.

## Explicit Non-Goals

- Do not replace the M2 Ultra as the primary development or publication host.
- Do not support Linux arm64 development hosts in this plan.
- Do not run arm64 products or tests through emulation on Linux.
- Do not make a contributor machine a trusted runner or remote build worker.
- Do not publish arbitrary task outputs or add a generic remote Collider cache.
- Do not place contributor inputs in immutable GitHub Releases or native package
  repositories.
- Do not define the public third-party application SDK or its compatibility
  policy here.
- Do not make genuine amd64 Swift cross-compilation on the M2 Ultra a Linux-host
  prerequisite.
