# Android Architecture Parity Plan

Status: active

## Invariant

The Nucleus Android guest is one device tree built as one product per supported
architecture. `nucleus-android` is an architecture-specific member of every
native package cohort on arm64 and x86_64 alike, and every cohort member is
produced by the ordinary build graph. No package input is supplied to the graph
by path, and no architecture is packaged from another architecture's images.

An architecture is supported when its AOSP product builds, signs, and validates
in the graph, its package input materializes in the builder image, its cohort
assembles and qualifies from that input, and its guest boots on that
architecture's hardware. Declaring a package for an architecture the repository
cannot produce is not support.

## Current State

Both supported architectures have an AOSP product.
`android-runtime/aosp-product.lock.json` pins `nucleus_arm64` and
`nucleus_x86_64`, `AOSPProductLock.validate()` admits each entry for its own
architecture and no other, and both generations are built, signed, and
validated by the graph.

The device tree is architecture-neutral in substance. Across the 61 tracked
files under `android-runtime/aosp/device/nucleus/nucleus_x86_64`, every `x86`
occurrence outside `BoardConfig.mk` is the product name or the tree's own path:
`AndroidProducts.mk` entries, `PRODUCT_NAME`, `PRODUCT_DEVICE`,
`PRODUCT_SYSTEM_DEVICE`, `inherit-product` and `PRODUCT_COPY_FILES` paths, and
Soong `visibility` and include paths. The genuine architecture settings are four
lines in `BoardConfig.mk`: `TARGET_ARCH`, `TARGET_ARCH_VARIANT`,
`TARGET_CPU_VARIANT`, and `TARGET_CPU_ABI`. Everything else the board declares —
no bootloader, no kernel, no recovery, ext4 images, AVB algorithms and rollback
indices, sepolicy directories — is architecture-independent. The native HALs
under `native/` are ordinary Soong modules that build for the target the product
selects.

The host side is already built for both architectures. gfxstream and its native
SDK are produced per `PlatformArchitecture`, and the Linux runtime, browser, and
package cohorts are assembled for arm64 and x86_64.

The Android image pipeline is per-product. `aospProductImageTasks` is declared
once per pinned entry, each product owning its own source directory,
generation, active-generation link, storage, and workspaces, and validation
asserts the product it was declared for.

The package input is declared per architecture and produced by the ordinary
graph. Each input consumes its own generation and the AVB signing identity as
artifacts, builds the Android runtime products for its architecture, and
materializes in the builder image, where it verifies that the generation's
provenance matches the architecture it packages for and that the images carry
the release key. The packaging lane names those producing tasks; no input is
supplied by path. Both inputs exist, each carrying its own architecture's
runtime executables and signed provenance.

A generation carries the tool that verifies it. `external/avb/avbtool.py` is
published beside the images as pinned source rather than as a host build of
itself, so a consumer outside the AOSP container — the package input, and an
installed runtime re-verifying later — holds one artifact rather than reaching
into the build that produced it.

What remains unproven is the cohort. No Linux runtime package has been
assembled from either input, because assembling one requires building Chromium
for both architectures.

## Phase 1: Separate the Device Tree From the Product

Shared device content moves to `device/nucleus/common`: the native HALs,
sepolicy, overlays, permissions, sysconfig, manifests, init and cgroup
declarations, and `device.mk`. A product directory holds only what AOSP resolves
by device name — `AndroidProducts.mk`, `BoardConfig.mk`, and the product
makefile — and inherits the shared tree. Soong visibility and include paths name
the shared package.

Collider names the shared tree and the selected product rather than one
hard-coded directory. The product source path, the source-checkout identity
inputs, and the signing and artifact task inputs take the product as a
parameter.

The x86_64 product keeps its exact name, release, variant, build number, and
platform identity. This phase moves files and parameterizes paths; it changes no
board setting and no packaged content.

Gate: the `nucleus_x86_64` product builds, signs, assembles, and validates, and
its image provenance declares the same product, release, build number, and
complete raw image set as before the move.

Status: complete. Gate evidence: run `2026-08-22T19-55-45.075Z-79403` compiled,
signed, assembled, and validated the product through the separated tree, and the
generation it published,
`1781652681-nucleus-android17-r1-cp2a-nucleus_x86_64-user-37-202604`, carries the
same identity and the same raw image set as the generation preceding the move.

