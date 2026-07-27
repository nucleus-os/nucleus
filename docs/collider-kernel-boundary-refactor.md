# Collider Kernel Boundary and Execution Model

## Invariants

**Kernel ownership.** Collider owns task identity, execution sessions, declared
effects, scheduling, locking, state, caching, and event recording. It contains no
AOSP, Chromium, Skia, Hermes, Swift toolchain, React Native, Vulkan, or compositor
workflow logic.

**Component ownership.** The package that owns an artifact owns the actions and
task declarations that produce it. Adding a component requires one recipe in that
component's package and one entry in the command-layer component list. It never
requires a kernel change.

**One action seam.** Domain actions depend on `ColliderCore` only. Every
observable effect flows through a core-owned `ActionContext`. `ColliderRuntime`
implements that context without exposing runtime actors or runtime utility types
to recipe packages.

**Declared execution.** Host and container execution are alternative execution
environments. Kernel, device, privilege, and GPU requirements are orthogonal
hardware requirements. A task may therefore require both a containerized package
environment and host hardware.

**Declared identity.** A task identity covers its action kind and payload,
dependencies, declared inputs, execution environment, hardware contract, and
execution policy. Equality means equivalence with respect to those declared
inputs. It does not claim that undeclared machine state is equivalent.

**One compatible compilation.** A Swift module is compiled once for one complete
build context: configuration, target triple, toolchain identity, sanitizer,
traits, and compiler settings. Incompatible build contexts never share a SwiftPM
scratch path.

**Safe concurrency.** The scheduler launches a task only when its dependencies
are complete and all declared resources are available. In-process resource
admission prevents contention; filesystem locks preserve exclusion across
concurrent Collider processes.

**Verified restoration.** Portable cache entries contain content digests and
materialization metadata for every declared output. Existence or non-emptiness
alone never establishes cache integrity.

## Current State

### The kernel enumerates its clients

`TaskOperation` in `collider/engine/Sources/ColliderCore/TaskGraph.swift` declares
44 cases. Fifteen are generic filesystem or process primitives. The other 29
name specific consumers such as AOSP product compilation, Chromium source
preparation, Android SDK assembly, browser installation, and host toolchain
validation.

That inversion creates four structural problems.

**The runtime is a domain namespace.** `ColliderRuntime` carries roughly 10,000
lines of extensions across the AOSP, Chromium, Android SDK, and host toolchain
workflows. The operation switch dispatches every case back onto the same actor,
so unrelated workflows share one isolation domain and one mutable state bag.

**Execution is serial within one run.** `TaskEngine.execute` walks topological
order in a plain loop. Actor reentrancy could overlap some awaited work, but
synchronous workflow work would remain serialized on the actor. The loop and the
shared actor must both disappear before scheduling is genuinely concurrent.

**The digest tag space is global.** `encode(operation:into:)` allocates canonical
tags from one flat integer space. Domain additions require editing the kernel,
and an accidental reuse can silently alias two payload fields.

**Recipe and component APIs drift.** Recipe packages expose unrelated sets of
static methods with incompatible signatures. `ComponentRegistry` hand-assembles
them, while `ComponentID`, `ComponentSelection`, `WorkspaceComponent`, and
`WorkspaceLayout` repeat component identity and paths.

The existing file locks are still meaningful: they protect shared checkouts and
state from concurrent Collider processes. They are underused by the serial
in-process executor, not vestigial.

### Build capacity is consumed by duplicated work

The workspace occupies roughly 492 GB across the checkout and Nucleus caches.
`android-runtime/` accounts for roughly 325 GB through its AOSP source and build
trees.

Each package currently invokes `swift build` from its own root without a shared
scratch path. Shared first-party modules are consequently compiled into several
package-local `.build` trees. SwiftPM build directories occupy roughly 58 GB.

The AOSP ccache uses `CCACHE_COMPILERCHECK=content` and reaches direct mode. The
host ccache used by Skia, gfxstream, the React Native C++ stack, and the
toolchain resolves most hits through preprocessed mode and treats most calls as
uncacheable. Per-package absolute build paths contribute to that result.

