# Single-Root SwiftPM Architecture

## Invariant

Every first-party Swift target belongs to one package rooted at the Nucleus
repository root. Target and module boundaries retain ownership and dependency
direction. Nested first-party package manifests do not survive the cutover.
Third-party source remains in independently versioned path packages.

Collider owns repository orchestration, native lanes, task attribution, and
artifact policy. Stock SwiftPM owns one first-party package graph, one scratch
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

## Command Contract

The build and test commands use only stock SwiftPM interfaces:

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

Android cross-compilation sets `NUCLEUS_TARGET_PLATFORM=android`, which adds the
JNI product and its `swift-java` dependency to the same manifest without
placing target-only JNI headers in the host graph.

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

Stock SwiftPM supplies the architecture the former multi-root patches
approximated:

- one invocation floor;
- one coherent incremental graph;
- source-file and target-level invalidation;
- one test compilation;
- standard SourceKit-LSP integration.

SwiftPM patches `0002` through `0005` and the SourceKit-LSP workspace-plan patch
are removed. Unrelated toolchain fixes remain.

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
- Collider’s command suite passes against the stock SwiftPM command contract.
