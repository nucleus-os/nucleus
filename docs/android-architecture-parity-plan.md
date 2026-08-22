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

One AOSP product exists. `android-runtime/aosp-product.lock.json` pins
`nucleus_x86_64`, and `AOSPProductLock.validate()` rejects every other product,
so the pin is a hard constraint rather than a default.

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

The Android image pipeline is single-product. `aospProductImageTasks` names one
product source directory, produces one generation under one active-generation
link, and declares one set of storage and workspaces. Product validation asserts
the single pinned product.

The package input is containerized but unselected. Its materialization runs in
the builder image, and it verifies that the generation's provenance matches the
architecture it packages for. Nothing in the catalog declares it, and the
packaging lane still reads the input as a supplied tree with no producing task,
through `--android-arm64` and `--android-x86-64`.

The consequence is that the arm64 cohort declares `nucleus-android` as an exact
member and no product in this repository can produce it. Native package
distribution records an earlier run assembling and qualifying arm64 cohorts,
which the current provenance check would not admit from an x86_64 generation;
that evidence is superseded by the gates below rather than relied on.

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

## Phase 2: Add the arm64 Product

`device/nucleus/nucleus_arm64` declares the four architecture settings for
arm64 and inherits the shared tree. `AndroidProducts.mk` in each product
directory names its own product. The product lock becomes one entry per
architecture, and `AOSPProductLock.validate()` admits each product for its own
architecture and no other.

The native HALs and the gfxstream guest compile for arm64 under Soong. This is
the phase where a genuine architecture dependency in the guest surfaces, and any
that does is fixed in the shared tree rather than forked per product.

Gate: `nucleus_arm64` compiles, assembles its complete raw image set, signs with
the AVB identity the graph generates, and passes product validation with arm64
provenance.

## Phase 3: Build Both Products in the Graph

`aospProductImageTasks` becomes one task graph per architecture. Each product
has its own generation, active-generation link, output workspace, compiler cache
workspace, and storage declarations, and records provenance naming its own
product. Source materialization remains shared: one Repo-managed AOSP checkout
serves both products.

Gate: both generations exist simultaneously, each records its own product and
architecture, and building one does not invalidate the other.

## Phase 4: Produce Both Package Inputs From the Graph

The package input task is declared per architecture. Each consumes its own AOSP
generation and the AVB signing identity as artifacts rather than as paths
hashed at planning, builds the Android runtime products for its architecture,
and materializes inside the builder image.

Gate: both package inputs are produced by the ordinary graph on the macOS
builder, each carrying provenance for its own architecture, with no input
supplied by path.

## Phase 5: Package Both Cohorts From Produced Inputs

The packaging lane consumes the produced package-input artifact for each
architecture instead of reading a tree with no producer. The `--android-arm64`
and `--android-x86-64` options are removed, along with the synthesized default
input path that no task produces.

Gate: `collider package linux-runtime` assembles and qualifies both
architectures' complete cohorts, including `nucleus-android`, from graph-produced
inputs alone, and the complete verification graph runs it on protected `main`.

## Phase 6: Qualify the arm64 Guest on Hardware

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
architectures elsewhere. The substantive unknowns are concentrated in Phase 2
and Phase 6 — whether the Nucleus HALs and the gfxstream guest are genuinely
architecture-neutral in behavior as well as in source, and whether the arm64
guest boots and passes isolation and graphics qualification on real hardware.
Neither is answerable by inspection, and neither is a reason to defer the
phases that precede them.
