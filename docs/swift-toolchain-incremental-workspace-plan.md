# Swift Target SDK Workspace Plan

## Invariant

The checksum-pinned official Swift.org macOS 6.4 snapshot supplies Swift,
SwiftPM, Swift Build, compiler plugins, and macros on the M2 Ultra. Xcode 27.1
supplies the macOS SDK and developer tools. Every host executable runs as a
native macOS arm64 process. Nucleus does not build a Swift compiler, Linux host
toolchain, LLVM host toolchain, LLDB, SourceKit-LSP, DocC, or SwiftPM.

Collider assembles immutable target SDK generations for Linux amd64, Android
arm64, and Android amd64. The SDKs supply target sysroots, Swift runtime
resources, native headers and libraries, target compiler flags, and linker
configuration. No Linux or Android executable runs during generation or
validation. Rosetta, QEMU, an amd64 VM, and an amd64 build machine are absent
from the build graph.

The Swift 6.4 inputs are the checksum-pinned official 2026-07-23 release-branch
packages:

- `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a-osx.pkg` for native macOS
  host tools;
- `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_android.artifactbundle.tar.gz`;
- `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a-ubuntu24.04.tar.gz` for
  Linux amd64 runtime resources.

The downloadable static Linux SDK is intentionally absent because it targets
musl. Nucleus targets `x86_64-unknown-linux-gnu`; Collider combines the Ubuntu
24.04 target package with a checksum-pinned Ubuntu amd64 package closure through
`swift-sdk-generator --no-host-toolchain`. The generator and every extraction,
copy, metadata, and validation process run directly on macOS arm64.

Xcode identity, official SDK digests, Nucleus native SDK digests, SDK assembly
code, and target configuration select immutable published generations. They do
not select mutable download or assembly workspaces. Unchanged inputs perform no
download, extraction, copying, or publication work.

## Current Defect

`collider toolchain rebuild` still models Swift platform generation as a Linux
host-toolchain build. It builds LLVM and Swift, packages host executables, then
cross-builds Android runtimes from that generated compiler. The recipe therefore
contains translated and native-Linux execution platforms, compiler build
presets, CMake/Ninja host roots, ccache state, NDK Linux host-tool paths, and
host-toolchain validation.

That work is unnecessary. Xcode 27.1 reports Swift 6.4 with compiler tag
`swiftlang-6.4.0.27.1`, but it cannot deserialize the July 23 snapshot's newer
C++ module interfaces. Swift.org publishes one matching macOS, Linux, and
Android snapshot set from 2026-07-23. Collider extracts the signed macOS package
into the immutable generation and uses those native host tools with the target
SDKs. It does not compile them.

Nucleus fork patches introduced for the monolithic toolchain build do not
justify retaining that build. Build-script, DocC, Swift Testing, compiler-cache,
and Linux-host packaging repairs disappear with the pipeline. Target behavior
that remains necessary is represented in SDK contents and target flags. A
compiler or package-manager fork is added back only if a behavioral test proves
that the pinned Xcode toolchain cannot express the required SDK contract.

## Phase 1 — Pin Official Target SDK Inputs

Add one checked-in target-SDK lock describing the exact Swift snapshot, source
URLs, SHA-256 digests, maximum response sizes, and accepted media types.
Collider parses and validates this lock before constructing tasks.

The initial Swift pins are:

- Android SHA-256
  `c5bb1c4399375c1a59c6aa672f3f81014e111de0d464ada8ae8cc5814ce29681`;
- Ubuntu 24.04 amd64 target-package SHA-256
  `05670a1487e907e732ca701bfda153e5f02aeac801dd3b07686f2aae4e0c6ad5`.

The lock also records the exact Ubuntu amd64 package URLs and SHA-256 digests
that form the sysroot. Package-index state is never an artifact input. Updating
the Ubuntu package closure is an explicit lock update.

Downloads use Collider's bounded, resumable, digest-verifying downloader and a
shared content-addressed download cache. The build never asks a container or
guest to access the network.

Phase 1 is complete when both archives download through Collider, their digests
match the lock, and a second run reuses both files without network work.

## Phase 2 — Remove Swift Host-Toolchain Generation

Delete the host-toolchain task graph and every input used only by it:

- Linux OCI Swift builder image and entry point;
- LLVM and Swift build presets and CMake overrides;
- host staging, host archive, host validation, and host package tasks;
- CMake, Ninja, SwiftPM, and ccache host build roots;
- source-gitlink identity as a compiler artifact selector;
- translated and native-Linux Swift builder execution;
- retired-layout scanners, migration code, and compatibility paths.

The Swift SDK task graph contains no OCI operation. It builds the pinned
`swift-sdk-generator` executable with Xcode into an external scratch directory,
then runs it directly on macOS with already downloaded target inputs.