Retention exists for Chromium generations and installations but not for AOSP
product generations or sanitizer scratch trees. `.aosp-source/out` appears to be
a default-`OUT_DIR` tree outside the declared AOSP product flow. Podman also has
inactive images, and the Swift source checkout lacks the partial-clone filtering
used by the AOSP sync.

### Identity data is not a proof of machine equivalence

Collider hashes declared files, trees, environment inputs, dependency
identities, and resolved host executables. This is valuable diagnostic data, but
it covers declared inputs only. It does not automatically cover dynamically
loaded libraries, undeclared environment state, kernel and driver behavior,
network responses, locale, time, or package data surrounding an executable.

Container execution adds a digest-pinned package environment. Hardware lanes
still observe the real kernel, privileges, devices, and drivers. The run
manifest must report both kinds of declared state without claiming that either
one proves complete environmental equivalence.

## Phase 1 — Establish compatible Swift build contexts and reclaim capacity

This phase lands first because later full replays need storage headroom and a
stable definition of which Swift builds may share artifacts.

### Define the build-context key

`ColliderCore` gains a `SwiftBuildContext` value containing every axis that can
change module compatibility:

- build configuration;
- target triple;
- installed toolchain identity;
- sanitizer;
- SwiftPM traits;
- effective Swift, C, and C++ compiler settings.

`WorkspaceLayout` maps that value to one scratch path under the workspace state
directory. Build, test, sanitizer, installation, and Android framework tasks use
the same accessor. No task constructs a scratch path directly.

Before migrating all tasks, representative root packages alternate sequential
builds against the same compatible scratch path. The proof records SwiftPM graph
planning and compilation output and establishes that:

- shared modules are reused across roots;
- returning to an earlier root remains warm;
- incompatible context keys do not reuse module artifacts;
- SwiftPM root-package metadata remains valid across the alternation.

The consolidated layout lands only after this proof passes.

Every task that currently declares `root/.build` as an output follows the new
scratch path. Compatible tasks declare the scratch path as a shared resource so
the later scheduler can serialize SwiftPM mutations intentionally.

### Configure host native caching

Host native builds use the workspace as `CCACHE_BASEDIR`,
`CCACHE_COMPILERCHECK=content`, and an explicit reviewed set of
`CCACHE_SLOPPINESS` values. Each sloppiness setting documents the input it
ignores and why that input cannot affect the produced artifact. The host cache
limit becomes 50 GB.

The configuration lands after scratch consolidation so its measured direct-mode
rate reflects the final path layout.

### Bound retained generations

`DirectoryRetentionPlan` covers:

- AOSP `staged`, `signed`, `unsigned`, and `images` generations;
- address, undefined, and thread sanitizer scratch generations;
- container images owned by Collider execution sessions.

Retention runs only against explicit generation roots. It never targets a
workspace root, package root, or unresolved path.

### Reclaim confirmed orphaned state

A full AOSP product build records every access to the effective output roots.
`.aosp-source/out` is removed only after the trace proves that no declared stage
reads or writes it. Inactive Podman images are pruned by exact image identity.
The Swift source checkout adopts partial clone, blob filtering, no-tag fetches,
and current-branch fetch behavior appropriate to its pinned revision flow.

### Verification gate

For every migrated Swift build context:

1. The first run after output relocation executes the affected tasks.
2. The immediately following run is fully clean.
3. Alternating representative package roots remains warm.
4. Incompatible contexts occupy different scratch paths.
5. SwiftPM storage drops to one copy per compatible build context.
6. Host ccache direct-mode and cacheable-call rates improve without changing
   produced artifacts.

## Phase 2 — Introduce the action, capability, and identity contracts

This phase replaces the closed operation enum and deliberately starts a new task
identity schema. Old task state is not interpreted under the new schema.

### Put every public contract in `ColliderCore`

