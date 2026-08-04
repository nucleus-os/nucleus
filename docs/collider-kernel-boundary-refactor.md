# Collider Kernel, Planning, and Execution Architecture

**Status: active.** This is the sole authority for Collider graph declaration,
planning, execution, persistence, caching, output ownership, input auditing,
target/host execution placement, and resource-aware scheduling.

## Invariants

**Collider remains a Nucleus build tool.** Collider is not a second package
resolver, a user-loaded build-script language, or a general replacement for
SwiftPM, Gradle, CMake, Ninja, or Bazel. It declares, coordinates, validates,
and records the build systems that produce Nucleus.

**The root Swift package is built once per compatible context.** Component
recipes declare logical Swift build and test requirements. Planning coalesces
all dirty requirements for one `SwiftBuildContext` into the minimum correct set
of stock root `swift build` and `swift test` invocations. A test invocation
subsumes the build invocation only when its package closure produces every
expected build output for that context. No component action launches its own
SwiftPM build.

**Every command executes through the plan.** A command selects entrypoints and
hands the selection to planning. No command shells a build system, test runner,
benchmark, or sanitizer harness directly. Benchmarks, sanitizer lanes, and
repository-wide test gates are component entrypoints with declared inputs,
identities, execution contracts, and run-log attribution. The only processes
Collider launches outside a planned action are the ones that produce the plan.

**Execution environment is declared, never inherited.** A task that produces or
exercises a Linux artifact declares a Linux execution contract and runs in the
pinned container image regardless of runner operating system. The host runner is
never an implicit substitute for the target. Planning rejects a host-executed
task whose Swift build context, artifact target, or machine requirement names a
non-host platform. There is no host fallback path.

**Tools are either semantic or operational.** A semantic tool can affect output
equivalence; its binary digest enters task identity, so it is resolved inside a
pinned execution environment or is a first-party artifact produced by another
task. An operational tool does not enter identity and is legal only when the
action validates a content-addressed result independently of that tool. Ambient
host tools are therefore limited to host-only source materialization whose
outputs are validated against exact revisions or content digests and which
declares no target artifact. An ambient tool is never silently treated as an
operational tool merely to make state portable.

**One environment name has one meaning.** A path exported to both host and
container execution resolves to the same logical level in both. The native SDK
root is always per-target; there is no untargeted level and no environment
variable whose interpretation depends on where it is read.

**Every published path has a producing task.** Every path a manifest, action, or
external build system reads from a Collider-owned publication root is a typed
output slot with exactly one producer. Symlink publication validates the link
target, not merely the link.

**The kernel never enumerates component workflows.** Adding or changing an
AOSP, Chromium, Swift target SDK, React Native, compositor, or other
component-owned workflow never changes the Collider kernel. The owning recipe
module owns its actions and declarations.

**Collider remains bootstrap-safe.** Recipe modules remain in the `collider`
package. The root runtime package does not depend on Collider's engine merely
to colocate build-tool source beside runtime source. Logical ownership is
expressed by recipe module ownership, action namespaces, and the root component
registry.

**One complete graph exists per component.** A component constructs one
immutable graph and publishes named entrypoints into it. Commands select
entrypoints and dependency closure; they never reconstruct component graphs.

**Planning is complete before execution.** Graph expansion, validation,
selection, tool resolution, input hashing, identity calculation, cleanliness
assessment, SwiftPM lowering, output ownership, and resource normalization
produce one immutable `ExecutionPlan`. Execution does not mutate graph or
identity state.

**Identity describes output equivalence, not scheduling or reuse policy.** Task
identity covers semantic inputs, semantic dependency identities, output slots,
action identity, and execution properties that can affect results. Ordering
edges, diagnostic metadata, declaration order, locks, concurrency limits,
incremental-versus-portable policy, and other scheduling or reuse data do not
cause rebuilds.

**Ordering and semantic dependencies are distinct.** An ordering edge constrains
execution and contributes nothing to identity. An artifact or result reference
is a semantic dependency, derives the required execution edge, and contributes
the referenced producer output identity. A host materialization implementation
never contaminates target identity when the semantic output is independently
content-verified.

**Identity migration is one hard break after the declaration model stabilizes.**
Collider has one canonical identity encoding and one state layout. Actions,
typed artifacts, semantic edges, scoped effects, and execution contracts land
before the replacement encoding becomes active. The migration then deletes the
exact legacy task-state and cache roots once. Collider carries no schema number,
version namespace, compatibility decoder, or dual identity encoder. A future
incompatible identity or persisted-state change performs the same explicit
derived-state reset.

**Artifact identity is independent of placement.** Recipes exchange typed
producer/output-slot references. Absolute host paths, container paths, and
generation destinations are resolved during planning and execution and never
become portable artifact identity.

**Every effect crosses a narrow capability seam.** Component actions depend on
`ColliderCore` contracts only. They do not import runtime actors, persistence
stores, lock managers, process implementations, or nested action dispatch.
Large build systems receive explicitly scoped tree capabilities rather than an
unrestricted filesystem object.

**Exhaustiveness is the compiler's job.** No switch over a closed Collider enum
carries a `default:` clause. Adding a case is a compile error at every site that
must handle it, not a silent fallthrough to an empty environment, a lightweight
resource claim, or a skipped validation.

**The declaration layer speaks one path type.** `FilePath` is the path type of
declarations, recipes, workspace layout, and the engine API. `URL` appears only
at the call site of a Foundation API that requires it.

**Concurrency is resource-aware.** A task launches only after its dependencies
complete and all weighted capacities, exclusive resources, output ownership,
machine requirements, and cross-process locks are satisfied. A single root
SwiftPM invocation may reserve most execution capacity; concurrency never
means blindly running multiple build systems against one scratch database.

**Incrementality and portability are separate promises.** Incremental tasks may
reuse validated local outputs. Portable tasks additionally provide complete,
relocatable, content-verified snapshots. No task becomes portable merely
because its identity is content-addressed.


## Current Foundation

The production repository already has the foundations this plan preserves:

- the repository root owns one first-party SwiftPM graph;
- Collider synthesizes stock root Swift invocations per compatible context,
  and `subsumedDependencies` already implements the current test-over-build
  subsumption behavior;
- `SwiftBuildContext` separates incompatible toolchain, target, sanitizer,
  trait, flag, and standard-library configurations, and `SwiftPMExecution`
  already distinguishes host from OCI execution;
- recipe targets live under `collider/Sources`;
- `TaskGraph` validates dependencies and returns deterministic topological
  order;
- declared inputs, outputs, postconditions, task locks, state records, run
  records, and artifact digests already exist;
- cross-process file locks already protect shared mutable state;
- `ExecutionPlatform`, `RunnerPlatform`, `ArtifactTarget`, and
  `OCIExecutorResolver` already model where a task runs and what it produces;
- `RunRegistry` already records planning duration and per-stage run logs.

Two capabilities the earlier revision of this plan proposed to create already
exist in production and are completed rather than introduced:

- **The action seam exists but has one consumer.** `ColliderAction`,
  `ColliderActionIdentity`, `AnyColliderAction`, `ActionContext`,
  `ActionFileSystem`, and `CanonicalDigestEncoder` are implemented in
  `ColliderCore`. `TaskOperation.action` is their only call site. The
  outstanding work is completing the contract and converting the remaining
  thirty-four operation cases, not designing the seam.
- **The concurrent scheduler exists but is under-declared.** `TaskEngine`
  already runs a bounded ready queue over `withThrowingTaskGroup` with weighted
  CPU and memory admission, exclusive claims, and lock-disjointness checks. The
  outstanding work is output-tree ownership reservation, atomic canonical-order
  claim reservation, per-task-class resource declarations, and critical-path
  measurement, not replacing serial execution.

The remaining architectural debt is concentrated in seven places:

1. `TaskOperation` is a closed enum containing generic and domain-specific
   behavior, dispatched through eight parallel switches and a hand-allocated
   digest tag space.
2. `ColliderRuntime` is both the execution implementation and a namespace for
   AOSP, Chromium, Android SDK, browser, and Swift target SDK workflows.
3. `ComponentRegistry` reconstructs different task arrays for each command,
   owns component-specific selection behavior, and carries unreachable
   selection branches.
4. planning, state assessment, synthesized SwiftPM execution, and execution
   admission remain coupled inside `TaskEngine`.
5. several commands bypass the graph entirely and drive host SwiftPM against
   Linux-only targets.
6. host tools shape target artifacts and enter target task identity.
7. the command layer carries duplicated path resolution, two path types, and
   string-keyed task identifiers.

## Verified Defects

These are confirmed by source reading and, where noted, by inspecting the
provisioned SDK cache. Each is assigned to the phase that repairs it.

### Host and target placement

**The repository-wide test gates run on the host.** `ColliderCommand.Test`
invokes `Orchestrator.runRepositoryWideTestGates()` whenever the component is
unset or `all` and the run is not a dry run, with no platform guard.
`Orchestrator.testReleaseSuite` takes a host `swiftPMInvocation` and shells
`swift test --filter` six times through `context.run`. Three of the six suites
cannot build on macOS: `NucleusFoundationPublicationStressTests` lives in
`NucleusUITests`, whose linker settings use GNU `--start-group`/`--end-group`
and `-lvulkan`; `NucleusPlatformTransportStressTests` and
`NucleusCompositorTransitionStressTests` are Wayland and Linux-platform suites.
Repaired in phase 2, absorbed into entrypoints in phase 4.

