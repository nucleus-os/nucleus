# Collider Process Execution Plan

Status: complete

## Invariant

Collider runs a child process one way. Every execution captures output through
concurrently drained streams, so no invocation can deadlock because a child
filled one pipe while the parent was reading another, and no execution blocks a
cooperative thread while it waits. No layer reaches for `Foundation.Process`,
because every layer has an execution path available to it.

## Current State

Two mechanisms execute child processes. `ColliderRuntime` uses the pinned
`nucleus-os` fork of `swift-subprocess`, which drains concurrently by
construction, and `WorkspaceContext.run` routes command-shaped work through it.
Every other layer reaches the same fork through `CapturedChildProcess` in
`ColliderProcess`, which owns how Collider captures a child.

No site constructs `Foundation.Process`. Five did before Phases 1 and 2, and
three of them shared one shape:

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
throws` — and every one of these sites is a synchronous function. A site cannot
adopt it without becoming async, and for the two in `ColliderPersistence` the
synchronous chain above them was the whole planning layer:
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

Status: complete. `CapturedChildProcess` is the persistence layer's execution
entry point, and `GitSourceCheckoutHasher` and `ProductArtifactSourceSnapshot`
reach `Subprocess` through it. The async path runs from
`TaskPlanningServices` through `TaskIdentityBuilder`, `ColliderPlanner`, and
the engine's planning closure down to `PlanningArtifactDigestCache`, and no
recipe changed.

Gate evidence: `collider build runtime --dry-run --explain-identity` produces
a byte-identical identity dump across all 16,712 encoded component lines and
all 18 planned task identities, including `core.skia.linux-arm64`, whose
closure spans 53 checkouts. A child filling either pipe while the other stays
open is captured completely on both streams, sixty-four consecutive captures
end with no more open descriptors than they started with, and
`collider test collider` passes.

Two encoders had to be restructured, because `IdentityEncoder.appendSequence`
takes a synchronous closure and source capture suspends. Both now resolve
their digests before encoding and encode from what the resolution produced.
The branch deciding whether Git already identifies a path has one definition
that both passes call: a disagreement between them would change what a source
checkout hashes to, which is the failure this phase exists to avoid.

The capture limit found its own defect. It was first set to 16 MB on the
stated assumption that Git output is small, and `llvm-project` — 165k tracked
paths, 16.9 MB from `ls-files -s -z` — exceeded it on the first real run. The
limit is now sized against that measurement rather than against an
assumption.

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

Status: complete. No `Foundation.Process`, `Pipe`, or `readDataToEndOfFile`
remains anywhere in Collider. Three sites were in the deadlock class —
`SwiftPackageGraphResolver.runSwiftPackage`,
`MacOSBuilderProvisioning.githubResponse`, and
`ManagedSkillDocumentation.runGit` — and `commandSucceeds` was not, because it
discarded both streams; each records which reason applies. `githubResponse`
also lost the comment that excused its ordering, which rested on how much a
third-party tool writes to standard error.

Gate evidence: the identity dump is byte identical to the baseline recorded
before Phase 1, across all 16,712 encoded component lines and all 18 planned
task identities, which is what covers dependency resolution — `swiftPMInvocation`
feeds task construction. `collider skill verify collider` verifies the
generated skill, and `collider skill verify swift-cxx-interop` clones from
Swift.org through the converted capture and correctly reports the checked-in
content as behind upstream. `collider test collider` passes. Builder
provisioning is not exercised here: it reconciles a GitHub runner group and
needs organization credentials this host does not hold.

Two structural changes were required rather than optional. `CapturedChildProcess`
moved to its own `ColliderProcess` target: cross-package API in Collider is
`public`, so leaving it in `ColliderPersistence` would have published a
subprocess primitive as part of the persistence library's contract. And
`SwiftPackageGraphResolver` held a mutex across a whole materialization to
describe each package root exactly once; describing suspends now, so an actor
holds the in-flight materialization and callers share that instead of a lock.

Converting the skill commands exposed a latent defect in command dispatch.
`ColliderCommand.execute` ran every non-workspace command through the
synchronous `run()`, and `ParsableCommand` supplies one that requests help, so
an `AsyncParsableCommand` reached that way printed usage and exited zero
instead of running. Nothing had triggered it: every async command until now was
either a workspace command or a group with no `run()` of its own. The
informational path now dispatches an async command as such.

## Phase 3: Leave One Way To Do It

Two modules construct a child process, and each owns a distinct kind of
execution. `ColliderRuntime` runs a task's command: logged, cancellable,
streamed, and able to hold the terminal. `ColliderProcess` captures a child
whose output is decoded rather than reported, which is what a layer needs when
routing through the run log would be wrong — a control-plane response carrying
a registration token, or source provenance hashed below the runtime in the
dependency graph. `WorkspaceContext.run` is the command layer's route into the
runtime rather than a third mechanism.

Both build the child's environment through one definition, because a rule
deciding what a child may inherit is exactly the kind that drifts when it is
written twice.

The structural property is what keeps the invariant: a layer with an execution
path available to it has no reason to construct a process by hand.

Gate: every execution site names the entry point its layer exposes, and the
entry points are the only places that construct a child process.

Status: complete. Only `ColliderRuntime` and `ColliderProcess` import
`Subprocess`, and the six `Subprocess.run` call sites in Collider are inside
those two modules. No source constructs a child by any other means: there is no
`posix_spawn`, `fork`, `popen`, `execve`, `system`, or `NSTask` in the Swift
sources or in the C shim.

`ChildProcessEnvironment.validated` is the one place that decides whether a
name and value may reach a child. `ColliderRuntime` had its own copy of those
rules and its own pair of error cases for them; both are gone, and the
duplicate cases were removed rather than left unused.

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