`ColliderCore` owns:

```swift
public protocol TaskAction: Sendable {
    static var kind: ActionKind { get }
    var toolRequirements: [ToolRequirement] { get }

    func encode(into encoder: inout ActionDigestEncoder)
    func run(in context: ActionContext) async throws
}
```

`ActionKind` is a stable component-qualified string such as
`"aosp.compile-product"` or `"toolchain.assemble"`. `TaskGraph` records the
concrete action type associated with every kind and rejects a graph in which two
different types claim the same kind.

`ActionDigestEncoder` writes the identity schema version and action kind once,
then encodes action-local fields. Local numeric tags do not share a registry
with other action types. Repeated fields have explicit ordered or unordered
encoding methods so collection ordering is intentional.

`TaskDeclaration` stores `any TaskAction` and no longer conforms to `Hashable`.
Task collections key on `TaskID`, and `TaskGraph` continues to reject duplicate
identifiers explicitly.

### Make `ActionContext` a core-owned capability facade

`RuntimeCancellation` and runtime execution options do not cross the package
boundary. `ColliderCore` instead owns `CancellationToken`,
`TaskExecutionOptions`, and the public capability facade:

```swift
public struct ActionContext: Sendable {
    public let stage: TaskID
    public let outputs: [OutputDeclaration]
    public let options: TaskExecutionOptions
    public let cancellation: CancellationToken

    public func execute(_ command: CommandSpec) async throws -> CommandResult
    public func download(_ specification: DownloadSpec, to path: FilePath) async throws
    public func inspect(_ path: FilePath) async throws -> FileMetadata?
    public func list(_ path: FilePath) async throws -> [DirectoryEntry]
    public func read(_ path: FilePath) async throws -> [UInt8]
    public func write(_ bytes: [UInt8], atomicallyTo path: FilePath) async throws
    public func copy(from source: FilePath, to destination: FilePath) async throws
    public func remove(_ path: FilePath) async throws
    public func log(_ bytes: [UInt8]) async throws
}
```

The exact filesystem surface follows the needs found while moving workflows, but
every addition is generic and domain-neutral. Domain actions do not import
`ColliderRuntime` or reach for `DurableFile`, `GenerationPublisher`,
`DirectoryLifecycle`, runtime actors, or runtime error types.

Arbitrary nested `context.perform(action)` is not part of the seam. It would
create an undeclared action graph whose tools and payload could escape the parent
identity. Composite actions encode their complete configuration and call generic
context capabilities. A kernel-owned `SequenceAction`, when needed as a
top-level declaration, encodes every nested action kind and payload before
running them.

### Declare tools in their actual resolution environments

`ToolRequirement` couples an executable with the environment used to resolve it.
An action containing commands with different `PATH` values declares separate
requirements. Identity resolution never relies on one action-wide
`toolEnvironment`.

The execution session resolves requirements. Host sessions record the resolved
path and binary digest. Container sessions record the image digest and resolve
the executable inside that image. The task identity includes the container image
digest because the executable's surrounding libraries and package data are part
of that declared environment.

### Start identity schema version 2

Schema version 2 includes:

- task ID and component ID;
- execution policy;
- ordered dependency identities;
- declared inputs;
- named output contracts;
- action kind and action-local payload;
- execution environment;
- hardware requirements.

State records live under the version-2 state namespace. Version-1 records never
validate version-2 tasks and are removed through bounded state retention after
the migration. There is no dual encoder and no compatibility path.

Tests establish:

- identical declarations produce identical bytes;
- changing every identity-bearing field changes the digest;
- collection ordering follows its declared semantics;
- two concrete action types cannot claim one kind;
- malformed or duplicate action fields fail during encoding where applicable.

### Verification gate

All kernel primitive actions execute through `ActionContext`. Identity tests
cover every primitive. The first version-2 run rebuilds affected tasks, and the
second run is fully clean with stable version-2 identities.

## Phase 3 — Move workflows into their owning packages