**`collider benchmark` builds Linux products on the host.** `BenchmarkCommand`
takes a host release `swiftPMInvocation` and builds `NucleusLinuxBenchmarks`,
which depends on `NucleusLinuxReactorC`, `NucleusLinuxDBus`, and
`NucleusLinuxSessionC`. The defect is host placement, not the availability of
the command spelling. Repaired in phase 2, absorbed into entrypoints in phase 4.

**`collider sanitize` builds and executes Linux harnesses on the host.**
`SanitizerCommand.run` takes a host sanitizer `swiftPMInvocation`, runs
`swift test` or `swift build`, then executes the produced binary directly. Its
invocation table spans `platform-linux`, `compositor`, `android-runtime`, and
`integration-tests/window-client-conformance`. Its own source comment states
the Linux-host assumption. Repaired in phase 2, absorbed into entrypoints in
phase 4.

**`wayland.generate` uses an unpinned host scanner.** The task declares
`.tool(.named("wayland-scanner"))` and emits `executable: .named(...)`, a host
`PATH` lookup, while `wayland.native-sdk.linux-arm64` builds a pinned scanner
into the native SDK and mounts it for the x86_64 cross build. The task's outputs
are committed source: `Sources/WaylandServerC`, `Sources/WaylandClientC`, and
`protocol-runtime/Sources/WaylandProtocolsC`. `WorkspaceDoctor` does not list
`wayland-scanner` as a prerequisite, so `collider doctor` passes on a machine
where the task cannot run. Repaired in phase 2.

**The native SDK root means two different levels.** `tools/host-env.sh` and
`collider-setup.sh` export `NUCLEUS_NATIVE_SDK_ROOT` as the untargeted parent,
and `WorkspaceContext.init` defaults it the same way, while the container mounts
built by `ComponentRegistry.linuxArchitectureTasks` export it as
`<root>/<target>`. The root manifest reads `$NUCLEUS_NATIVE_SDK_ROOT/render/...`
and therefore resolves to a different tree depending on where it is evaluated.
Repaired in phase 2.

**The host render SDK slot points at an orphan.** `publishRenderSDK` symlinks
`<root>/render/lib/skia-graphite` to `core/.skia-build/graphite`. No task in any
recipe builds `.skia-build/graphite`; the only Skia producers write
`.skia-build/linux-arm64`, `.skia-build/linux-x86_64`, and
`.skia-build/android-arm64`. On the provisioned cache the `graphite` directory
is a stale host build predating the target split, and the sibling
`skia-graphite-android-arm64` link is dangling because its target does not
exist. The task's default dependency `core.skia.host` names a task ID no recipe
declares, and survives only because every call site overrides it. Repaired in
phase 2, made structurally impossible in phase 5.

**Dangling symlinks satisfy output validation.** `PathValidation.exists` is
implemented as `stat(followTargetSymlink: false)`, so `lstat` succeeds on a
broken link and the publishing task reports success. Repaired in phase 1.

**Host tool digests enter target task identity.** `core.sources` declares
`.tool` inputs for `git`, `python3`, `unzip`, and `chmod`; `rn.generate`
declares `node`; `rn.javascript-dependencies` declares `corepack`. A macOS point
release that touches `/usr/bin/chmod` re-runs Skia dependency sync, and no task
state is shareable between a macOS and a Linux runner. The `unzip` and `chmod`
steps carry no semantic content: the extracted `gn` is a Linux ELF used only
inside the container. `corepack yarn install` additionally resolves
platform-gated optional dependencies by runner platform, so
`third-party/react-native/node_modules` is host-shaped. Repaired in phase 2.

### Declaration surface

**Five switches over `TaskOperation` carry `default:` clauses.**
`scheduledResources`, `containsOCIExecution`, `validateArtifactOutputs`,
`operationEnvironment`, and `executionCoordinates` each enumerate nearly every
case and then swallow the rest. `operationEnvironment` is the dangerous one: its
result resolves `.tool` inputs during identity calculation, so a new operation
carrying an environment and declaring tool inputs resolves those tools against
the process `PATH` and records a digest for the wrong binary. Repaired in
phase 1.

**Six recipe modules carry the same private task helper.** `CoreColliderRecipe`,
`VulkanColliderRecipe`, `WaylandColliderRecipe`, `ReactNativeColliderRecipe`,
`CompositorAppColliderRecipe`, and `CompositorColliderRecipe` each define a
structurally identical `task`/`packageTask` differing only in component ID,
package name, product list, source tree names, and lock. They have already
drifted in signature — positional versus labeled `swiftPM`, required versus
defaulted dependencies, three positions for `subsumedDependencies` — and each
branches on `let isBuild = arguments == ["build"]`, keying behavior to a string
comparison against a magic argument array. Repaired in phase 4, homed in
`ColliderSwiftPM` in phase 6.

**`WorkspaceLayout` vends `URL` into a `FilePath` API.** Every layout property
returns `URL`, and consumers immediately reconstruct `FilePath` from `.path` —
fifty-seven times in `ComponentRegistry` alone, one hundred thirty-two across
the package. Repaired in phase 3.

**Path resolution is implemented more than once.** `WorkspaceContext.init` and
`WorkspaceContext.cacheRoot` independently implement the
`XDG_CACHE_HOME`/`HOME`/`.cache` fallback. `nativeSDKRoot` exists three times,
in `CommandSupport`, `ComponentRegistry`, and `WorkspaceDoctor`, one of which
force-unwraps the environment value. `resolve(_:relativeTo:)` is defined twice
in `ColliderCommand.swift` with identical bodies. Repaired in phase 3.

**Task identifiers are strings.** One hundred eighty-one
`TaskID(rawValue: "…")` literal sites cover ninety-seven distinct identifiers.
The command layer derives them by concatenation and by a dictionary of string
arrays; recipes cross-reference each other by literal. A typo compiles and fails
at graph validation. Repaired in phase 3 for recipe-to-recipe references and in
phase 4 for command-to-recipe selection.

**Selection carries unreachable branches.** In `selectedBuildTasks`, every
selection not in `runtimeLinuxSelections` is rejected by the following guard, so
the final `selection.rawValue + ".build"` return is dead. In
`selectedTestTasks`, `runtimeLinuxSelections` is tested first, so the
`taskNames` entries for `tracy`, `vulkan`, `wayland`, `core`, `config`, `ipc`,
`linux`, `rn`, `compositor`, `shell`, and `android-runtime` are unreachable —
only `loader`, `gpu-headless`, and `gpu-drm` resolve through it. The host-context
per-component build and test tasks these branches appear to select are
constructed on every planning pass and never selected. Repaired in phase 3.

**The command layer has two catch-all files.** `WorkspaceContext`, workspace
root discovery, three global mutable slots, and `WorkspaceFileLock` share
`ProcessRunner.swift`. `TaskControls`, plan rendering, language-server
publication, `swiftPMInvocation`, compiler discovery, and directory pruning
share `CommandSupport.swift`. `ColliderCommand.swift` holds roughly thirty-five
command types. Repaired in phase 3.

**`RunOptions` maintains specified-ness by hand.** `Run` declares eighteen
parsed properties and copies each into `RunOptions`, hand-setting
`outputOptionWasSpecified` and `tracyOnlyOptionWasSpecified`. Repaired in
phase 3.

**The engine package has no tests.** `ColliderCoreTests` is declared by the
outer `collider` manifest with `path: "engine/Tests/ColliderCoreTests"`, and
`engine/Package.swift` declares no test target, so the engine cannot be verified
as an independent boundary. Repaired in phase 3.

## Target Package Graph

The final engine package exposes its products with one-way dependencies:

```text
ColliderPlanning ─────────────→ ColliderCore
ColliderPersistence ──────────→ ColliderCore
ColliderDownloads ────────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderPersistence
ColliderRuntime ──────────────→ ColliderDownloads
ColliderEngine ───────────────→ ColliderCore
ColliderEngine ───────────────→ ColliderPlanning
ColliderEngine ───────────────→ ColliderPersistence
ColliderEngine ───────────────→ ColliderRuntime
ColliderTesting ──────────────→ ColliderCore
ColliderTesting ──────────────→ ColliderPlanning
```

`ColliderPlatformC` remains a leaf C target consumed by `ColliderDownloads` and
`ColliderRuntime`.

`ColliderSwiftPM` lives in the outer `collider` package and depends on
`ColliderCore` and `ColliderPlanning`. Recipe modules that declare Swift
requirements depend on `ColliderSwiftPM`. The root command layer explicitly
installs its lowering into the planner.

### `ColliderCore`

`ColliderCore` is pure declaration and capability API. It owns:

- task, component, entrypoint, action, resource, and output identifiers;
- canonical identity encoding contracts, but no hashing implementation;
- typed artifact and declared-path references;
- task declarations and component definitions;
- action type erasure;
- execution and machine requirement declarations;
- resource requests;
- action context and effect protocols;
- command declarations;
- planner service protocols and immutable service inputs;
- immutable execution-plan and attribution value types;
- diagnostics and source locations.

It does not own:

- subprocess implementation;
- downloads;
- filesystem mutation;
- cryptographic hashing implementation;
- state stores;
- locks;
- runtime actors;
- command-line parsing;
- domain workflows.

### `ColliderPlanning`

`ColliderPlanning` is deterministic and side-effect free except through
explicit read-only planning services. It owns:

- component expansion and indexing;
- entrypoint selection and dependency closure;
- graph and action-kind validation;
- artifact-edge derivation;
- output ownership analysis;
- execution-contract validation, including host/target placement rejection;
- resource normalization;
- selected-input digest requests;
- tool snapshot requests;
- task identity construction;
- local-state assessment against immutable snapshots;
- deterministic plan lowering;
- immutable `ExecutionPlan` creation.

