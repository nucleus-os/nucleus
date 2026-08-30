# Task identity precision

Status: active

## Invariant

A task re-executes when, and only when, an input it actually reads has changed.
Consuming an artifact means consuming the part of it the task reads, not
everything the producing task happened to bundle together. A task declared to
run every time re-runs its own action, and it does not change its output
identity when its own inputs have not changed: an always-run task whose output
identity moves converts itself into an always-run subgraph.

## Established measurements

A revision changing three files -- the SwiftPM overlay pin, one document, and
the SwiftPM gitlink -- left 215 of 286 tasks clean and gave 71 tasks work. The
71 are almost entirely Swift SDK consumers, and they include six C and C++
builds that contain no Swift: Skia, gfxstream, Hermes, `rn.cxx`, `rn.support`,
and wayland, each for both Linux architectures.

The same set re-executes on a local build with no source change at all. That
run finished in roughly seven minutes, because ccache and the persistent ninja
and CMake workspaces find nothing to do, so the present cost is one container
start and one no-op build-system pass per task rather than recompilation. The
cost stops being absorbed exactly when the SDK genuinely changes: the first
sweep after the August 26 toolchain rebase spent 46 minutes rebuilding those
same components, and that rebuild was legitimate.

Two mechanisms produce the churn, and they compound.

## Phase 1: Give one active generation one identity

Status: active

The recipe built the active Swift SDK generation through two mutually exclusive
paths. `swift-sdk.activate-target-sdks` ran when a full generation was produced,
and `swift-sdk.use-active-generation` ran when `activeGenerationIsReusable` found
an existing generation the active symlink already resolved to. Both declared the
same `generation-marker` output, at the same path, holding the same content.
They were different tasks with different identities, so the recorded identity of
that marker depended on which path last produced it.

`swift-sdk.publish-active-generation` consumes that marker, and every consumer
of the SDK consumes its result. Each flip between the two paths therefore
changed the marker's producing identity, changed the published SDK artifact
identity, and invalidated every SDK consumer -- while the generation directory
on disk, the toolchain in it, and the marker's own 45 bytes of content were all
unchanged.

Three consecutive runs demonstrated the flip. A sweep took the activation path,
a following local build took the reuse path and reported
`publish-active-generation` moving from `410e` to `97cc`, and the next sweep
took the activation path again and recorded `97cc`. Nothing about the SDK
differed across the middle transition; only the identity of the task that
asserted it did.

The flip was not command-scoped. `forceSwiftSDKGeneration` is set only by
`collider build swift-sdk --rebuild`; every other invocation passes
`reuseActiveGeneration: true` and lets `activeGenerationIsReusable` decide, so
the path alternated whenever an SDK input changed and then stopped changing --
exactly the local-iteration-then-sweep pattern this repository works in.

Achieved state: one active generation has one identity, whichever path
established it. A run that reuses an existing generation records the marker
identity that producing it would have recorded, so alternating between the two
paths leaves the SDK artifact identity and every consumer of it clean.

`swift-sdk.use-active-generation` no longer exists. Both paths build
`swift-sdk.activate-target-sdks`, with the same output slot, inputs, locks,
postcondition, assessment policy, and action. The generation directory is named
by a digest over everything that defines it, and the marker's output path
carries that name, so the name is what identifies the assertion. Whether the run
produced the generation or found it published is a difference in the work the
run had to do, not in which SDK is active.

The generation subgraph therefore reaches activation as an ordering edge rather
than a consumed artifact. `ArtifactReference.ordering` expresses that: run after
this artifact's producer without taking its identity. `TaskDeclaration` already
separated `dependencies`, which identity encodes, from `executionDependencies`,
which adds ordering; the edge was simply the wrong kind. The activation action
publishes a staged candidate when one exists and otherwise requires the
generation's own marker, so a genuinely missing candidate stays an error rather
than becoming a silent success.

Landed with a recipe test asserting that every field planning encodes into a
task identity matches across the two paths while the ordering edge does not, and
that activation carries no artifact references or identity dependencies at all.

Remaining gate: a full SDK generation, then a consumer build that takes the
reuse path, then a third run, where the SDK artifact identity is identical
across all three and no SDK consumer re-executes across the flip. The first run
after this change re-keys the activation identity once, because the recorded
identity was produced under the old encoding; the gate reads the two runs after
that one.

## Phase 2: Face the Swift SDK so consumers depend on what they read

Skia declares `task.consume(builder.swiftSDK)` and mounts `builder.swiftSDKRoot`
read-only; Hermes, gfxstream, wayland, and `rn.cxx` consume it the same way.
Each is a GN, Ninja, or CMake build of C and C++ that reads clang, the linker,
and the Ubuntu sysroot out of that bundle. The Swift standard library, Dispatch,
Foundation, XCTest, Swift Testing, and the SwiftPM overlay are not inputs to any
of them, and a change confined to those currently invalidates all five across
both architectures.

Achieved state: the Swift SDK artifact exposes a native-toolchain facet holding
clang, the linker, and the sysroot, with an identity of its own, alongside the
full bundle. C and C++ tasks consume the native facet. Swift compilation and
SwiftPM tasks consume the full bundle. A change confined to the Swift half of
the SDK leaves every C and C++ component clean.

This phase lands after Phase 1 because Phase 1's gate is the instrument that
proves it: while the activation identity still moves every run, no consumer can
be observed staying clean.

Gate: change the SwiftPM overlay revision and confirm Skia, Hermes, gfxstream,
wayland, and `rn.cxx` remain clean for both architectures while the SwiftPM
tasks re-execute. Then rebase the Swift SDK onto a newer snapshot and confirm
the same five do rebuild, because clang changed with it.

## Non-goals

- Do not reduce the always-run surface of the release-gate tasks, the macOS
  package tests, or Collider's own host tests. A verification sweep re-running
  its gates is the gate, and their cost is not what this plan measures.
- Do not treat content-named `swift.package.*` tasks reporting `no prior task
  state` as a defect. Those task names carry their identity by construction, so
  a changed input produces a new name rather than a comparison against an old
  record, while SwiftPM's own incremental state lives in the persistent
  workspace that survives the rename.
- Do not split the workflow's single verification command into separate build
  and test steps to pursue this. `verify` holds the exclusive verification lock
  across the whole build-and-test closure; two steps drop that lock between
  them, and holding it across steps requires a session surface the
  [GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md)
  lists as an explicit Non-Goal. The redundancy this plan removes is in the
  identity graph, and no workflow shape recovers it.
- Do not weaken or bypass container-level caching to compensate for identity
  churn. The caching is what currently absorbs the cost; the churn is the defect.