With execution on `TaskAction`, domain workflows leave `ColliderRuntime`.
Ownership follows the recipe that constructs the task.

| Destination | Actions |
|---|---|
| `swift-toolchain/Sources/SwiftPlatformColliderRecipe` | Swift source preparation, host toolchain preparation/assembly/validation, Android SDK assembly/wiring/validation, Android runtime linkage validation, link metadata sanitization |
| `android-runtime/Sources/AndroidRuntimeColliderRecipe` | AOSP source lock and preparation, build-container preparation, signing identity, product compile/sign/assemble/validate/publish, Android-specific Meson setup |
| `chromium/Sources/ChromiumColliderRecipe` | depot_tools and source preparation, Chromium product build, browser/CEF assembly and validation, browser installation, Chromium package validation |
| `core/Sources/CoreColliderRecipe` | Android host validation |

The associated implementation and behavioral tests move with each action.
Package resource bundles and fixtures move to the package that consumes them.
Domain-specific error types move with the workflow; generic execution,
validation, cancellation, and filesystem failures remain core/runtime errors.

`ColliderRuntime` retains only the implementations behind the core capability
facade:

- execution sessions and process I/O;
- downloads;
- cancellation implementation;
- cross-process file locks;
- run and log recording;
- durable filesystem operations;
- artifact hashing and state persistence.

The runtime is no longer a domain namespace or the isolation domain for action
bodies. Recipe targets depend on `ColliderCore` only.

### Verification gate

`collider test all` passes. Representative AOSP, Chromium, Swift toolchain, and
core actions produce the same outputs as their pre-move implementations. After
one version-2 execution, each representative selection replays to a fully clean
plan. Package tests assert behavior and runtime contracts, not source
declaration shape.

## Phase 4 — Unify component declarations and CLI identity

`ColliderCore` gains:

```swift
public protocol ColliderComponent: Sendable {
    static var id: ComponentID { get }
    static var directoryName: String { get }
    static var selectionNames: [String] { get }
    static func tasks(in context: RecipeContext) throws -> [TaskDeclaration]
}
```

The first selection name is canonical; the remaining names are stable CLI
aliases. `rn`, `android-runtime`, `gpu-headless`, `gpu-drm`, and every other
currently accepted spelling remain accepted through explicit metadata.

`RecipeContext` carries the resolved component root, repository root, declared
task environment, and build-context scratch resolver. Recipe construction is
pure: it does not probe the filesystem, resolve tools, or execute commands.

`TaskDeclaration` gains a facet:

```swift
public enum TaskFacet: Hashable, Sendable {
    case build
    case test(lane: String?)
    case bootstrap
    case generate
    case install
    case qualify(lane: String?)
}
```

Every component returns its complete declaration set from one method. Command
selection filters the flattened declarations by component, facet, and lane.

The command layer contains one `[any ColliderComponent.Type]` list.
`ComponentSelection` becomes a registry-backed argument value rather than a
hand-maintained enum. Registry validation rejects duplicate component IDs,
directory names, canonical names, aliases, task IDs, and action-kind ownership.

`WorkspaceComponent` is deleted. `WorkspaceLayout` resolves component paths
through `directory(for:)`; only non-component state paths retain dedicated
accessors.

### Verification gate

Every previously accepted component and lane spelling parses to the same
selection behavior. A frozen table exercises the public CLI spellings.
Flattening all recipes produces one valid graph with no duplicate identities or
aliases.

## Phase 5 — Add action-scoped execution environments and hardware contracts

Execution location and hardware requirements are separate declaration fields:

```swift
public enum ExecutionEnvironment: Hashable, Sendable {
    case host
    case container(ContainerImage)
}

public struct HardwareContract: Hashable, Sendable {
    public let requirements: Set<HardwareRequirement>
}
```

Tasks that depend on a distribution package set use a digest-pinned container.
Tasks that consume only declared toolchain and native SDK artifacts run on the
host. DRM nodes, Vulkan capability, binderfs, mount delegation, BPF delegation,
and other real-machine requirements appear in `HardwareContract` regardless of
execution environment.