Planning services return values. They do not expose mutable persistence or
runtime actors.

### `ColliderPersistence`

`ColliderPersistence` implements durable data services:

- local task state;
- artifact and tree hashing;
- persistent file metadata/digest indexes;
- tool identity snapshots;
- action-result records;
- run manifests and event storage;
- portable artifact manifests and storage;
- atomic file replacement;
- bounded retention of artifacts and generations.

The public protocols consumed by planning and execution remain in
`ColliderCore`. This target supplies production implementations.

### `ColliderRuntime`

`ColliderRuntime` executes immutable plans. It owns:

- the ready-queue scheduler;
- host and container execution sessions;
- process lifecycle and process-group cancellation;
- terminal and log I/O;
- scoped filesystem capability implementations;
- hardware, kernel, privilege, and device probes;
- in-process resource admission;
- cross-process lock acquisition;
- plan event recording;
- state publication after successful action completion.

It contains no AOSP, Chromium, Android SDK, browser, Swift target SDK, React
Native, Vulkan, Wayland, compositor, or shell workflow type.

It does not import `ColliderPlanning`. The immutable plan contract lives in
`ColliderCore`; planning produces it and runtime consumes it.

### `ColliderEngine`

`ColliderEngine` is the production composition root. It owns only the thin
snapshot-to-plan-to-execute coordinator and production service wiring. It has no
declaration vocabulary, planning algorithm, persistence implementation,
scheduler implementation, command parsing, or component workflow.

### `ColliderTesting`

`ColliderTesting` provides:

- recording action contexts and process executors;
- deterministic identity fixtures;
- in-memory state and event stores;
- temporary-directory filesystem harnesses;
- planner service fixtures;
- graph and entrypoint assertions;
- scheduler admission and cancellation harnesses;
- component contract suites.

Filesystem behavior tests use real temporary filesystems. A fake filesystem is
used only for tests that intentionally do not depend on POSIX semantics.

## Core Authoring Model

### Actions

An action describes behavior and semantic identity. Task policy describes when
and where that behavior may run.

```swift
public protocol ColliderAction: Sendable {
    associatedtype Identity: ActionIdentity = EmptyActionIdentity

    static var kind: ActionKind { get }

    var identity: Identity { get }
    var requirements: ActionRequirements { get }

    func execute(in context: ActionContext) async throws
}
```

`ActionRequirements` is the sole declaration of tools and effect scopes
intrinsic to the action. Tools are classified as semantic or operational. The
task supplies placement, machine, privilege, network, reuse-policy, and
scheduling requirements; it never mirrors action requirements. Planning
combines the two declarations into the resolved execution contract.

`AnyColliderAction` is a concrete sendable box. It stores:

- stable `ActionKind`;
- canonical identity encoding closure;
- immutable action requirements;
- execution closure;
- runtime concrete-type identity used only for duplicate-kind diagnostics;
- diagnostic description and source location excluded from persistent identity.

Persistent identity never uses a Swift mangled type name, reflection result, or
process-dependent object identifier.

The graph rejects:

- one action kind claimed by multiple concrete action types;
- an action kind outside its component's declared namespace;
- an operational ambient tool without an independently content-verified output;
- an executable action left unhandled by a required planning lowering.

Actions never invoke other actions dynamically. Composition exists only in the
declared graph. There is no sequence action, nested dispatch capability, or
hidden runtime graph.

### Action identity

```swift
public protocol ActionIdentity: Sendable {
    func encode(into encoder: inout ActionIdentityEncoder)
}
```

The one canonical encoder:

- uses action-local positive numeric field tags;
- rejects duplicate and zero tags;
- distinguishes scalar, optional, ordered repeated, sorted repeated, and nested
  values;
- normalizes strings and integer widths;
- never depends on dictionary or set iteration order;
- emits canonical bytes without choosing a hash algorithm.

Tags are action-local. There is no global tag space and no hand-maintained
allocation table shared across unrelated payloads.

Task identity contains:

1. task ID and component ID;
2. semantic dependency identities keyed and sorted by dependency `TaskID` and
   output name;
3. named declared inputs in canonical order;
4. typed output-slot contracts;
5. execution properties that can affect results, including the resolved
   execution environment and artifact target;
6. action kind;
7. action-local identity bytes.

It excludes:

- task labels and source locations;
- entrypoint, facet, lane, and tag metadata;
- declaration order where order is not semantic;
- shared and exclusive scheduler claims;
- ordering-only dependencies;
- task execution and artifact-reuse policy;
- `--jobs` and scheduler capacity;
- log presentation settings;
- absolute resolved output paths for portable artifacts;
- the runner operating system, for any task whose execution environment is a
  pinned container.

If a resource changes output behavior, the task declares the semantic value as
an identity input in addition to its scheduling claim.

### Task declarations

```swift
public struct TaskDeclaration: Sendable {
    public let id: TaskID
    public let component: ComponentID
    public let after: Set<TaskID>
    public let inputs: [DeclaredInput]
    public let outputs: [AnyOutputSlot]
    public let resources: ResourceRequest
    public let execution: ExecutionContract
    public let policy: TaskExecutionPolicy
    public let metadata: TaskMetadata
    public let action: AnyColliderAction
}
```

`TaskDeclaration` does not conform to `Hashable`. Graph collections key by
`TaskID`, and duplicate IDs are explicit validation failures.

Declarations become immutable when `ComponentDefinition` is created. There is
no late `configure` API and no graph mutation after planning begins.

`after` contains ordering-only edges. Artifact and result inputs derive both a
semantic identity edge and an execution edge. A task that semantically consumes
another task without consuming a file uses a typed `TaskResultReference`; it
never overloads `after` to affect identity.

### Typed artifacts

Artifact identity and resolved placement are distinct:

```swift
public struct ArtifactReference<Value>: Hashable, Sendable {
    public let producer: TaskID
    public let output: OutputName
}

public struct ResolvedArtifact<Value>: Sendable {
    public let reference: ArtifactReference<Value>
    public let hostPath: FilePath
    public let executionPath: FilePath
}
```

Marker types include:

- `FileArtifact`;
- `DirectoryArtifact`;
- `ExecutableArtifact`;
- `JSONArtifact`;
- `StaticArchiveArtifact`;
- `OpaqueTreeArtifact`.

An output slot declares its marker, stable name, validation contract, and
placement rule. Its planned output identity is the producer task identity plus
the slot name and contract; this is available before execution and is distinct
from the content digest recorded after successful production. A consumer
accepting an `ArtifactReference` automatically gains:

- a dependency on its producer;
- a producer-output identity input;
- producer/output type validation;
- output ownership validation;
- host/container path resolution.

Raw source inputs remain explicit:

```swift
Input.file(path)
Input.tree(path)
Input.environment(name)
Input.value(name, bytes)
Input.tool(requirement)
```

Generated outputs may not re-enter the graph as unrelated raw paths. The
planner first warns during migration and then rejects this condition.

Artifact and result references have no public memberwise initializer. They are
created only by the task builder when an output or result slot is declared.
Consequently, a reference without a producer and slot is unrepresentable, while
an unknown producer introduced by decoding or internal corruption remains a
planner validation failure.

Output validation distinguishes a link from its target. `exists` means the path
resolves; a slot that publishes a symlink declares `symlinkTarget` with the
required target validation. No validation contract is satisfiable by a broken
link.

### Scoped filesystem capabilities

`ActionContext` exposes effects rather than implementation objects:

```swift
public struct ActionContext: Sendable {
    public let task: TaskID
    public let cancellation: CancellationToken
    public let options: TaskExecutionOptions
    public let files: FileSystemCapabilities
    public let logs: TaskLogger

    public func execute(_ command: Command) async throws -> CommandResult
    public func download(
        _ request: DownloadRequest,
        to output: ArtifactReference<FileArtifact>
    ) async throws
}
```

The filesystem facade resolves only declared capabilities:

- read-only source file;
- read-only source tree;
- mutable checkout tree;
- scratch tree;
- declared output slot;
- publication root with explicit ownership transfer.

Large external build systems receive a scoped tree handle. They are not
misrepresented as touching only one typed file. Unrestricted absolute-path
access is an audited capability with an explicit reason, is recorded in the run
manifest, and disqualifies the task from portable caching.

The context never exposes:

- runtime or scheduler actors;
- state or artifact stores;
- lock managers;
- execution-session implementations;
- arbitrary path mutation;
- nested action execution.

### Commands

```swift
public struct Command: Hashable, Sendable {
    public let executable: ExecutableReference
    public let arguments: [CommandArgument]
    public let workingDirectory: DirectoryReference
    public let environment: EnvironmentOverlay
    public let standardInput: CommandInput
    public let standardOutput: CommandOutput
    public let timeout: Duration?
}
```

Path-bearing arguments and environment values are typed:

```swift
public enum CommandArgument: Hashable, Sendable {
    case literal(String)
    case artifact(AnyArtifactReference)
    case declaredPath(DeclaredPathReference)
    case joined([CommandArgument], separator: String)
    case responseFile([CommandArgument], format: ResponseFileFormat)
}
```

This centralizes:

- host/container path translation;
- response-file generation;
- deterministic rendering;
- declared path validation;
- safe diagnostic redaction.

`ExecutableReference` distinguishes an ambient host tool, a container-resolved
tool, and a first-party artifact. An ambient host tool is legal only in a task
whose execution contract is host and whose outputs declare no artifact target.

Typed arguments do not claim to observe every filesystem access made by a
subprocess. Scoped tree capabilities declare the actual mutation boundary.