Reaching that gate exposed how long the lane had been unbuildable. Nothing had
compiled it since 2026-08-09, and eleven independent defects stood between the
tree and an image: two openssl implementations in one signing chain, an
acquisition path the credential-less build identity could not use, a provenance
status renamed on one side only, two container mount rules that forbade the
nesting this build requires, two workspaces classified as authoritative when
they held only rebuildable state, a Siso configuration repository that must sit
inside the tree, an object store seeded once and unable to see later objects,
Repo metadata pinned to the manifest a volume was first written with, and a
bridge application calling a framework entry point that was never added. Each
was invisible for the same reason: the lane that would have reported it was
itself broken.

## Phase 2: Build Every Product the Lock Declares

The image pipeline names one product throughout: the lock holds a single
identity, and the generation, build root, staged archives, task identifiers,
output workspace, compiler-cache workspace, storage declarations, and
active-generation link are all derived from it. A second product cannot be added
to a pipeline shaped like that, so the shape changes before the product does.

The product lock becomes one entry per architecture, and
`AOSPProductLock.validate()` admits each entry for its own architecture and no
other. `aospProductImageTasks` produces one task graph per locked entry, each
with its own generation, active-generation link, workspaces, storage, and task
identifiers, and each recording provenance naming its own product. Source
materialization stays shared: one Repo-managed checkout serves every product.

This phase changes structure, not content. With one entry still declared, it
builds exactly what it built before.

Gate: the `nucleus_x86_64` product builds, signs, assembles, and validates from a
lock that now expresses a set, publishing the same generation identity and raw
image set as the phase before it.

Status: complete. Gate evidence: run `2026-08-22T20-52-09.625Z-17569` compiled,
signed, assembled, and validated through the per-product pipeline and published
`1781652681-nucleus-android17-r1-cp2a-nucleus_x86_64-user-37-202604` with its
complete raw image set, unchanged from the phase before.

The output and compiler-cache workspaces stay shared. AOSP already separates
products inside one output tree, and a product-specific ninja file beside shared
host tooling is what makes a second product cheap rather than a second full
build.

## Phase 3: Add the arm64 Product

`device/nucleus/nucleus_arm64` declares the four architecture settings for arm64
and inherits the shared tree, and `AndroidProducts.mk` in each product directory
names its own product. The lock gains its entry, which the pipeline already
knows how to build.

The native HALs and the gfxstream guest compile for arm64 under Soong. This is
where a genuine architecture dependency in the guest surfaces, and any that does
is fixed in the shared tree rather than forked per product.

Gate: `nucleus_arm64` compiles, assembles its complete raw image set, signs with
the AVB identity the graph generates, and passes product validation with arm64
provenance. Both generations exist simultaneously, and building one does not
invalidate the other.

Status: complete. Gate evidence: run `2026-08-22T21-30-45.307Z-39952` compiled
`nucleus_arm64` in 7h28m across 144,172 steps with no failures, and run
`2026-08-23T06-00-12.958Z-25386` completed the pair with 11 tasks clean and 11
executed, none failed. Both products publish a generation carrying `system`,
`system_ext`, `product`, `vendor`, `vbmeta`, and `vbmeta_system` as raw images
with `status: signed` under one build number, and each names its own product in
its provenance.

Soong resolved the shared device tree, the Nucleus HALs, and the gfxstream
guest for arm64 without a single architecture dependency needing a fix, which
is what the phase existed to discover.

The coexistence clause holds. Adding the arm64 product left
`aosp-compile.x86_64` needing a rebuild only because its own workspace identity
changed when the workspaces became architecture-neutral, and once both had
built, a replan taken with no intervening source change reported all fifteen
AOSP tasks clean across both products. Building one does not invalidate the
other, and `aosp-compile.arm64` was reused rather than repeated while the
second product built.

Two properties of the pipeline surfaced here rather than in the phase that
owns them. A task running a first-party Linux tool hashes the Collider package
tree through its Swift product requirement, so editing Collider invalidates the
signing identity and everything downstream of it for both products; the
compiles are unaffected. And nothing on the development host compiles
`#if os(Linux)` sources, so a Linux-only caller of a changed signature fails
first inside a container build.

Binary translation is the pipeline's least reliable element, and it has its own
plan: [Android native arm64 host toolchain](android-native-arm64-host-toolchain-plan.md).

## Phase 4: Produce Both Package Inputs From the Graph

