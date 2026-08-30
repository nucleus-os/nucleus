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

Status: complete

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

The run record names the active artifact by component, and more than one task
in this component claimed that name. The record is written only when a task
executes, so a run that published a generation recorded
`swift-sdk.publish-active-generation`'s identity while a run that reused one
recorded the always-run activation task's, for the same generation directory
and the same toolchain. Nothing reads that record for identity or scheduling,
so it never reached a consumer, but it is the line a reader checks this phase
against, and it reported movement where there was none.
`swift-sdk.publish-active-generation` is now the sole claimant, because its
`active-sdk` and `active-swift` outputs are what every consumer resolves, and a
clean task records the identity it already established, so the line names the
same artifact whether or not the run had work to do.

Gate met. A forced rebuild produced and published a generation, recording the
SDK artifact as `a6b07dd3`. The next run reused that generation, left
`swift-sdk.publish-active-generation` clean, and recorded the same `a6b07dd3`;
planning the whole build across that transition left all sixteen SDK consumers
clean, both architectures. `swift-sdk.activate-target-sdks` is the only task
still dirty, because it is declared to run every time, and it no longer moves
any identity by doing so.

## Phase 2: Face the Swift SDK so consumers depend on what they read

Status: complete

Skia declares `task.consume(builder.swiftSDK)` and mounts `builder.swiftSDKRoot`
read-only; gfxstream, Hermes, `rn.cxx`, `rn.support`, and wayland consume it the
same way. Each is a GN, Ninja, or CMake build of C and C++ containing no Swift.

What they read from that bundle is the target sysroot, and only that. The
compiler and linker are not in it: Skia's GN arguments name `cc="/usr/bin/clang"`
and `cxx="/usr/bin/clang++"`, which resolve inside the builder image every task
already consumes separately. The SDK contributes `--sysroot`, the libc++ include
root, and the libc++ library directory. The Swift standard library, Dispatch,
Foundation, XCTest, Swift Testing, and the SwiftPM overlay are inputs to none of
them, and `usr/lib/swift` and `usr/lib/swift_static` sit inside the same sysroot
directory as the native content, which is why a Swift-only change reaches them.

The reach is total rather than partial. Appending two lines of shell comment to
`swift-sdk/validate-target-sdk-artifacts.sh` -- a script that checks a finished
SDK and contributes nothing to one -- re-keys `swift-sdk.assemble-target-sdks`
and `swift-sdk.publish-active-generation` and dirties all sixteen SDK consumers
across both architectures. The validator reaches them because it is one of ten
inputs to the digest naming the generation directory, and every consumer depends
on the identity of the task that publishes that directory.

Achieved state: the Swift SDK artifact exposes a native-sysroot facet with an
identity of its own, alongside the full bundle. The facet is named by a digest
over what determines the native half -- every target's Ubuntu package set, the
first-party pkg-config files, and the SDK generator revision -- and excludes what
determines only the Swift half: the snapshot, the Swift source closure, the host
Xcode, the runtime builder context and preset, and the validation inputs, which
determine neither half. C and C++ tasks consume the facet. Swift compilation and
SwiftPM tasks consume the full bundle.

The facet is published by an always-run task holding Phase 1's invariant: it
re-points at whichever generation is active on every run, and its output identity
moves only when a native input moves. Keying it on the assembled bytes instead
was rejected: identity is computed during planning, so a digest of content this
run is about to produce names the previous run's bytes, and a genuine native
change would go unnoticed for exactly the run that introduced it. Input
provenance is what planning can know.

Gate met, in both directions. Appending a comment to the validator, which
previously dirtied all sixteen SDK consumers, now leaves all sixteen clean while
`swift-sdk.assemble-target-sdks`, `swift-sdk.validate-target-sdks`, and
`swift-sdk.publish-active-generation` re-execute. Replacing one target's
`libvulkan-dev` checksum dirties every C and C++ build on both architectures,
which is what distinguishes a facet that tracks the native half from one that
never moves.

`swift-sdk.publish-native-sysroot` is the always-run publisher. It reaches the
active bundle by ordering rather than by consuming it, so the SDK it faces
contributes nothing to its identity, and it carries no artifact references or
identity dependencies at all. `wayland.generator` and `wayland.generate` keep the
full bundle: both execute Swift, so the Swift half is genuinely theirs.

The validator and the validation fixture still name the generation directory, so
a change to either re-assembles an SDK it cannot affect. Removing them was tried
and reverted, and the reason is worth keeping: the validation tasks consume
`assembly.hostSwift`, each target's SDK artifact, and `assembly.linuxSDK`, so
they are planned only on the generation path. Naming the generation after the
validator is therefore the only thing that re-runs validation when the validator
changes -- wastefully, by rebuilding an identical SDK, but it is load-bearing.
Dropping it measured clean everywhere, including the validation tasks, because
on the reuse path they are not planned at all. That is a verification gate
failing open, which no saving justifies.

The order is therefore fixed: make validation runnable against a published
generation first, then remove the coupling. Until the first exists, the
generation digest keeps naming inputs that do not define it.

The claim the facet makes is that the listed inputs determine the native half of
the sysroot. Verify it directly rather than by inspection: after the snapshot
rebase, diff the previous and current generations' sysroots with `usr/lib/swift`
and `usr/lib/swift_static` excluded, and require them byte-identical. A
difference means an input is missing from the facet digest, and the facet must
grow to include it.

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