`Command.unsafeShell` is restricted to workflows that genuinely require shell
syntax. It must declare its effect scopes, is recorded prominently, and cannot
use portable caching.

## Component and Selection Model

Each recipe module exposes one component definition:

```swift
public protocol ColliderComponent: Sendable {
    static var descriptor: ComponentDescriptor { get }

    static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition
}
```

`ComponentDefinition` contains:

- the component descriptor;
- one immutable task collection;
- named entrypoints mapped to root task IDs.

Entrypoints are the command contract:

```text
build
test.default
test.gpu-headless
test.gpu-drm
test.release-gate
bootstrap
generate
install
benchmark
sanitize.address
sanitize.undefined
sanitize.thread
qualify
```

A task may be reachable from any number of entrypoints. `TaskMetadata` may carry
facets, lanes, and tags for reporting and ad hoc filtering, but those labels do
not duplicate tasks or determine identity.

Every entrypoint a component publishes is reachable from at least one selection
spelling, and every selection spelling resolves to a declared entrypoint.
Registry construction rejects an entrypoint no group or alias can select and a
selection table entry shadowed by an earlier match.

The command package contains one explicit root registry:

```swift
let components = ComponentRegistry {
    SwiftPlatformComponent.self
    AndroidRuntimeComponent.self
    ChromiumComponent.self
    CoreComponent.self
    ConfigComponent.self
    IPCComponent.self
    LinuxComponent.self
    ReactNativeComponent.self
    CompositorComponent.self
    ShellComponent.self
    TracyComponent.self
    VulkanComponent.self
    WaylandComponent.self
}
```

There is no linker-section discovery, runtime registration, or reflection.

The registry also owns named selection groups such as `all` and `runtime`.
Groups expand to component entrypoints. Aliases such as `rn`, `android`,
`android-runtime`, `gpu-headless`, and `gpu-drm` remain explicit public CLI
metadata.

Registry construction validates:

- duplicate component IDs, directory names, canonical names, and aliases;
- duplicate task and entrypoint IDs;
- duplicate action kinds;
- action/component namespace mismatch;
- unknown dependencies and artifact producers;
- entrypoints with unknown roots;
- unreachable entrypoints and shadowed selection spellings;
- overlapping output ownership.

`RecipeContext` contains declared repository layout and build-context values as
`FilePath`. It does not inspect hardware, resolve tools, hash trees, or execute
commands.

## Execution Contracts

Execution location, machine capabilities, privilege, network, and scheduling
are separate:

```swift
public struct ExecutionContract: Hashable, Sendable {
    public let environment: ExecutionEnvironment
    public let machine: Set<MachineRequirement>
    public let privileges: Set<PrivilegeRequirement>
    public let network: NetworkPolicy
}
```

`ExecutionEnvironment` is host or digest-pinned container.

`MachineRequirement` covers operating system, architecture, DRM nodes, Vulkan
capability, and other physical host properties.

`PrivilegeRequirement` covers binderfs, mount delegation, BPF delegation, and
other kernel or container privileges.

Network access is a policy, not hardware. Portable tasks declare whether
network is forbidden or restricted to content-addressed fetches. Unrestricted
network access disqualifies portable caching.

Planning resolves the action's tool requirements and derives container mounts
from its scoped filesystem capabilities. Neither is repeated in
`ExecutionContract`.

Planning rejects, as a structural error rather than a runtime failure:

- a host execution contract on a task whose Swift build context targets a
  non-host triple;
- a host execution contract on a task declaring an artifact target the runner
  cannot produce;
- an ambient host tool requirement on a task declaring an artifact target;
- a container execution contract naming an image the runner cannot execute.

Planning resolves and snapshots requirements only for the selected dependency
closure. Structural validation still covers the complete component graph. A
missing DRM device therefore rejects a selected DRM entrypoint but never an
unrelated build.

## SwiftPM Planning Integration

SwiftPM requirements are logical declarations, not directly executable
component actions:

```swift
SwiftProductRequirement(
    owner: componentTask,
    context: swiftBuildContext,
    expectedOutputs: outputs
)

SwiftTestRequirement(
    owner: componentTask,
    context: swiftBuildContext,
    expectedOutputs: outputs
)
```

`ColliderSwiftPM` installs one deterministic planner lowering. After logical
task assessment, the lowering:

1. collects dirty, selected Swift requirements;
2. groups them by complete `SwiftBuildContext` and compatible environment;
3. replaces build plus test requirements with one test invocation for a context
   containing any selected tests;
4. otherwise creates one build invocation for that context;
5. targets the repository root package;
6. uses the context-derived scratch path and cross-process lock;
7. maps every synthesized execution task back to its logical owners;
8. publishes logical task state only after the synthesized task and required
   postconditions succeed.

The lowering never emits qualified per-component product invocations for the
canonical root build. Component source inputs remain attached to logical tasks
for dirtiness and attribution. The physical Swift invocation uses stock:

```text
swift build --package-path <repository-root> --scratch-path <context-scratch>
swift test  --package-path <repository-root> --scratch-path <context-scratch>
```

The execution environment of a synthesized invocation is derived from its
`SwiftBuildContext`, not from the runner. A Linux-target context always lowers
to a container invocation. Benchmark, sanitizer, and release-gate contexts are
ordinary contexts and receive no exemption.

`ColliderSwiftPM` also owns the one Swift package task builder shared by every
recipe. A recipe names its component, package, products, source trees, lock, and
test product; it does not restate the input, postcondition, lock, and operation
shape, and no recipe infers build-versus-test from an argument array.

No architecture phase may replace this lowering with one SwiftPM process per
component.

## Planning Pipeline

Planning follows one strict order:

1. instantiate the explicit root component registry;
2. construct every component's immutable declarations and entrypoints;
3. normalize declarations without resolving external state;
4. derive execution edges from ordering, artifact, and result references;
5. validate the complete structural graph and action namespaces;
6. validate complete output ownership;
7. validate execution-contract placement across the complete graph;
8. expand command selection into component entrypoints;
9. compute selected dependency closure;
10. normalize execution and resource contracts for the selected closure;
11. request tool and container snapshots for the selected closure;
12. hash selected declared inputs through the persistent digest index;
13. calculate logical task identities from semantic edges in deterministic
    graph order;
14. assess logical local state and output postconditions;
15. run registered deterministic lowerings, including SwiftPM coalescing;
16. calculate identities and assessments for synthesized execution tasks;
17. freeze output ownership, resource indexes, attribution, and reporting order;
18. produce the immutable `ExecutionPlan`.

`ExecutionPlan` contains:

- stable reporting order;
- selected logical tasks;
- physical execution tasks;
- logical-to-physical attribution;
- semantic dependency identities and ordering edges as distinct fields;
- resolved execution contracts;
- immutable tool and container snapshots;
- local/cache assessments;
- output ownership;
- normalized resource requests;
- postconditions and publication rules.

Execution performs no tool resolution, graph traversal, identity mutation, or
new input hashing.

## Scheduler and Resource Model

The scheduler is a ready-queue actor. Readiness requires:

- every dependency succeeded or was already clean;
- weighted CPU, memory, and I/O capacity is available;
- all shared/exclusive resource claims can be reserved atomically;
- no output-tree ownership conflict exists;
- machine and privilege probes succeeded;
- the corresponding cross-process locks can be acquired.

Resources include:

- CPU weight;
- memory reservation;
- bounded I/O-heavy slots;
- checkout mutation;
- SwiftPM scratch context;
- ccache namespace;
- publication root;
- container image preparation;
- hardware device exclusivity;
- canonical output tree.

Every task class declares its real resource request. No task class receives a
lightweight default because a dispatch switch failed to name it.

All in-process claims are reserved atomically in canonical key order before
launch. A task never occupies an execution slot while waiting for another
in-process claim. Cross-process locks are acquired after admission and remain
cancellation-aware.

The synthesized root SwiftPM task declares a high CPU weight and exclusive
scratch ownership. Native preparation work overlaps only when capacity and
outputs allow it.

Failure behavior is deterministic:

1. record the original task failure;
2. stop admitting new work;
3. cancel running execution sessions;
4. wait for process-group and container cleanup;
5. release cross-process and in-process resources;
6. mark dependent tasks blocked;
7. emit final results in stable graph order.

Task-local log byte order is preserved. Cross-task events retain real
timestamps. Final summaries use stable graph order and include resource-wait
and execution durations for critical-path analysis.

## State and Cache Model

```swift
public enum TaskExecutionPolicy: Hashable, Sendable {
    case always
    case incremental
    case portable
}
```

Policy controls assessment and restoration only. It is recorded in run
manifests but is excluded from task and artifact identity.

### `always`

Runs every time. It covers presentation, launch, fresh benchmarks, and explicit
hardware observations.

### `incremental`

Uses canonical local state, task identity, and validated outputs. Most builds,
checkouts, generated trees, AOSP products, Chromium products, and SwiftPM
scratch-backed work remain incremental.

### `portable`

May restore a verified artifact snapshot. It requires:

- complete declared semantic inputs;
- complete declared outputs;
- relocatable output slots;
- no undeclared mutable state;
- no unrestricted path capability;
- no unrestricted network;
- no ambient host tool in its identity;
- representable permissions, symlinks, and file types;
- an audited execution environment.

Portable manifests contain output-slot names, content digests or directory
Merkle roots, permissions, symlink targets, and archive/chunk identities.
Restoration materializes into a temporary sibling, validates the entire
snapshot, and atomically publishes it. Existence and non-emptiness never prove
cache validity.

Run manifests record:

