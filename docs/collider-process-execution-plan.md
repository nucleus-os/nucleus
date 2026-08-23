# Collider Process Execution Plan

Status: active

## Invariant

Collider runs a child process one way. Every execution captures output through
concurrently drained streams, so no invocation can deadlock because a child
filled one pipe while the parent was reading another. `Foundation.Process` is
not that way, and no layer reaches for it because the layer it needs sits above
it.

## Current State

Two mechanisms execute child processes. `ColliderRuntime` uses the pinned
`nucleus-os` fork of `swift-subprocess`, which drains concurrently by
construction, and `WorkspaceContext.run` routes command-shaped work through it.
Five sites construct `Foundation.Process` directly:
`GitSourceCheckoutHasher` and `ProductArtifactSourceSnapshot` in
`ColliderPersistence`, `SwiftPackageGraphResolver` and
`MacOSBuilderProvisioning` in `ColliderWorkspaceCommands`, and
`ManagedSkillDocumentation` in `ColliderCLI`.

Three of them share one shape:

```swift
try process.run()
let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
```

The parent reads standard output to end of file before it reads standard error.
A child that fills the standard error pipe before closing standard output
blocks on that write while the parent blocks on its read, and neither moves.
Git reaches that volume through progress output, submodule warnings, and
detached-head advisories. The deadlock is inherent to draining two pipes in
sequence and is not specific to an operating system or a Foundation
implementation.

The split has a structural cause rather than a careless one. `ColliderRuntime`
depends on `ColliderPersistence`, so the persistence layer cannot reach the
runtime's execution path, and `Subprocess` is declared as a dependency of
`ColliderRuntime` alone. A persistence-layer site that needs a child process
has nothing to call.

That layer is also the highest-exposure one. Source capture runs Git once per
checkout across the hundreds in a source closure, and its own comment records
an earlier resource defect at the same site: waiting for pipes to close on
deallocation leaked four descriptors per invocation and exhausted the process
limit before the closure finished hashing.

## Phase 1: Give the Persistence Layer an Execution Path

`ColliderPersistence` declares `Subprocess` as a dependency, which introduces no
cycle because the dependency is external to the engine graph.
`GitSourceCheckoutHasher` and `ProductArtifactSourceSnapshot` capture their
children through it.

These two are first because they carry the exposure: one runs per checkout
across a whole source closure, and both feed source provenance, which is an
input to task identity.

Gate: source capture and artifact source snapshotting run through concurrently
drained streams, a source closure hashes with no descriptor growth across
checkouts, and the recorded provenance for an unchanged closure is identical to
the provenance recorded before the change.

## Phase 2: Convert the Command Layer

`SwiftPackageGraphResolver`, `MacOSBuilderProvisioning`, and
`ManagedSkillDocumentation` capture their children through the same path,
reaching it by `WorkspaceContext.run` where the call is command-shaped and by
`Subprocess` directly where it is not.

A site that captures only one stream is not in the deadlock class, and its
conversion is for singularity of mechanism rather than for correctness. Each
such site records which of the two reasons applies.

Gate: no site in Collider constructs `Foundation.Process`, and dependency
resolution, builder provisioning, and skill generation produce the same results
as before the change.

## Phase 3: Leave One Way To Do It

Each layer exposes exactly one execution entry point: `WorkspaceContext.run`
above the runtime, and the runtime's own path below it. The structural property
is what keeps the invariant, because a layer with an execution path available to
it has no reason to construct a process by hand.

Gate: every execution site names the entry point its layer exposes, and the
entry points are the only places that construct a child process.

## Risk Surface

Source provenance is an input to task identity, so a change to how Git output is
captured must produce byte-identical provenance for an unchanged closure.
Anything else silently invalidates every task that consumes a source checkout,
which is why Phase 1 gates on comparing recorded provenance rather than on the
capture merely succeeding.

The deadlock is latent rather than observed. No capture has hung, and the
argument for this work rests on the shape of the code and on the descriptor
defect already found at the same site, not on a reproduction. A reproduction
would need a child that fills one pipe while holding the other open, which is
straightforward to construct and worth constructing before Phase 1 rather than
after, so the fix has something that fails without it.
