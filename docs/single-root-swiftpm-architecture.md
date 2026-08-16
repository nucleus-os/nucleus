# Single-Root SwiftPM Architecture

## Invariant

Every first-party Swift target belongs to one package rooted at the Nucleus
repository root. Target and module boundaries retain ownership and dependency
direction. Nested first-party package manifests do not survive the cutover.
Third-party source remains in independently versioned path packages.

Collider owns repository orchestration, native lanes, task attribution, and
artifact policy. SwiftPM owns one first-party package graph, one scratch
directory, one build database, incremental compilation, and test compilation.

## Production Shape

The root [`Package.swift`](../Package.swift) owns every first-party runtime,
library, executable, benchmark, generator, sanitizer harness, and test target.
It declares the complete host graph and activates the Android JNI targets only
for the Android compiler context. Third-party packages remain path
dependencies.

Component recipe modules live under `collider/Sources`. Collider and its engine
remain separate tooling packages, so the runtime graph has no dependency back
into orchestration.

The supported external Swift source products are `Nucleus`, `NucleusDesktop`,
`NucleusReactRuntime`, `NucleusFoundation`, `NucleusSessionProtocol`, and
`NucleusAndroidRuntimeCore`. They are automatic SwiftPM libraries because a
source-consumer boundary does not imply a shared-object deployment boundary.
`nucleus-android` remains explicitly dynamic because Android loads that JNI
artifact as a shared object. Internal protocols, generated Wayland modules,
Vulkan bindings, C++ bridges, shell implementation groups, and Linux
implementation groups remain targets rather than independently supported
library products.

A target boundary remains only when it owns behavior, visibility, a language or
toolchain seam, focused tests, a supported product, or a process entry point.
Thin executables depend directly on substantive testable runtimes; pass-through
targets that only reshape arguments, translate an exit status, or reexport an
unsupported product do not survive. `NucleusCompositor` therefore calls
`NucleusRenderServerRuntime` directly, while the runtime and its focused tests
remain separate from the executable process-policy entry point.

## Command Contract

The build and test commands use only public SwiftPM interfaces:

```sh
swift build \
  --package-path . \
  --scratch-path out/single-root-production \
  --build-system swiftbuild

swift test \
  --package-path . \
  --scratch-path out/single-root-production \
  --build-system swiftbuild
```

Collider synthesizes one of these operations for each compatible compiler
context. Component tasks retain attribution and source ownership, but they do
not launch SwiftPM independently. Runtime installation consumes the complete
root build instead of rebuilding each executable.

The root graph always declares the Android JNI product and its `swift-java`
dependency. Collider selects that product with an explicit Swift SDK and target
triple; ambient environment state never changes the manifest graph.

## Manifest and Destination Contract

The root manifest evaluates from a bare clone with Swift 6.4. Evaluation
reads no environment variables, launches no process, derives no repository root
from `#filePath`, and embeds no absolute host path. It declares one unconditional,
destination-independent product, dependency, and target graph. Platform
conditions and selected products determine the compiled closure without changing
the declaration graph.

First-party Swift targets share the repository's Swift 6 language mode, strict
memory-safety, warnings, and C++ interoperability contract. Repository-owned
headers, shims, and module maps use repository-relative paths. Targets name
semantic native libraries and link ordering without interpolating SDK roots or
absolute archives.

Collider owns compiler selection, Swift SDK artifact and directory, target
triple, native SDK roots, scratch path, generated SwiftPM header locations, and
execution environment. The selected target SDK owns its sysroot, stable native
search roots, pkg-config metadata, headers, and libraries. SwiftPM owns package
topology and generated module maps and `*-Swift.h` headers. None of these values
crosses boundaries through manifest-time environment lookup.

Linux ABI dependencies use checked-in system-library module maps and semantic
`pkgConfig` declarations. Collider supplies `PKG_CONFIG_LIBDIR` and
`PKG_CONFIG_SYSROOT_DIR` exclusively from the selected SDK. Nucleus-built static
archives retain explicit native-SDK search paths and link groups; target
toolchain primitives remain toolchain concerns rather than pkg-config packages.

Supported workflows invoke the installed `collider` command without sourcing
`tools/host-env.sh`. A fresh clone builds Collider with Xcode, publishes target
SDKs, provisions native SDK artifacts, and then builds and tests the root graph
through the ordinary setup, doctor, bootstrap, build, and test commands. There
is no parallel manifest-portability workflow or compatibility layer.

## SourceKit-LSP Result

The root package produces correct build settings and cross-target semantic
navigation after the replaced nested manifests and the old multi-root
`workspacePlan` setting are absent.

The semantic probe opened
`ipc/control-protocol/Sources/NucleusControlProtocol/ControlProtocol.swift`,
requested hover and definition information for `BindAction`, and received:

- the complete `BindAction` declaration and documentation;
- a definition location in
  `config/model/Sources/NucleusConfig/BindAction.swift`;
- a clean SourceKit-LSP shutdown.

Two migration constraints are mandatory:

1. The nested first-party manifests must be deleted in the same phase that
   lands their root target declarations. If they remain, SourceKit-LSP assigns
   a source file to its nearest legacy package and does not create a root
   language service for that file.
2. `.sourcekit-lsp/config.json` must stop supplying the multi-root
   `workspacePlan`. If it remains, SourceKit-LSP mixes the root graph with the
   legacy package graph and attempts to prepare targets the root prototype does
   not own.

## Decision

SwiftPM supplies the architecture the former multi-root patches
approximated:

- one invocation floor;
- one coherent incremental graph;
- source-file and target-level invalidation;
- one test compilation;
- standard SourceKit-LSP integration.

SwiftPM patches `0002` through `0005` and the SourceKit-LSP workspace-plan patch
are removed. The Linux builder applies one unrelated Nucleus-owned
SwiftPM/SwiftBuild host-tool overlay: it preserves the native host SDK for build
tools and their dependencies while an arm64 SwiftPM process cross-compiles an
x86_64 destination. Collider builds that overlay locally from exact pinned
SwiftPM and SwiftBuild root submodules using the official arm64 compiler,
persistent build state, host-materialized dependencies, and offline container
execution. Collider publishes it as a bounded directory, retains its producer
edge in every production SwiftPM invocation, and mounts it read-only rather than
copying it into the stable builder image. The overlay does not change the
package graph or public command contract and is not a separately published
release input.

## Verified State

- The repository root is the only first-party Swift package root.
- The host and Android manifests resolve deterministic product and target
  inventories for their selected destination. Verification compares the
  normalized inventories instead of embedding volatile counts in this document.
- `collider build` issues one ordinary root SwiftPM build invocation per
  compatible compiler context.
- `collider test` builds and executes the root test graph once.
- A warm no-op build has one invocation floor.
- SourceKit-LSP resolves cross-target symbols without a custom workspace plan.
- The complete host build and complete host test graph pass.
- Collider’s command suite passes against the public SwiftPM command contract.