### Create one execution session per task

The kernel creates an execution session before resolving tools or running the
action. The session owns:

- environment and executable resolution;
- host-to-container path mapping;
- the container image identity;
- declared mounts;
- command execution;
- cancellation;
- filesystem capabilities exposed through `ActionContext`;
- event and log attribution.

Container sessions mount declared workspace, state, cache, and output roots at
stable absolute paths. Action code observes the same logical paths through the
context in host and container environments. Undeclared host paths are not
mounted.

All commands for one action use the same declared container environment and
mount set. Tool identities are resolved inside that environment. The container
image digest, declared mounts, and command environment participate in task
identity.

### Assign environments

The following producers use container execution because distribution package
state affects their results:

- AOSP;
- Chromium;
- Skia;
- the React Native C++ stack;
- the Swift toolchain.

Swift package builds and tests remain host tasks because they consume the
declared installed toolchain and content-addressed native SDK. Their complete
`SwiftBuildContext` remains part of identity.

GPU DRM, GPU headless, Android presentation, Android framework boot, binderfs,
APEX mount, and BPF delegation lanes declare their exact hardware requirements.
An unmet requirement fails before action execution with the requirement name and
probe result. It never silently skips.

### Verification gate

A representative task in each environment records the tools and environment it
actually used. Container tasks resolve tools inside the pinned image and cannot
read undeclared host paths. Hardware tasks fail before execution when a declared
capability is absent. Repeated executions in the same declared environment
produce stable identities and pass their artifact-specific behavioral
validation.

## Phase 6 — Add a resource-aware ready-queue scheduler

The identity and assessment pass remains deterministic and complete before
execution begins. The execution pass becomes a bounded ready queue rather than a
serial loop or dependency-level barrier.

A task is ready when:

- every dependency succeeded or was already clean;
- its declared in-process resources are available;
- its execution slot fits the `--jobs` limit;
- no running task owns an overlapping output.

Resources include checkout mutation, shared SwiftPM scratch paths, publication
roots, and other explicit `TaskLock` values. The scheduler reserves all resources
atomically in canonical order before launching a task and releases them when the
task completes. Tasks never block executor threads waiting for an in-process
resource.

After admission, the task acquires the existing filesystem locks for the same
resources. These locks remain necessary for exclusion against other Collider
processes. Lock acquisition is cancellation-aware and reports its current
owner.

### Validate output ownership

Graph construction canonicalizes declared output paths without following a
mutable final symlink. It rejects:

- identical output paths owned by unrelated tasks;
- parent/child output overlap without an explicit dependency and ownership
  transfer;
- an output nested under another task's mutable publication root;
- undeclared shared scratch mutation.

Publication actions retain explicit ownership-transfer semantics rather than
depending on path coincidence.

### Make reporting deterministic

Per-task events and log bytes preserve task-local order. Cross-task event order
records actual concurrency. The final execution report presents task results in
stable graph order while retaining start/end timestamps for concurrency
analysis.

The tool identity cache becomes an immutable snapshot produced during planning.
Execution does not mutate planner state.

On failure, the scheduler cancels pending work, propagates cancellation into
running execution sessions, waits for their cleanup, releases resources, and
then reports the original failure.

### Verification gate

A cold `collider build all --jobs 1` and a cold concurrent run execute the same
task set and produce artifact-equivalent outputs. Repeated concurrent runs show
stable final reports, no overlapping output mutation, no leaked execution
sessions, and no lock-order deadlocks. A dependency chain advances as soon as
its own predecessor completes; it does not wait for unrelated tasks at the same
graph depth.

## Phase 7 — Add audited portable caching and declared-input manifests

Incremental cleanliness and portable restoration are different contracts.
`TaskExecutionPolicy` expresses them directly:

```swift
public enum TaskExecutionPolicy: Hashable, Sendable {
    case always
    case incremental
    case portableCache
}
```