- task and action identities;
- semantic dependency identities and ordering edges as distinct fields;
- declared file, tree, value, environment, and artifact inputs;
- resolved semantic tools and binary digests;
- operational tools and their independent output validations;
- container image digest and container-resolved tools;
- Swift build context;
- execution and machine requirements;
- runner platform, execution environment, and artifact target;
- scoped effect roots;
- hardware probe results;
- policy and assessment;
- output snapshot digests;
- local-clean, restored, or executed outcome;
- logical-to-physical SwiftPM attribution.

Equal manifests mean equality of declared state, not proof of complete machine
equivalence.

## Sequential Implementation Plan

## Phase 1 — Freeze the invariants and close the exhaustiveness escapes

**Progress: complete.** Closed-enum handling is exhaustive, the AOSP product
stages use one explicit stage payload, symlink publication validates its target,
SwiftPM subsumption is output-aware, the placement audit and timing metrics are
in place, and the Phase 1 command and engine regression suite passes.

Delete the `default:` clause from every switch over a closed Collider enum and
enumerate the remaining cases: `scheduledResources`, `containsOCIExecution`,
`validateArtifactOutputs`, `operationEnvironment`, and `executionCoordinates`.
Replace the five-case AOSP product family, which re-discriminates one shared
payload back into a stage string inside `encode(operation:into:)`, with one case
carrying an explicit stage value. From this phase forward the compiler
enumerates the conversion surface for phase 5.

Add `PathValidation.symlinkTarget`, which resolves the link and validates the
target, and convert every symlink-publishing output declaration to it.

Add regression coverage before moving engine boundaries:

1. assert that dirty logical Swift requirements sharing one host context produce
   exactly one root build;
2. assert that a dirty test requirement whose closure produces every expected
   build output produces one root test and no preceding root build;
3. assert that a test closure missing an expected product retains one root
   build alongside the root test;
4. assert that incompatible Swift contexts produce separate invocations and
   scratch locks;
5. assert that unselected DRM, Android, and container tasks do not trigger tool
   resolution or hardware probes;
6. assert that complete graph reporting remains deterministic;
7. assert that a publication task whose symlink target is absent fails output
   validation;
8. add a complete placement audit over every public CLI spelling and record the
   exact current invalid set as benchmark, sanitizer, and release-gate
   workloads;
9. record planning duration, selected input-hashing duration, invocation count,
   and total execution makespan as the baseline. Critical-path and resource-wait
   measurement lands in phase 7 and is compared with this baseline thereafter.

Tighten the existing test-over-build subsumption at this boundary: a synthesized
test suppresses a build only after proving that its selected package closure
produces every expected build output. This correctness rule remains fixed while
the implementation moves in phase 6.

The existing synthesized SwiftPM behavior remains the enforced reference while
the later planner is extracted, with this corrected subsumption rule.

### Verification gate

Collider command and engine tests pass. No switch over a Collider enum contains
`default:`. A dry-run of the complete build reports the minimum correct root
Swift invocation set per compatible context. A dry-run of complete tests
reports no root build whose expected outputs are already produced by the root
test and retains every build with an uncovered expected output. The placement
audit reports exactly the known benchmark, sanitizer, and release-gate defects;
phase 2 empties that set.

## Phase 2 — Close the host/target execution split

This phase repairs live incorrect behavior and establishes the placement rule
the rest of the architecture depends on.

**Progress: complete.** The native SDK root is per-target, obsolete
untargeted publications are gone, benchmark/sanitizer/release-gate work is
planned into Linux arm64 OCI execution, Swift product header prebuilds are
ordered explicitly, Wayland generation uses the produced arm64 scanner, Node,
Corepack, and Yarn are pinned in the builder image, target identities no longer
contain the removed ambient host tools, and Doctor validates the new ownership
layout. The placement audit is empty and all three affected command dry-runs
resolve to the intended OCI coordinates. A real RN bootstrap completed the
arm64 and x86_64 native lanes, SDK publication, JavaScript installation, and RN
generation. Its clean second run skipped every target-producing task and ran
only the deliberately always-run `core.sources` bridge that phase 5 deletes.
Wayland regeneration completed through the produced arm64 scanner. The final
host verification passes all 125 engine tests, all 63 command tests, the
Collider build, formatting, and diff checks. The portability corrections found
by that matrix include native APFS directory exchange, placement-independent
tree identity, macOS raw pseudo-terminal handling, and deterministic network
interruption fixtures.

Collapse the native SDK root to one meaning. `NUCLEUS_NATIVE_SDK_ROOT` becomes
per-target everywhere: `tools/host-env.sh`, `collider-setup.sh`,
`WorkspaceContext` defaulting, container mounts, `WorkspaceDoctor` path checks,
and the root manifest all resolve the same level. Delete the untargeted
`<root>/render` and `<root>/rn` publication slots along with
`publishRenderSDK`'s orphan `.skia-build/graphite` link and its nonexistent
`core.skia.host` default dependency. The Android render publication becomes a
per-target slot named for the target it holds, produced by the task that builds
it. Reset the affected derived state once rather than tolerating a stale layout.

Move every Linux-target Swift workload off the host runner:

1. give `BenchmarkCommand` an OCI Swift build context per benchmark suite,
   derived the same way `ComponentRegistry.linuxArchitectureTasks` derives the
   architecture lanes;
2. give `SanitizerCommand` an OCI Swift build context per sanitizer, preserving
   the sanitizer runtime environment, suppression files, and harness execution
   inside the container;
3. declare the six release structural suites as Linux lane test tasks on the
   release build context, selected through the ordinary test selection path,
   and delete `Orchestrator`, `WorkspaceComponent`, and the direct `swift test`
   shelling with them. Phase 4 gives these tasks their own `test.release-gate`
   entrypoint; phase 2 only moves them into the graph and the container.

Move code generation that shapes committed source into the container. The
`wayland.generate` scanner steps execute against the pinned scanner produced by
`wayland.native-sdk.linux-arm64` rather than an ambient `PATH` lookup.
`SwiftWaylandGen` and `VulkanGen` remain first-party host Swift tools whose
binary identities are first-party produced artifacts.

Remove ambient host tools from target task identity. During this phase,
`core.sources` may use host `git` and `python3` only as operational tools for
exact-revision, content-validated source materialization and declares no target
artifact. Its semantic identity contains the revision, manifest, embedded
verification logic, and resolved checkout result, not the operational binary
digest. This verifier is an explicit bridge and is deleted by phase 5's exact
Git materialization action. Its `unzip` and `chmod` steps become engine
operations so the extracted Linux `gn` never depends on the runner's coreutils.
`rn.generate` and `rn.javascript-dependencies` resolve `node` and `corepack`
from the pinned container image, which also makes `node_modules` target-shaped
rather than runner-shaped. Any materialization step without an exact content
postcondition uses a pinned semantic tool instead.

Add container capability and per-target native SDK ownership checks to
`WorkspaceDoctor`, and delete its private `nativeSDKRoot` duplicate in favor of
the single workspace accessor. Do not require a host `wayland-scanner`; it is a
produced container artifact.

Keep command vocabulary independent of the runner. Selecting `Benchmark` or
`Sanitize` resolves the required container executor during planning and fails
with a placement diagnostic when the runner cannot satisfy it. Command
registration never implies a host fallback.

### Verification gate

The complete placement audit returns an empty invalid set. `collider test`,
`collider benchmark`, and `collider sanitize` resolve and execute through the
same pinned Linux environments on the arm64 macOS builder. The pinned OCI
contract, not a second physical Linux host, is the target-environment boundary.
Their declared output snapshots are equivalent across architecture lanes;
outputs claimed to be reproducible are additionally byte-identical under
explicit path, timestamp, locale, archive, and random-seed normalization.
No target identity contains an ambient host tool, directly or transitively.
Planning rejects a selected entrypoint whose prerequisite cannot be resolved.
`collider doctor` validates only complete-checkout and bootstrap prerequisites.
Regenerating the Wayland protocol sources on macOS and on Linux produces
identical committed output. Every path under the native SDK root has exactly one
producing task, and deleting any of them fails validation rather than reporting
success.

## Phase 3 — Normalize the declaration surface

**Status: complete.** `WorkspaceLayout`, `WorkspaceContext`, cache roots, native
SDK roots, and Swift target SDK storage use `FilePath`; cache and native SDK
resolution happen once during context construction. Recipe modules own the
package-visible identifiers used by their consumers. Host-only per-component
build/test graphs and unreachable selection branches are gone, so planning no
longer resolves the host Swift compiler for container-only selections. Command
support has one owner per concern and one file per top-level command.
`RunOptions` is the direct parsed representation. The engine test target lives
in `collider/engine/Package.swift`, and the literal path-conversion gate is
closed.

The layer that later phases rewrite must first speak one path type, one
workspace context, and one task-identifier vocabulary.

Change `WorkspaceLayout` to vend `FilePath` and fix every consumer. `URL`
remains only at Foundation call sites that require it.

Collapse duplicated resolution to one implementation each: the cache root, the
native SDK root, and the workspace-relative path resolver defined twice in
`ColliderCommand.swift`. Remove the force-unwrapped environment read by making
the invariant explicit at the type instead of at the use site.

Give every recipe module package-visible `TaskID` constants for the tasks other
modules reference, and replace recipe-to-recipe string literals with them.
Command-layer selection remains string-driven until phase 4 replaces it with
entrypoints.

Delete the unreachable selection branches in `selectedBuildTasks` and
`selectedTestTasks`, and delete the host-context per-component build and test
task construction that only those branches appeared to select. Planning stops
resolving and hashing the host Swift compiler on commands that select no host
task.