`collider toolchain rebuild` requires the selected Xcode identity and invokes
the extracted Swift.org macOS toolchain directly. `collider toolchain status`
reports both the Swift.org compiler version and the selected Xcode identity.

Phase 2 is complete when no toolchain command can schedule a Swift compiler or
LLVM build and no Rosetta, Linux host-toolchain, or NDK Linux executable path
remains in the Swift SDK workflow.

## Phase 3 — Normalize Official SDK Bundles

Extract the official Android artifact bundle into a candidate-owned directory.
Generate the Linux artifact bundle from the pinned Ubuntu target package and
sysroot package closure. Parse `info.json` and every referenced Swift SDK
metadata file. Reject unexpected artifact IDs, triples, architectures, path
escapes, missing resources, and toolset executables.

Select exactly these destinations:

- `x86_64-unknown-linux-gnu`;
- `aarch64-unknown-linux-android<api>`;
- `x86_64-unknown-linux-android<api>`.

Publish the selected SDK entries as Nucleus-owned immutable artifact bundles.
Preserve upstream runtime resources and sysroots without rewriting their formats.
Replace host-tool paths with native macOS arm64 tools selected by Collider.
Android uses the NDK's native macOS arm64 tool slice. Linux uses a pinned native
macOS arm64 clang/lld toolset capable of producing ELF amd64 objects.

Phase 3 is complete when Xcode SwiftPM resolves each target by artifact ID and
explicit triple and emits the expected target compiler and linker commands.

## Phase 4 — Add Nucleus Native SDK Contents

Extend each normalized SDK entry with the matching Nucleus native artifacts:

- Linux amd64 render and React Native headers and libraries;
- Android arm64 render and native-library outputs;
- Android amd64 render and native-library outputs;
- checked-in module maps and SDK-local `pkg-config` metadata;
- libc++ include and library selection required by C++ interoperability;
- Android's 16 KiB maximum-page-size linker contract.

The SDK owns paths and search roots. `Package.swift` retains semantic imports,
library names, target defines, and linker ordering. No absolute SDK path or
environment lookup enters the manifest.

Phase 4 is complete when the manifest evaluates without Nucleus environment and
all three destinations resolve their native headers and libraries exclusively
through the selected SDK.

## Phase 5 — Validate Without Target Execution

For each destination, Xcode SwiftPM compiles and links a behavioral consumer.
Validation never launches the resulting binary.

Validate:

- Swift SDK metadata and exact target triple;
- ELF class, machine architecture, interpreter, and dynamic dependencies;
- absence of host Mach-O objects and wrong-architecture archives;
- Swift runtime and C++ runtime linkage;
- static and dynamic Swift linkage where supported;
- Foundation, Dispatch, Testing, C++ interoperability, and macro compilation;
- Android 16 KiB maximum-page-size alignment;
- Nucleus render and React Native link closure.

Use native macOS arm64 inspection tools or parsers. Do not invoke an executable
from an SDK toolset unless validation has first established it as Mach-O arm64.

Phase 5 is complete when all three consumers compile and link and every output
passes structural validation.

## Phase 6 — Publish and Prove Incremental Reuse

Candidate extraction and assembly remain isolated from the active generation.
Publication validates the complete candidate, atomically installs its immutable
generation, and updates the active reference only after success.

Use one exclusive SDK-assembly lock. Report download reuse, extraction reuse,
assembly reuse, validation reuse, and publication state. A failed rebuild leaves
the active SDK unchanged.

Run these proofs in strict order:

1. Fresh generation downloads, assembles, validates, and publishes.
2. Unchanged generation schedules no download or assembly work.
3. A Nucleus native SDK input change rebuilds only the affected target entry and
   aggregate publication.
4. A Swift SDK lock change creates a new immutable generation without mutating
   the previous one.
5. Concurrent rebuilds serialize candidate mutation and converge on one active
   generation.

Phase 6 is complete when all proofs pass on the M2 Ultra.

## Acceptance Criteria

- The signed Swift.org macOS snapshot is the only Swift host toolchain; Xcode
  supplies the macOS SDK and developer tools.
- Collider builds no Swift compiler, LLVM host toolchain, or Linux host tools.
- Official Swift 6.4 Linux and Android target inputs and the Ubuntu sysroot
  closure are checksum pinned.
- Linux amd64, Android arm64, and Android amd64 are selected by exact triples.
- Every build and validation process executed on the M2 is macOS arm64.
- No Rosetta, QEMU, amd64 VM, amd64 machine, or target execution is required.
- Nucleus runtime products compile and link through complete target SDKs.
- Published generations are immutable and failure-safe.
- Unchanged inputs perform no download, extraction, assembly, or publication.
- No old toolchain pipeline, migration reader, cleanup scanner, or compatibility
  path remains.
- No Swift SDK task schedules an OCI operation or requires an Apple container
  service.