`always` executes on every run. `incremental` uses local state records and
declared outputs. `portableCache` additionally promises that:

- every observable input is declared;
- every produced output is declared;
- outputs are relocatable through named output slots;
- execution does not depend on unrecorded mutable state;
- materialization metadata is representable by the artifact store.

Existing content-addressed tasks become `incremental`. Each action moves to
`portableCache` only after an explicit behavioral audit.

### Store verified output snapshots

The artifact store maps task identity to a snapshot manifest. Every output entry
contains:

- its stable output-slot name;
- content digest or directory Merkle root;
- file type;
- permissions;
- symlink target where applicable;
- the archive/chunk identities needed for materialization.

Resolved host paths are placement, not portable output identity. Portable tasks
encode stable input and output names plus content, while their execution session
resolves those names to checkout/state paths.

Restoration writes into a temporary sibling, verifies the complete snapshot, and
atomically publishes it to the declared destination. A corrupt or incomplete
entry is quarantined and treated as a miss. The kernel never accepts a restored
artifact based only on `exists` or `nonEmptyDirectory`.

Nested and overlapping outputs are not independently cacheable. One owning task
stores the complete tree, or the graph separates them into disjoint output
slots.

### Emit declared-input run manifests

`RunRegistry` records, for every task:

- identity schema version and task identity;
- dependency identities;
- declared file, tree, value, and environment inputs;
- resolved host tool paths and digests;
- container image digest and container-resolved tools;
- `SwiftBuildContext`;
- execution environment and mounts;
- hardware requirements and probe results;
- execution policy;
- output snapshot digests;
- cache hit, local clean, or executed status.

A manifest comparison reports the first declared difference and then the
remaining differences in stable task order. Equal manifests mean equality of
declared inputs and outputs, not proof that all machine state was identical.

### Verification gate

An audited portable task executes in one state root, restores into a second cold
state root, passes full digest verification, and is locally clean on the next
plan. Permission and symlink round trips are covered behaviorally. Corrupt
content is quarantined and rebuilt. Two equivalent runs produce identical
declared-input sections even when event timestamps differ.

## Risk Surface

**Identity schema.** Incorrect action encoding can silently validate stale work.
Schema version 2 intentionally invalidates old state, action kinds are checked
for unique ownership, and field-sensitivity tests cover every action.

**Scratch compatibility.** SwiftPM root graphs may not safely share a scratch
path even when compiler settings match. Phase 1 proves alternating-root reuse
before migration and keys every compatibility axis explicitly.

**Output relocation.** Moving scratch and publication paths without moving their
declarations makes tasks permanently dirty or hides produced artifacts. Every
relocation requires one rebuilding run followed by a clean replay.

**Orphan cleanup.** `.aosp-source/out` is removed only after traced product
execution proves it unused. Cleanup targets exact validated paths and image
identities.

**Capability completeness.** Workflow relocation will reveal runtime helpers
used directly by domain code. Each required effect becomes a generic
`ActionContext` capability before the caller moves. Domain-specific helpers do
not remain in the runtime.

**Container path and tool identity.** Resolving a tool on the host for a command
that runs in a container records the wrong input. Execution sessions resolve
tools, paths, mounts, and commands in one environment.

**CLI compatibility.** Component selection is a public interface. Canonical
names and aliases are explicit component metadata and are exercised through
argument parsing behavior.

**Concurrency.** Blocking file locks inside task-group children can exhaust
executor threads, and path overlap can corrupt plausible-looking outputs. The
ready queue performs resource admission before launch; filesystem locks remain a
cross-process backstop.

**Portable cache completeness.** Existing incremental tasks are not presumed
hermetic. Portable eligibility is explicit, output snapshots are
cryptographically verified, and restoration is atomic.

**Empty inward-facing modules.** Empty `NucleusAOSP*` target directories under
`collider/engine/Sources` do not become new kernel modules. They are removed or
their intended domain logic lands in `android-runtime` during phase 3.