Split the two catch-all command files. `WorkspaceContext`, workspace root
discovery, the process runner, task controls, and language-server publication
each get their own file, and `ColliderCommand.swift` becomes one file per
top-level command.

Make `RunOptions` the parsed representation rather than a hand-copied mirror,
deriving specified-ness from optionality and deleting both `wasSpecified` flags.

Move the engine test target into `engine/Package.swift` so the engine is
verifiable as an independent boundary.

### Verification gate

No `FilePath(...path)` conversion remains in the command layer or recipes.
`swift test --package-path collider/engine` runs the engine suite. Every public
CLI spelling resolves to a task that exists; no selection table entry is
unreachable. `RunOptionsTests` passes unchanged. Building or testing one
component resolves no tool the selection does not require.

## Phase 4 — Unify components and command entrypoints

**Progress: complete.** The engine now owns immutable component descriptors,
entrypoints, definitions, recipe context, typed entrypoint references, selection
groups, and a validated component catalog. Catalog construction validates the
complete task graph, component and directory identity, selection spellings,
entrypoint roots, cross-component dependencies, and overlapping output trees.
The outer `ColliderSwiftPM` target now owns the single build/test requirement
builder, and the four dead per-recipe argument-sentinel helpers are deleted. The
native builder, AOSP/gfxstream, Core native SDK, React Native native SDK,
Wayland, Linux lanes, compositor DRM, Vulkan generation, Chromium, benchmark,
sanitizer, and release-gate recipes now publish immutable component definitions
into one catalog. Bootstrap, generation, browser, benchmark, sanitizer, AOSP,
runtime build, and runtime test paths select those definitions rather than
reconstructing task arrays. This exposed and repaired the missing
gfxstream-to-builder edge, duplicate Chromium source producers, and quadratic
output-ownership validation. Android-host Skia, native-SDK publication, Swift
cross-build, ABI validation, and the opinionated Gradle verification now live
in the Core component, and the Android SDK bundle name comes from the pinned
target-SDK input catalog rather than the unrelated Swift source digest. Swift
target-SDK generation is also one configured component definition; both
`build swift-sdk` and `swift-sdk rebuild` select that graph, and its
cross-process lifecycle lock is declared by every task rather than supplied by
one command path. `ComponentSelection` and `GeneratorComponent` are deleted.
Build, test, bootstrap, and generation commands pass registry spellings
directly, and each execution constructs one catalog and selects roots from it.
The Linux runtime installer, Android add-on packager, and Tracy receiver build
are recipe-owned tasks selected through the Shell and Android-runtime
components. Commands no longer launch build systems or construct task
declarations. The registry freezes its complete public request table, rejects
unpublished routes and unreachable entrypoints, requires action kinds to live
under their owning component namespace, and rejects one action kind backed by
multiple implementations. Focused catalog and registry tests cover the frozen
spelling table and these construction-time failures.

Add `ColliderComponent`, `ComponentDescriptor`, `ComponentDefinition`,
`ComponentEntrypoint`, `RecipeContext`, and immutable task builders to
`ColliderCore`.

Convert every recipe module to one `makeComponent(in:)` implementation. Each
component constructs one graph containing all of its build, test, bootstrap,
generate, install, benchmark, sanitizer, qualification, and publication tasks.
It publishes named entrypoints into that graph. No command or registry callback
constructs a command-specific task array.

Introduce the one shared Swift package requirement builder and delete the six
near-identical recipe helpers, including every `arguments == ["build"]`
sentinel. Build and test are distinct logical requirements rather than argument
shapes.

Replace:

- `ComponentSelection`;
- per-command recipe calls;
- command-owned task reconstruction;
- hard-coded component path switches;
- command-layer `TaskID` derivation;
- `BenchmarkCommand` and `SanitizerCommand` execution logic;
- the remaining direct repository-wide test orchestration.

Create one explicit root component list. The registry owns canonical component
names, aliases, selection groups, and entrypoint spellings. Commands parse a
selection and hand it to planning; they contain no component behavior.

Graph construction remains pure. DRM discovery, lavapipe resolution, container
inspection, tool discovery, and all other external observations become
requirements resolved only for the selected closure.

### Verification gate

Every accepted CLI spelling resolves through registry metadata. Frozen CLI
tables preserve intended public aliases. Complete registry validation finds no
duplicate IDs, aliases, action kinds, entrypoints, or output ownership, and no
unreachable or shadowed spelling. Building an unrelated component probes no
optional hardware or tool. No command launches a build system, test runner,
benchmark, sanitizer, or qualification harness outside a planned task. Every
component graph is constructed exactly once per planning operation.

## Phase 5 — Complete actions, typed artifacts, and scoped effects

This phase establishes the final declaration and identity vocabulary before any
new persisted identity becomes active.