The package input task is declared per architecture. Each consumes its own AOSP
generation and the AVB signing identity as artifacts rather than as paths
hashed at planning, builds the Android runtime products for its architecture,
and materializes inside the builder image.

Gate: both package inputs are produced by the ordinary graph on the macOS
builder, each carrying provenance for its own architecture, with no input
supplied by path.

Status: complete. Gate evidence: run `2026-08-23T19-08-42.618Z-74397`
materialized `android-runtime.package-input.arm64` and
`android-runtime.package-input.x86_64` in one graph, 20 tasks executed and
none failed, with every input consumed as an artifact and none supplied by
path. Each input carries the provenance of its own signed product —
`nucleus_arm64` and `nucleus_x86_64`, both `signed`, each naming the same six
images — and each stages runtime executables for its own architecture,
aarch64 in one and x86-64 in the other. Both payloads verify their vbmeta
chain against the release key inside the assembler container before the
manifest is written.

The materialization had never executed before this phase. Nine defects
separated a description that read as working from a path that ran, and each
became visible only once the one ahead of it was fixed: a filesystem copy
implemented for macOS alone, a sysroot conflated with a build's library path,
a named sysroot that was never mounted, native-SDK inputs absent from the
assembly, and a verification tool read from a path no generation has. The
last of those was the sharpest — the published tool was Soong's
`python_binary_host` build of avbtool, an x86_64 ELF that could not have run
in the arm64 assembler container and could not have shipped in an arm64
payload. Assembly now asserts at publication that what it publishes is
architecture-neutral, and a test drives that guard with both shapes.

This is the same finding Phase 1 recorded about the AOSP lane, in the same
plan, for the second time: a lane described as working had never been run
end to end, and its coverage exercised its callers rather than its
execution. The tests around the tool-staging step passed against a fixture
whose container answered every command it did not recognize with a stub, so
the step had no coverage at all.

## Phase 5: Package Both Cohorts From Produced Inputs

The packaging lane consumes the produced package-input artifact for each
architecture instead of reading a tree with no producer. The `--android-arm64`
and `--android-x86-64` options are removed, along with the synthesized default
input path that no task produces.

Gate: `collider package linux-runtime` assembles and qualifies both
architectures' complete cohorts, including `nucleus-android`, from graph-produced
inputs alone, and the complete verification graph runs it on protected `main`.

Status: active. Each architecture's Android payload consumes its package-input
artifact, and the synthesized default input path is gone along with
`--android-arm64`, `--android-x86-64`, and the path-supplied
`collider android-runtime package-input` command.

The first half of the gate is met. `collider package linux-runtime` assembles
and qualifies both architectures' complete cohorts from graph-produced inputs
alone, including `nucleus-android` for each: `nucleus-android_arm64.deb`,
`nucleus-android-...aarch64.rpm`, and `nucleus-android-...aarch64.pkg.tar.zst`
beside their amd64 counterparts, alongside `nucleus`, `nucleus-runtime`,
`nucleus-browser`, `nucleus-development-host`, and `nucleus-session` in all
three families.

The remaining half is the verification graph running it on protected `main`.
`collider verify all` now requests the packaging entrypoint, so the graph
includes it; what remains is a sweep completing it.

## Phase 6: Qualify the arm64 Guest on Hardware

Activation gate: protected-main verification has completed Phase 5, the native
arm64 host-toolchain plan has removed translated Android host execution, and the
Android application-integration and container-security plans have completed
their agent-runnable gates.

The arm64 image boots under the rootless LXC runtime on arm64 Linux hardware and
satisfies the gates already defined by the Android container security and
Android application integration plans. Cross-architecture inspection and
translated execution do not satisfy them.

Gate: qualification records bound to the arm64 artifact and provenance digests,
covering cold boot, the host isolation boundary, application isolation, and
graphics and lifecycle failure paths.

## Risk Surface

The plumbing phases are mechanical: a file move, a parameterized path, a
duplicated board fragment, and a task graph that already loops over
architectures elsewhere. The substantive unknowns are concentrated in Phase 3
and Phase 6 — whether the Nucleus HALs and the gfxstream guest are genuinely
architecture-neutral in behavior as well as in source, and whether the arm64
guest boots and passes isolation and graphics qualification on real hardware.
Neither is answerable by inspection, and neither is a reason to defer the
phases that precede them.
