# Collider Process Execution Plan

Status: active

## Invariant

Collider runs a child process one way. Every execution captures output through
concurrently drained streams, so no invocation can deadlock because a child
filled one pipe while the parent was reading another, and no execution blocks a
cooperative thread while it waits. `Foundation.Process` driven by sequential
reads is neither, and no layer reaches for it because the layer it needs sits
above it.

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

The structural cause is not that `Subprocess` is declared for one module. It is
that `Subprocess` is async-only — every `run` overload it offers is `async
throws` — and all five sites are synchronous functions. A site cannot adopt it
without becoming async, and for the two in `ColliderPersistence` the
synchronous chain above them is the whole planning layer:
`PlanningArtifactDigestCache`, `PlanningInputProvider`, the closure types in
`TaskPlanningServices`, `TaskIdentityBuilder`, `ColliderPlanner`, and the
`planning:` closure the engine invokes.

That chain is narrower than it appears. Recipes never call these services; they
declare `.sourceCheckout(path)` inputs, and the planner resolves them, so
`TaskPlanningServices` is confined to `ColliderPlanning` and the engine. Of its
eight closures only two run a child process — `digestSourceCheckout` and
`digestSourceCheckoutClosure`. `semanticToolIdentity` resolves a name against
`PATH` and hashes the resulting binary, and `digestFile` and `digestTree` read
the filesystem, so all three stay synchronous.

There is a second defect the deadlock hides. Planning is invoked from an async
context and computes on the calling thread, so hundreds of blocking Git
invocations run on a cooperative thread. Blocking a cooperative thread is wrong
independently of which pipe is drained first, and no arrangement of
synchronous reads fixes it. This is why the source-identity path becomes async
rather than gaining a synchronous concurrent drain: a synchronous drain would
resolve the deadlock and leave Collider blocking the pool for the duration of
every cold source closure.

The persistence layer is also the highest-exposure one. Source capture runs Git
once per checkout across the hundreds in a source closure, and its own comment
records an earlier resource defect at the same site: waiting for pipes to close
on deallocation leaked four descriptors per invocation and exhausted the
process limit before the closure finished hashing.

## Phase 1: Make the Source-Identity Path Async

`digestSourceCheckout` and `digestSourceCheckoutClosure` become `async throws`
in `TaskPlanningServices`, and the path that serves them becomes async with
them: `TaskIdentityBuilder` where it resolves those two inputs,
`ColliderPlanner.plan`, the engine's `planning:` closure and its two call
sites, `PlanningInputProvider`, and `PlanningArtifactDigestCache` including its
recursive memoization of nested checkouts. `ColliderPersistence` declares
`Subprocess` as a dependency, which introduces no cycle because the dependency
is external to the engine graph, and `GitSourceCheckoutHasher` and
`ProductArtifactSourceSnapshot` capture their children through it.

The digest cache stays a single-task memoization. Planning remains one
operation with no internal concurrency, so making its functions async
introduces suspension points but no shared mutable state across isolation
domains, and the cache's own comment records that mutation is confined to one
planning operation.

These two sites are first because they carry the exposure: one runs per
checkout across a whole source closure, both feed source provenance, which is
an input to task identity, and both run today on a cooperative thread.

Gate: source capture and artifact source snapshotting run through concurrently
drained streams on the runtime's execution path; a child that writes more than
a pipe buffer to standard error and to standard output is captured completely
on both streams; a source closure hashes with no descriptor growth across
checkouts; and the recorded provenance for an unchanged closure is byte
identical to the provenance recorded before the change.

## Phase 2: Convert the Command Layer

`SwiftPackageGraphResolver`, `MacOSBuilderProvisioning`, and
`ManagedSkillDocumentation` capture their children through the same path,
reaching it by `WorkspaceContext.run` where the call is command-shaped and by
`Subprocess` directly where it is not. Each becomes async along the chain that
reaches it: `swiftPMInvocation` and its seven call sites across three files for
the resolver, and the skill command adopts `AsyncParsableCommand`, which
`CommandGroups` already uses for other commands.

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

The substantive unknown is Phase 1's reach into planning. The measured surface
is seven files in the engine package and no recipe, but planning is the layer
every command passes through, and an async conversion that reaches
`ColliderPlanner` touches how every task's identity is computed. The gate
compares provenance rather than trusting the conversion, and the whole
repository's task identities are the check: an unchanged checkout that replans
to different identities is the failure this phase must not produce.

The deadlock is latent rather than observed. No capture has hung, and the
argument for this work rests on the shape of the code, on the cooperative-thread
blocking that is not latent at all, and on the descriptor defect already found
at the same site. The reproduction the gate names — a child that fills both
pipes — is written before the conversion, so the fix has something that fails
without it.