**Progress: in progress.** `ActionKind`, action-local canonical identity
encoding, semantic and operational tool requirements, declared effect scopes,
the final assessment-policy names, and cancellation, logging, filesystem,
command, and download capabilities are implemented. `TaskBuilder` now creates
opaque typed artifact, result, and ordering references; graph validation proves
their producer slots, paths, and value types, and ordering-only edges are
excluded from identity. Runtime filesystem capabilities enforce declared
read/write roots and reject lexical escapes. The first producer-consumer
migration is underway: AOSP source-lock verification, source provenance,
signing metadata, validation provenance, and publication provenance now flow
through typed JSON references instead of raw dependency-output paths. Every
standalone download now produces a typed file slot: Swift host, Android, and
Ubuntu packages; the AOSP Repo launcher; GN; and Boost. Swift Linux sysroots
and runtime installations, the active Boost generation, Skia external sources,
React Native codegen, and Wayland-generated sources flow as typed directories.
Skia consumes the exact GN executable, Wayland x86_64 compilation and codegen
consume the exact native `wayland-scanner`, and render-SDK publication consumes
the exact architecture-matched Skia build directory. React Native's Hermes and
support-library archives feed its C++ runtime through typed slots, and native
SDK publication consumes that typed runtime closure. The Swift SDK generator,
assembled Linux and Android SDKs, validation executables, activation marker,
and discovery publications form one typed producer-consumer chain. Chromium's
depot-tools bootstrap executable, source provenance, builder image, CEF and
browser publications, retention, tests, and installation also form one typed
chain. AOSP compilation, signing, image assembly, validation, and publication
consume typed builder-image, target-files, host-tool, image, signing, and
provenance slots. The composition root now merges each architecture's active
Swift target SDK, Core, React Native, and Wayland SDK publications, and
gfxstream products into one typed target-artifact closure. Linux builds,
benchmarks, sanitizers, and release gates consume that closure; raw SDK-tree
inputs and handwritten cross-recipe task-ID edges are deleted. The managed
Android add-on consumes the exact active AOSP generation. The Swift runtime
builder image, React Native JavaScript dependency tree, and Core Android host
build and validation chain are typed producer-consumer relationships as well.
Swift SDK activation and discovery links are declared output slots rather than
postcondition-only paths. Remaining operation cases, unrestricted command
paths, legacy identity activation, and the derived-state reset remain open. The
first operation-family deletion is complete: Meson
setup, direct file copy, matching-file copy, ZIP extraction, raw file write,
link-metadata sanitation, directory publication, and apt-package validation no
longer exist as operation cases, payloads, runtime dispatch, or retained
test-only compatibility surface. The obsolete attributed Swift-test no-op and
raw permission mutation cases are gone as well. Test fixtures write through
scoped actions. Every production create/remove/symlink/retention preparation is
now owned by a semantic recipe action. The create-directory, remove-path,
replace-symlink, symlink-publication, and directory-retention operation cases,
their global identity tags, and their runtime dispatch are deleted; engine
fixtures use scoped actions, and Swift SDK discovery publication retains its
behavioral coverage beside the owning recipe. Generation activation and every
standalone download are now namespaced recipe actions, so their operation cases
and global identity tags are deleted as well. Download policy has one canonical
action identity value, and action-owned output validation rechecks the expected
digest during clean-state assessment. Active-generation reporting is explicit
task reporting metadata rather than a kernel test for a Swift SDK operation.
Android host ELF/JNI validation now lives in the core recipe with its behavioral
test; its payload, operation case, and `ColliderRuntime` workflow file are
deleted. Chromium depot-tools materialization is likewise a recipe-owned exact
checkout action that rejects tracked modifications; the generic managed-source
workflow is deleted. Every OCI builder-image preparation is now a namespaced
recipe action using the declared container capability. Action requirements
carry execution placement and resource demand, preserving scheduler behavior
without kernel operation inspection, and the global OCI image-preparation
operation case and dispatch are deleted.
All recipe-owned standalone OCI executions are now semantic actions as well:
Skia, React Native JavaScript and native builds, Wayland generation and native
SDK builds, gfxstream, Chromium tests, and Swift Linux runtime builds execute
through the container capability. Their action requirements preserve target
placement and scheduler resources without treating the Apple-container Swift
API as an ambient executable tool. Integration tests execute these actions
against a recording container capability instead of inspecting legacy enum
payloads. The only remaining raw OCI execution is emitted by the SwiftPM
lowering that moves to `ColliderSwiftPM` in phase 6.
The shared native-builder image is now one typed file artifact constructed by
the native component and injected into recipe configuration. Skia, React
Native, Wayland, gfxstream, and synthesized Linux SwiftPM tasks consume that
exact reference; handwritten `native.builder` dependencies and raw image-path
inputs are deleted. Recipe targets that needed the native-builder module only
for its task ID no longer depend on it.
Core exports each architecture's exact Skia ICU archive to the composition root,
which injects it into React Native's Hermes build. The raw generated ICU path,
handwritten Core task dependency, and React Native recipe dependency on the Core
recipe module are deleted. React Native SDK publication likewise no longer
carries an unrelated ordering dependency on Core SDK publication.
AOSP source-lock verification and exact Repo source materialization now execute
as Android-runtime actions through scoped filesystem and command capabilities.
Their behavioral fixtures moved beside the owning recipe, the source-domain
payloads left `ColliderCore`, and both global operation cases, digest branches,
runtime dispatch branches, and the 735-line engine workflow are deleted.
AOSP signing-identity creation and validation now follow the same ownership:
the Android-runtime action declares OpenSSL as a semantic tool, scopes all key
material effects to its output root, validates certificate/private-key pairs,
and retains behavioral coverage for initial creation and repeat validation. Its
payload, global operation case, legacy digest and dispatch branches, and engine
preparation method are deleted.
AOSP product publication is also recipe-owned. The action commits signed files
and the image tree, writes provenance last, activates the generation, and
applies bounded retention through scoped filesystem capabilities. The publish
stage, engine workflow method, hard-link publication helpers, and its runtime
dispatch branch are deleted; behavioral coverage proves commit-marker ordering,
generation activation, and image publication.
AOSP image assembly now lives beside that publication action. It declares its
Linux/amd64 execution coordinate, Android artifact target, container mounts,
and host unzip tool; validates the generated host tools and staged target-files;
normalizes sparse images; and commits the archive and image directory through
scoped capabilities. A bounded prefix-read filesystem capability replaces the
engine's direct `FileHandle` access, so sparse-image detection never loads an
entire image. The assembly stage and engine implementation are deleted, and a
behavioral fixture proves container isolation policy, sparse normalization, and
the complete staged image set.
AOSP product signing is recipe-owned as well. It reuses the signing-identity
validator and the exact OCI execution declaration, exposes OpenSSL as its only
semantic host tool, mounts key material read-only, and stages the signed archive
through scoped filesystem effects. The signing stage, duplicated engine key
validation, runtime dispatch, and legacy identity branch are deleted;
behavioral coverage proves key-pair validation, release AVB arguments,
fail-closed networking, and production-variant policy.
The AOSP compile and validation stages complete the family conversion. Compile
now owns exact Repo cleanliness/provenance checks, product-tree synchronization,
ccache and source mountpoints, nsjail negative-boundary probes, fail-closed Soong
execution, and target-files publication through action capabilities. Container
execution returns its `CommandResult`, allowing policy-sensitive actions to
inspect captured output without invoking runtime internals. Validation owns AVB,
APK/APEX certificate, payload, SDK/vendor-level, fingerprint, font, image, and
provenance checks. The AOSP build model and all behavioral fixtures moved into
the Android-runtime recipe; `TaskOperation.aospProduct`, its global identity and
coordinate branches, every runtime dispatch branch, and the complete engine
`AOSPProductWorkflow.swift` are deleted.
Chromium source preparation is now a recipe-owned action. It declares exact
Git, Python, and depot-tools requirements; scopes immutable source generations
and the shared repository object cache separately; uses one recoverable
content-addressed candidate; validates every locked commit, tree, clean
worktree, PGO profile, V8 profile, depot-tools revision, and provenance digest;
and durably publishes the generation before activation. Its behavioral fixture
moved beside the Chromium recipe. The global source-preparation case, digest,
resource, environment, coordinate, validation, and dispatch branches and the
engine `ChromiumSourceWorkflow.swift` implementation are deleted.
The rest of the Chromium family is recipe-owned too. Product compilation
declares its Linux/amd64 container coordinate, exclusive build resources,
source/image/depot-tools inputs, staged PGO data, and scratch roots; records the
normalized GN, Clang, source, PGO, and V8 identity before and after the build;
and fails if they drift. Browser and CEF assembly use fixed recoverable
candidates, validate dynamic linkage and launch/consumer contracts, create
deterministic archives and checksums, and publish immutable generations through
scoped capabilities. Browser installation declares its Widevine inputs,
versioned prefix publication, privileged system-sandbox root, validation tools,
desktop integration, and retention policy. The source/build/artifact/install
payload models and behavioral fixtures live with the Chromium recipe. Every
Chromium operation case, global digest/resource/environment/coordinate branch,
runtime dispatch branch, and the product, browser, CEF, and installation engine
workflow files are deleted.
Every executable recipe task now has one recipe-owned action. The former
nonempty `TaskOperation.sequence` sites in the native builder, Swift runtime,
Skia, React Native, Wayland, gfxstream, Linux architecture probes,
qualification workloads, and Chromium are gone. Atomic configure/build/install
workflows own ordered OCI process pipelines as action data and execute those
processes directly through the container capability; they never contain or
dispatch child actions. Pipeline construction validates one execution platform,
artifact target, and host environment, combines effect scopes and resource
demand, and contributes every ordered execution to action-local identity.
Preparation that belongs to the same transaction now happens inside that
action. Skia dependency materialization and GN installation instead became two
tasks because they publish independent typed outputs.

Chromium build and publication ownership is now explicit. CEF compilation and
browser compilation publish distinct typed build-directory artifacts and may
run concurrently. Their publication actions consume those exact directories,
and retention consumes both publications. Assembly actions perform their own
dynamic-link, launch, consumer, version-manager, archive, and output validation;
the redundant standalone validation actions are deleted. Chromium test
compilation and execution form one test action, and browser installation owns
validation of its consumed active publication. The only remaining sequence
values are empty placeholders on logical SwiftPM requirements plus synthesized
SwiftPM operations in the runtime; phase 6 removes both while extracting the
lowering.

The native builder bootstrap boundary is now typed as well. The builder image
and ccache form a `NativeOCIBaseConfiguration`; only the Swift target SDK recipe
uses that bootstrap layer. After SDK activation, graph construction creates the
full `NativeOCIConfiguration` with the activation task's opaque `active-sdk`
reference. Skia, Wayland, gfxstream, Hermes, and the remaining React Native
native builds consume that reference directly, and Linux SwiftPM contexts mount
its resolved path. React Native also consumes Core's typed Skia external-source
artifact for ICU instead of rediscovering a generated subtree by path.

Complete-catalog validation now rejects any raw file, tree, optional-tree,
dependency-output, or tool path equal to or nested beneath another task's
declared output. The complete runtime graph passes this validation, and a
negative contract fixture proves that an explicit dependency plus a raw child
path is still rejected: generated data crosses components only through its
producer and output slot.

`TaskOperation` is deleted. A task now carries either one namespaced semantic
action or no action when it is a logical SwiftPM requirement or aggregate.
Runtime no longer switches over commands, OCI executions, or nested sequences;
it schedules, identifies, executes, and validates the task's single action.
Atomic multi-process behavior lives inside the owning recipe action. SwiftPM's
ordered prebuild and root invocations are consequently one
`swift-package.invoke` action owned by `ColliderSwiftPM`, with host commands or
OCI executions selected from the complete build context. Empty sequence
placeholders and the global operation identity branches are gone.

Complete the existing action seam with:

- `ActionKind`;
- `ActionRequirements` with semantic and operational tool roles;
- `ActionIdentityEncoder` with action-local positive tags and duplicate or zero
  rejection;
- cancellation, logger, filesystem, command, and download capabilities;
- typed ordering, artifact, and result references;
- output slots and scoped checkout, scratch, output, and publication effects;
- the final `always`, `incremental`, and `portable` assessment-policy names,
  with every currently reusable task mapped to `incremental` and no task yet
  granted portable restoration.

`ActionRequirements` is authoritative for intrinsic tools and effects.
`TaskDeclaration` adds placement, machine, privilege, network, reuse, and
scheduler policy without mirroring those requirements.

Migrate producer-consumer relationships in strict order:

1. generated metadata and JSON reports;
2. downloaded archives and extracted directories;
3. generated source directories;
4. host tools and executable products;
5. native SDKs and static archives;
6. Swift and Android target SDK generations;
7. AOSP and Chromium publication generations.

For every relationship, create the output through the producer task builder,
pass its opaque typed reference to consumers, derive the execution and semantic
edges, validate output type and ownership, and delete the raw generated path and
manual dependency-output input. Use `TaskResultReference` when success or
declared result data is semantically consumed without a file. Use `after` only
for ordering.

Change command arguments, working directories, and environment path values to
typed references. Large external build systems receive scoped tree
capabilities. Remaining unrestricted absolute-path or shell access is explicit,
audited in the run manifest, and ineligible for portable caching.

Convert `TaskOperation` cases in strict order:

1. command and process actions;
2. create, copy, write, remove, and symlink actions;
3. exact Git materialization, download, and archive actions;
4. generation activation, retention, and publication actions;
5. Swift target SDK source, bootstrap compiler, Android SDK, wiring, sanitation,
   and validation actions;
6. AOSP source, container, signing, compile, assemble, validate, and publication
   actions;
7. Chromium and depot_tools source, build, CEF, browser, validation,
   installation, and publication actions;
8. remaining Android-host and qualification actions.

Each action moves directly to its owning recipe module with its behavioral tests
and fixtures. Delete the corresponding enum case, runtime method, payload, and
switch branches in the same step. Recipe modules import `ColliderCore`, never
`ColliderRuntime`. There is no sequence action, general legacy action wrapper,
compatibility encoder, or nested dispatch.

The generic exact Git materialization action accepts a declared set of checkout
paths, remotes, and exact Git object names. It resolves each object to a commit,
fetches only when the object is absent, checks out that commit, rejects
`sync-deps.disable` and every tracked modification, and returns the resolved
commit set as its typed result. It delegates object resolution, checkout, and
worktree cleanliness to Git; it does not maintain a second lockfile, source
snapshot, index, or recursive digest of Git-tracked contents. The Skia recipe
owns translation from its pinned `DEPS` source into that declaration; the
kernel never names Skia or interprets component policy. Landing this action
deletes the `git-sync-deps` execution and the embedded Python verifier together.
Root Git remains authoritative only for the Skia gitlink; the action is
authoritative for the nested repositories that the root checkout does not
track.

After the final conversion:

- delete `TaskOperation` and the global digest tag allocation;
- remove domain workflow implementations from `ColliderRuntime`;
- make consumption of a known generated output through an unrelated raw path a
  planner error;
- activate the single canonical task and action identity encoding;
- validate the exact old task-state and cache roots against Collider's derived
  state safety root;
- delete those roots once and create the canonical empty state layout.

### Verification gate

All recipe actions execute through narrow `ActionContext` capabilities.
Ordering edges do not affect identity; semantic artifact and result edges do.
Changing each identity-bearing field changes canonical bytes, while changing a
lock, resource weight, diagnostic label, or reuse policy does not. Duplicate
action kinds, invalid namespaces, duplicate tags, unknown references, output
type mismatches, ownership overlap, and undeclared effects fail validation.
Artifact references cannot be constructed except from declared producer slots.
A clean second run performs no work. No component-domain workflow remains in
engine source, and no identity version, compatibility decoder, dual encoder, or
legacy state remains.

## Phase 6 — Extract deterministic planning, persistence, and SwiftPM lowering

**Progress: in progress.** The deterministic lowering protocol and immutable
assessed/lowered task values now live in `ColliderCore`. `ColliderSwiftPM` owns
grouping by complete build context, filter-preserving test grouping,
output-aware test-over-build subsumption, physical task identity and
construction, semantic-reference propagation, logical attribution, and
non-Swift prerequisite discovery. The composition root installs that lowering.
`ColliderRuntime` consumes only generic lowered tasks and no longer names,
groups, or synthesizes Swift build contexts. Swift-specific invocation-count,
selection, subsumption, context-separation, and prerequisite tests moved beside
the lowering. Extracting `ColliderPlanning` and `ColliderPersistence`, freezing
the full `ExecutionPlan`, and reducing runtime to execution over that plan
remain open.

Create `ColliderPlanning` and move component expansion, selection, graph
normalization, semantic-edge identity, placement validation, output ownership,
resource normalization, state assessment, and immutable plan construction out
of `TaskEngine`.

Define immutable planning-service protocols in `ColliderCore`. Create
`ColliderPersistence` and move:

- artifact and tree hashing;
- persistent digest metadata;
- task state;
- run manifests and event storage;
- atomic durable files;
- artifact snapshot records;
- artifact and generation retention.

Planning receives immutable snapshots and request/response service values.
Execution receives an `ExecutionPlan` and cannot mutate identity, add tasks, or
access planning mutation APIs.

Create `ColliderSwiftPM` in the outer package. It owns logical build and test
requirements, the shared requirement builder introduced in phase 4, and one
registered deterministic lowering. Move the existing synthesized Swift
aggregation out of runtime and preserve:

- grouping by complete `SwiftBuildContext` and compatible environment;
- one stock root package invocation per context;
- shared scratch paths and cross-process locks;
- test-over-build subsumption only when the selected root test closure produces
  every expected build output;
- explicit expected-output validation;
- logical-component attribution;
- execution placement derived from the build context rather than the runner.

When a test closure does not produce an expected executable or other product,
the lowering retains the required root build instead of assuming that every
`swift test` invocation subsumes every root product.

Delete planning, state assessment, and Swift synthesis from `ColliderRuntime`.
Create the thin `ColliderEngine` composition root that obtains persistence
snapshots, invokes the planner, and hands the frozen plan to runtime execution.

### Verification gate

The same declarations and planning snapshots produce byte-identical plans.
Unselected trees are not hashed, tools are not resolved, and hardware is not
probed. The Phase 1 invocation-count tests pass against the extracted lowering,
including coverage for a test closure that does not subsume a required product.
Editing multiple logical components in one compatible context still emits one
root SwiftPM invocation. Benchmark, sanitizer, release-gate, and architecture
lanes lower without command-specific exceptions. Persistence tests cover
interrupted writes, corrupt derived state, and bounded retention.

## Phase 7 — Complete the resource-aware runtime

Move the existing bounded ready queue, weighted CPU and memory admission,
exclusive claims, and lock-disjointness checks into `ColliderRuntime` execution
over the frozen plan.

Complete:

- canonical output-tree reservation;
- atomic reservation of every in-process claim in canonical key order;
- explicit resource requests for every task class;
- bounded I/O-heavy capacity;
- execution-session and process-group cancellation;
- container cleanup on success, failure, cancellation, and runner interruption;
- failure propagation that never publishes successful state after failure;
- stable reporting;
- critical-path, resource-wait, planning, hashing, and execution measurements.

A task never occupies execution capacity while waiting for another in-process
claim. Cross-process locks are acquired after admission and remain
cancellation-aware. The root SwiftPM task reserves its scratch database
exclusively and requests a realistic CPU and memory share. External build
systems declare their checkout, cache, memory, I/O, container, device, and
output constraints explicitly.

First execute the complete acceptance suites with scheduler capacity one. Then
enable the production capacity policy.

### Verification gate

Capacity-one and concurrent runs select identical plans and produce equivalent
declared outputs. Stress tests demonstrate no overlapping output mutation,
lock-order deadlock, leaked process group, leaked container, state publication
after failure, or occupied execution slot waiting for an in-process claim.
Every task declares resources. Task-local log byte order and stable final
reporting are preserved. Critical-path and resource-wait data explain the
difference from the Phase 1 makespan baseline.

## Phase 8 — Remove superseded architecture and validate the kernel

Delete:

- obsolete operation payloads and digest encoders;
- component-specific runtime extensions;
- command-specific graph construction;
- duplicate component identity types;
- duplicate path and cache-root resolution;
- raw generated-output dependencies;
- pre-plan and nested execution paths;
- temporary migration diagnostics and adapters.

This deletion includes the Phase 2 Skia operational-tool bridge: no embedded
dependency verifier and no Collider invocation of `git-sync-deps` remains.

Run the kernel acceptance matrix:

1. engine, planning, persistence, runtime, recipe, and command tests;
2. root host build and complete root tests;
3. Android manifest resolution and supported cross-compilation checks;
4. Swift SDK, AOSP, Chromium, native SDK, and publication behavioral suites;
5. capacity-one and production-capacity scheduler replays;
6. clean second-run verification for every component entrypoint;
7. macOS-runner and Linux-runner equivalence for container-executed entrypoints;
8. SourceKit-LSP configuration and semantic checks;
9. planning, hashing, invocation-count, resource-wait, and critical-path
   comparison with the Phase 1 baseline.

The kernel refactor is complete only when:

- no engine target contains component-specific workflow terminology;
- a workflow change touches only its recipe and generic contract extensions;
- commands select entrypoints without reconstructing task arrays;
- no command drives a build system outside a planned action;
- execution accepts only immutable plans;
- one compatible Swift context produces the minimum correct root SwiftPM
  invocation set;
- task execution follows the declared target rather than the runner;
- no target identity contains an ambient host tool directly or transitively;
- generated artifacts flow through opaque typed producer/output references;
- ordering-only edges never affect identity;
- every published path has exactly one producer;
- every mutable effect is scoped and recorded;
- concurrency is safe across tasks and Collider processes.

## Phase 9 — Add audited portable caching

Portable caching builds on the completed kernel; it does not shape or delay the
kernel migration.

Keep `always`, `incremental`, and `portable` as assessment policies excluded
from task identity. Migrating an action from incremental to portable never
changes its output-equivalence identity.

Implement verified snapshots, restoration, quarantine, and bounded storage in
`ColliderPersistence`. Promote bounded actions in strict order:

1. generated text, JSON, and metadata;
2. downloaded content-addressed files;
3. deterministic generated sources;
4. bounded native archives and first-party tools;
5. other relocatable outputs proven complete by behavioral replay.

Keep SwiftPM scratch trees, mutable source checkouts, AOSP build trees, Chromium
build trees, hardware qualification, unrestricted shell workflows, and
unrestricted network workflows nonportable unless a later complete audit proves
otherwise. A task with an ambient semantic tool, unrestricted effect, or
unverified operational tool is ineligible.

### Verification gate

Deleting a portable local output and restoring it reproduces the complete
validated tree, metadata, permissions, and symlinks. Corrupt snapshots are
quarantined and rebuilt. Relocation proves absolute checkout paths are absent
from artifact identity. A macOS runner and Linux runner exchange artifacts for
every container-executed task actually promoted to portable. Incremental and
portable assessment of the same task use the same output-equivalence identity.

## Non-Goals

This architecture does not add:

- dynamic third-party plugins;
- runtime component discovery;
- distributed execution or remote workers;
- a public plugin ABI;
- arbitrary evaluated build scripts;
- automatic syscall-based dependency discovery;
- universal sandboxing;
- a second dependency resolver;
- a host execution fallback for target workloads;
- compiler-macro authoring layers for declarations that are already explicit;
- portable caching claims for opaque external build trees.

Collider remains a compiled, explicit, deterministic Nucleus meta-build system:

```text
recipes own declarations and actions
commands select component entrypoints
planning validates, assesses, places, and lowers
runtime schedules and executes
persistence records and restores
```
