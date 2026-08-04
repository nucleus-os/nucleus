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
all dirty requirements for one `SwiftBuildContext` into one stock root
`swift build` or `swift test` invocation. A test invocation subsumes the build
invocation for the same context. No component action launches its own SwiftPM
build.

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

**Identity-bearing tools are pinned.** A tool whose binary digest enters task
identity is resolved inside the pinned container image or is a first-party
artifact produced by another task. Ambient host tools may participate only in
host-only source materialization, and such a task declares no target artifact.
A task whose identity depends on the contents of the runner's `/usr/bin` cannot
share state across runners and is never portable.

**One environment name has one meaning.** A path exported to both host and
container execution resolves to the same logical level in both. The native SDK
root is always per-target; there is no untargeted level and no environment
variable whose interpretation depends on where it is read.

**Every published path has a producing task.** Every path a manifest, action, or
external build system reads from a Collider-owned publication root is a typed
output slot with exactly one producer. Symlink publication validates the link
target, not merely the link.

**The kernel never enumerates component workflows.** Adding or changing an
AOSP, Chromium, Swift toolchain, React Native, compositor, or other
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

**Identity describes output equivalence, not scheduling.** Task identity covers
semantic inputs, dependency identities, output slots, action identity, and
execution properties that can affect results. Diagnostic metadata, declaration
order, locks, concurrency limits, and other scheduling-only data do not cause
rebuilds.

**Identity migration is a hard break.** Collider has one canonical identity
encoding and one state layout. The action migration deletes the exact legacy
task-state and cache roots before the new encoding is used. Collider carries no
schema number, version namespace, compatibility decoder, or dual identity
encoder. A future incompatible identity or persisted-state change performs the
same explicit derived-state reset.

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

**Macros are authoring sugar.** Every action and identity can be written and
tested without macros. Macros may generate repetitive conformance only after
the explicit contracts stabilize. Runtime registration and reflection are
never used for discovery.

## Current Foundation

The production repository already has the foundations this plan preserves:

- the repository root owns one first-party SwiftPM graph;
- Collider synthesizes one stock Swift build or test per compatible context,
  and `subsumedDependencies` already implements test-over-build subsumption;
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
  thirty-eight operation cases, not designing the seam.
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
   AOSP, Chromium, Android SDK, browser, and toolchain workflows.
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
Repaired in phase 2, absorbed into entrypoints in phase 5.

**`collider benchmark` builds Linux products on the host.** `BenchmarkCommand`
takes a host release `swiftPMInvocation` and builds `NucleusLinuxBenchmarks`,
which depends on `NucleusLinuxReactorC`, `NucleusLinuxDBus`, and
`NucleusLinuxSessionC`. The command is registered unconditionally, unlike `Run`.
Repaired in phase 2, absorbed into entrypoints in phase 5.

**`collider sanitize` builds and executes Linux harnesses on the host.**
`SanitizerCommand.run` takes a host sanitizer `swiftPMInvocation`, runs
`swift test` or `swift build`, then executes the produced binary directly. Its
invocation table spans `platform-linux`, `compositor`, `android-runtime`, and
`integration-tests/window-client-conformance`. Its own source comment states
the Linux-host assumption. Repaired in phase 2, absorbed into entrypoints in
phase 5.

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
phase 2, made structurally impossible in phase 6.

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
comparison against a magic argument array. Repaired in phase 5, homed in
`ColliderSwiftPM` in phase 8.

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
phase 5 for command-to-recipe selection.

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
ColliderMacros ───────────────→ ColliderCore
ColliderPlanning ─────────────→ ColliderCore
ColliderPersistence ──────────→ ColliderCore
ColliderDownloads ────────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderPlanning
ColliderRuntime ──────────────→ ColliderPersistence
ColliderRuntime ──────────────→ ColliderDownloads
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

It contains no AOSP, Chromium, Android SDK, browser, Swift toolchain, React
Native, Vulkan, Wayland, compositor, or shell workflow type.

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

### `ColliderMacros`

`ColliderMacros` contains only macro implementation. The explicit protocols in
`ColliderCore` remain the source of truth. Macro expansion never performs
registration, filesystem discovery, or runtime initialization.

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

`ActionRequirements` contains tools and effect scopes intrinsic to the action.
The task declaration supplies environment, machine, policy, and scheduling
requirements.

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
- an action requirement not represented by the task declaration;
- an executable action left unhandled by a required planning lowering.

Actions never invoke other actions dynamically. Composition exists in the
declared graph. A generic sequence action is allowed only when all nested action
kinds and identities are encoded as the sequence action's static payload.

### Action identity

```swift
public protocol ActionIdentity: Sendable {
    func encode(into encoder: inout ActionIdentityEncoder)
}
```

The one canonical encoder:

- uses action-local positive numeric field tags;
- rejects duplicate, zero, and reserved tags;
- distinguishes scalar, optional, ordered repeated, sorted repeated, and nested
  values;
- normalizes strings and integer widths;
- never depends on dictionary or set iteration order;
- emits canonical bytes without choosing a hash algorithm.

Tags are action-local. There is no global tag space and no hand-maintained
allocation table shared across unrelated payloads.

Task identity contains:

1. task ID and component ID;
2. dependency identities keyed and sorted by dependency `TaskID`;
3. named declared inputs in canonical order;
4. typed output-slot contracts;
5. execution properties that can affect results, including the resolved
   execution environment and artifact target;
6. action kind;
7. action-local identity bytes;
8. task execution policy.

It excludes:

- task labels and source locations;
- entrypoint, facet, lane, and tag metadata;
- declaration order where order is not semantic;
- shared and exclusive scheduler claims;
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
    public let dependencies: Set<TaskID>
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
placement rule. A consumer accepting an `ArtifactReference` automatically gains:

- a dependency on its producer;
- a dependency-output identity input;
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
    public let mounts: Set<MountRequirement>
    public let tools: Set<ToolRequirement>
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
4. derive artifact dependencies;
5. validate the complete structural graph and action namespaces;
6. validate complete output ownership;
7. validate execution-contract placement across the complete graph;
8. expand command selection into component entrypoints;
9. compute selected dependency closure;
10. normalize execution and resource contracts for the selected closure;
11. request tool and container snapshots for the selected closure;
12. hash selected declared inputs through the persistent digest index;
13. calculate logical task identities in deterministic graph order;
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
- dependency identities;
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
- dependency identities;
- declared file, tree, value, environment, and artifact inputs;
- resolved host tools and binary digests;
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

## Macro Authoring Layer

Macros land only after explicit action and identity implementations have
stabilized.

`@ActionIdentity` synthesizes canonical encoding from explicitly tagged fields:

```swift
@ActionIdentity
public struct CompileProductIdentity {
    @IdentityField(1) let source: ArtifactReference<DirectoryArtifact>
    @IdentityField(2) let product: String
    @IdentityField(3) let release: String
    @IdentityField(4) let overlays: [SourceOverlay]
}
```

It diagnoses:

- duplicate, zero, and reserved tags;
- unsupported types;
- an unencoded stored property;
- implicit set or dictionary ordering;
- invalid ordering annotations;
- non-sendable identity fields.

`@ColliderAction` may synthesize conformance, kind, and type erasure. It does
not synthesize global registration, persistence behavior, test fixtures, or
identity-bearing source locations.

`@ColliderComponent` may synthesize descriptor boilerplate. The explicit root
component list remains mandatory.

Every macro has expansion tests and an equivalent handwritten conformance test.
Collider's clean build must demonstrate that macro dependencies do not
materially regress its bootstrap path.

## Sequential Implementation Plan

## Phase 1 — Freeze the invariants and close the exhaustiveness escapes

Delete the `default:` clause from every switch over a closed Collider enum and
enumerate the remaining cases: `scheduledResources`, `containsOCIExecution`,
`validateArtifactOutputs`, `operationEnvironment`, and `executionCoordinates`.
Replace the five-case AOSP product family, which re-discriminates one shared
payload back into a stage string inside `encode(operation:into:)`, with one case
carrying an explicit stage value. From this phase forward the compiler
enumerates the conversion surface for phase 4.

Add `PathValidation.symlinkTarget`, which resolves the link and validates the
target, and convert every symlink-publishing output declaration to it.

Add regression coverage before moving engine boundaries:

1. assert that dirty logical Swift requirements sharing one host context produce
   exactly one root build;
2. assert that any dirty test requirement produces one root test and no
   preceding root build;
3. assert that incompatible Swift contexts produce separate invocations and
   scratch locks;
4. assert that unselected DRM, Android, and container tasks do not trigger tool
   resolution or hardware probes;
5. assert that complete graph reporting remains deterministic;
6. assert that a publication task whose symlink target is absent fails output
   validation;
7. assert that every task selected by every public CLI spelling declares an
   execution environment its artifact target can be produced in;
8. record planning duration, selected input-hashing duration, invocation count,
   and critical-path execution duration as the baseline.

The existing synthesized SwiftPM behavior remains the enforced reference while
the later planner is extracted.

### Verification gate

Collider command and engine tests pass. No switch over a Collider enum contains
`default:`. A dry-run of the complete build reports one root Swift invocation for
the ordinary host context. A dry-run of complete tests reports one root test and
no redundant root build. Assertion 7 fails against the current tree and names
the benchmark, sanitizer, and release-gate workloads; phase 2 makes it pass.

## Phase 2 — Close the host/target execution split

This phase repairs live incorrect behavior and establishes the placement rule
the rest of the architecture depends on.

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
   shelling with them. Phase 5 gives these tasks their own `test.release-gate`
   entrypoint; phase 2 only moves them into the graph and the container.

Move code generation that shapes committed source into the container. The
`wayland.generate` scanner steps execute against the pinned scanner produced by
`wayland.native-sdk.linux-arm64` rather than an ambient `PATH` lookup.
`SwiftWaylandGen` and `VulkanGen` remain first-party host Swift tools producing
portable output and are unchanged.

Remove ambient host tools from target task identity. `core.sources` keeps host
`git` and `python3` for source materialization only and declares no artifact
target; its `unzip` and `chmod` steps become engine operations so the extracted
Linux `gn` never depends on the runner's coreutils. `rn.generate` and
`rn.javascript-dependencies` resolve `node` and `corepack` from the pinned
container image, which also makes `node_modules` target-shaped rather than
runner-shaped.

Add `wayland-scanner` and the per-target native SDK paths to `WorkspaceDoctor`,
and delete its private `nativeSDKRoot` duplicate in favor of the single
workspace accessor.

Register `Benchmark` and `Sanitize` with the same platform gating as their
execution contract requires, so no subcommand is offered that cannot run.

### Verification gate

Phase 1 assertion 7 passes. `collider test`, `collider benchmark`, and
`collider sanitize` complete on an arm64 macOS runner and produce artifacts
byte-identical to a Linux runner for every container-executed task. No task
declaring an artifact target resolves an ambient host tool. `collider doctor`
fails on a machine missing any prerequisite that a selected entrypoint needs.
Regenerating the Wayland protocol sources on macOS and on Linux produces
identical committed output. Every path under the native SDK root has exactly one
producing task, and deleting any of them fails validation rather than reporting
success.

## Phase 3 — Normalize the declaration surface

The layer that later phases rewrite must first speak one path type, one
workspace context, and one task-identifier vocabulary.

Change `WorkspaceLayout` to vend `FilePath` and fix every consumer. `URL`
remains only at Foundation call sites that require it.

Collapse duplicated resolution to one implementation each: the cache root, the
native SDK root, and the workspace-relative path resolver defined twice in
`ColliderCommand.swift`. Remove the force-unwrapped environment read by making
the invariant explicit at the type instead of at the use site.

Give every recipe module public `TaskID` constants for the tasks other modules
reference, and replace recipe-to-recipe string literals with them. Command-layer
selection remains string-driven until phase 5 replaces it with entrypoints.

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

## Phase 4 — Complete the action seam

`ColliderAction`, `ColliderActionIdentity`, `AnyColliderAction`, `ActionContext`,
`ActionFileSystem`, and `CanonicalDigestEncoder` already exist in
`ColliderCore`. Complete them with:

- `ActionKind`;
- `ActionRequirements`;
- `ActionIdentityEncoder` with action-local tags and duplicate/zero/reserved
  rejection;
- cancellation, logger, filesystem, command, and download capability protocols;
- the canonical replacement identity encoding.

Convert operations in strict order:

1. command and process actions;
2. create, copy, write, remove, and symlink actions;
3. download and archive actions, including the extraction step that replaced
   host `unzip` in phase 2;
4. generation activation, retention, and publication actions;
5. Swift source, host toolchain, Android SDK, wiring, sanitation, and validation
   actions;
6. AOSP source, container, signing, compile, assemble, validate, and publication
   actions;
7. Chromium/depot_tools source, build, CEF, browser, validation, installation,
   and publication actions;
8. remaining core Android-host and qualification actions.

Each converted workflow moves immediately to its owning recipe module under:

```text
collider/Sources/<Component>ColliderRecipe/Actions/
```

Its behavioral tests and fixtures move with it. The corresponding enum cases,
runtime methods, payload types, and switch branches are deleted in the same
step. Recipe modules import `ColliderCore`, never `ColliderRuntime`.

There is no general `LegacyTaskOperationAction`, compatibility encoder, or
permanent dual dispatch. After the final conversion:

- delete `TaskOperation` and the hand-allocated global digest tag space;
- remove operation dispatch from `ColliderRuntime`;
- remove every domain workflow file from `ColliderRuntime`;
- change `TaskDeclaration` to store `AnyColliderAction`;
- validate the exact legacy task-state and cache roots against Collider's
  derived-state safety root;
- delete those legacy roots once before executing the new identity encoding;
- create the one canonical empty state layout.

### Verification gate

All recipe actions execute through `ActionContext`. Identical action identities
produce identical bytes; changing each identity-bearing field changes the
digest. Duplicate kinds, invalid namespaces, and duplicate identity tags fail
validation. A clean second run performs no work. No domain term remains in
engine source. No identity version, compatibility decoder, or legacy state
remains. Task identity for a container-executed task is independent of runner
operating system.

## Phase 5 — Unify components and command entrypoints

Add `ColliderComponent`, `ComponentDescriptor`, `ComponentDefinition`,
`ComponentEntrypoint`, `RecipeContext`, and immutable task collection builders
to `ColliderCore`.

Convert every recipe module to one `makeComponent(in:)` implementation. Move all
build, test, bootstrap, generate, install, benchmark, sanitizer, and
qualification declarations into that graph. Define named entrypoints rather than
separate recipe methods. The benchmark and sanitizer workloads relocated in
phase 2 become `benchmark` and `sanitize.*` entrypoints, and the release
structural suites become `test.release-gate`; `BenchmarkCommand` and
`SanitizerCommand` are deleted along with the last `context.run` call sites that
drive a build system.

Introduce the one shared Swift package task builder and delete the six
near-identical private recipe helpers, including every
`arguments == ["build"]` sentinel. Build versus test is an explicit declaration.

Replace:

- `ComponentSelection`;
- per-command recipe calls;
- command-owned task reconstruction;
- hard-coded component path switches;
- the remaining command-layer `TaskID` string derivation.

Create one explicit root component list and registry-owned selection groups in
`ColliderCommands`. Commands parse component/group/entrypoint arguments and
perform generic selection only.

Graph construction remains pure. Move DRM-node discovery, lavapipe resolution,
container inspection, and tool discovery into selected planning requirements.

### Verification gate

Every accepted CLI spelling resolves through registry metadata. Frozen public
CLI tables preserve intended aliases. Expanding all component graphs produces
no duplicate IDs, aliases, kinds, entrypoints, or output ownership, and no
unreachable entrypoint. Building an unrelated component does not probe optional
hardware. No command in `ColliderCommands` launches a build system, test runner,
benchmark, or sanitizer outside a planned action. One recipe declares a Swift
package build and test in fewer lines than the deleted helper, and no recipe
restates the shared shape.

## Phase 6 — Introduce typed artifacts and scoped effects

Add artifact marker types, `ArtifactReference`, output slots,
`ResolvedArtifact`, declared path references, and scoped tree capabilities.

Migrate producer-consumer relationships in strict order:

1. generated metadata and JSON reports;
2. downloaded archives and extracted directories;
3. generated source directories;
4. host tools and executable products;
5. native SDKs and static archives;
6. toolchain and Android SDK generations;
7. AOSP and Chromium publication generations.

For each relationship:

- replace the repeated raw path with a typed reference;
- derive the dependency edge;
- add output type and ownership validation;
- resolve host/container placement only in planning;
- delete the redundant manual dependency-output input.

The native SDK publication slots repaired in phase 2 become typed artifacts,
which makes a slot without a producing task unrepresentable rather than merely
tested against.

Add scoped checkout, scratch, output, and publication capabilities for large
external build systems. Record every granted scope in the run manifest.

Change command arguments, working directories, and environment path values to
typed references. Confine remaining shell use to `Command.unsafeShell` and mark
those tasks non-portable.

After migration, make consumption of a known generated output through an
unrelated raw path a planner error.

### Verification gate

Planner tests prove automatic dependency derivation, type mismatch rejection,
host/container path mapping, output overlap detection, and placement-independent
artifact identity. A publication slot with no producer fails to compile.
Representative AOSP, Chromium, SwiftPM, and publication actions operate only
within declared scopes.

## Phase 7 — Extract deterministic planning and persistence

Create `ColliderPlanning` and move graph normalization, selection, identity,
assessment, execution-contract placement validation, output ownership, and plan
construction out of `TaskEngine`.

Define immutable planning service protocols in `ColliderCore`. Create
`ColliderPersistence` and move:

- artifact hashing;
- persistent digest metadata;
- task state;
- run manifests;
- atomic durable files;
- artifact snapshot records;
- artifact and generation retention.

Planning receives immutable snapshots and request/response service values.
Execution receives an `ExecutionPlan`; it cannot access planner mutation APIs.

Delete the planning and assessment coordinator from `TaskEngine`. Keep only a
thin runtime orchestration entrypoint that obtains planning snapshots, invokes
the planner, and hands the frozen plan to execution.

### Verification gate

The same declarations and planning snapshots produce byte-identical plans.
Unselected trees are not hashed, unselected tools are not resolved, and
unselected hardware is not probed. Execution cannot mutate task identities or
add tasks. Persistence tests cover interrupted writes, corrupt state, and
bounded artifact retention.

## Phase 8 — Move SwiftPM aggregation into explicit plan lowering

Create `ColliderSwiftPM` with logical build/test requirement declarations, the
shared Swift package task builder introduced in phase 5, and one deterministic
lowering. Register it explicitly in the command-layer planner configuration.

Move the existing synthesized-build behavior out of runtime execution and into
the lowering. Preserve:

- complete `SwiftBuildContext` grouping;
- one root package invocation;
- shared context scratch paths and locks;
- test-over-build subsumption;
- expected output validation;
- logical component attribution;
- stock SwiftPM command arguments;
- execution environment derived from the build context, never the runner.

Delete synthesized Swift planning from `ColliderRuntime`. Runtime sees ordinary
physical execution tasks and attribution metadata only.

### Verification gate

The phase 1 invocation-count tests pass unchanged against the new planner.
Editing one component may dirty multiple logical dependents but still produces
one SwiftPM process for their compatible context. Root build and root test pass
with the stock patch-free toolchain. Benchmark, sanitizer, release-gate, and
lane contexts all lower to container invocations without special-casing.

## Phase 9 — Complete the resource-aware scheduler

The bounded ready queue, weighted CPU and memory admission, exclusive claims,
and lock-disjointness checks already exist in `TaskEngine`. Move them into
`ColliderRuntime`'s scheduler over the frozen plan and complete them.

Implement the missing pieces:

- canonical output-tree reservation;
- atomic reservation of all in-process claims in canonical key order;
- explicit resource requests for every task class, replacing the lightweight
  default the deleted `default:` clause used to supply;
- bounded I/O-heavy slots;
- execution-session tracking and container cleanup on cancellation;
- failure propagation that never publishes state after failure;
- stable final reporting;
- critical-path and resource-wait measurements.

The root SwiftPM task reserves its scratch database exclusively and receives a
high CPU weight. AOSP, Chromium, native SDK, download, and publication tasks
declare their real checkout, cache, memory, I/O, container, and output
constraints.

First execute all acceptance suites with scheduler capacity one. Then enable the
production capacity policy.

### Verification gate

Capacity-one and concurrent executions select the same tasks and produce
artifact-equivalent outputs. Stress tests show no overlapping output mutation,
lock-order deadlock, leaked process group, leaked container session, or state
publication after failure. Every task class declares a resource request. Logs
remain task-local and final reports remain stable.

## Phase 10 — Add macro authoring support

Create the macro implementation target and public declarations. Add
`@ActionIdentity`, `@IdentityField`, `@ColliderAction`, and
`@ColliderComponent` without changing the underlying runtime contracts.

Convert repetitive identities and descriptors after expansion tests cover every
diagnostic. Retain handwritten examples as conformance fixtures. Do not add
registration or reflection.

### Verification gate

Macro-generated and handwritten identities produce identical canonical bytes.
Diagnostics cover tag, type, ordering, and omitted-field mistakes. Collider's
bootstrap build remains within the recorded compile and dependency budget.

## Phase 11 — Add audited portable caching

Rename existing policy cases to `always`, `incremental`, and `portable`. Migrate
all current reusable work to `incremental`; this rename grants no portable
capability.

Implement verified portable snapshots, restoration, quarantine, and bounded
artifact retention in `ColliderPersistence`.

Audit and promote bounded actions in strict order:

1. generated text, JSON, and metadata;
2. downloaded content-addressed files;
3. deterministic generated sources;
4. bounded native archives and host tools;
5. other relocatable outputs proven complete by behavioral replay.

Keep SwiftPM scratch trees, mutable source checkouts, AOSP build trees, Chromium
build trees, hardware qualification, and unrestricted shell/network workflows
non-portable unless a later complete audit proves otherwise. A task whose
identity contains an ambient host tool is never promoted.

### Verification gate

Deleting a portable local output and restoring it reproduces the complete
validated tree, metadata, permissions, and symlinks. Corrupt snapshots are
quarantined and rebuilt. Relocation tests prove that absolute checkout paths are
not artifact identity. A macOS runner and a Linux runner exchange portable
artifacts for every container-executed task.

## Phase 12 — Remove superseded architecture and validate the end state

Delete:

- obsolete operation payloads and digest encoders;
- component-specific runtime extensions;
- command-specific graph construction;
- duplicate component identity types;
- duplicate path and cache-root resolution;
- raw generated-output path dependencies;
- serial and pre-plan execution code;
- temporary migration diagnostics and adapters.

Run the complete acceptance matrix:

1. Collider engine, macro, persistence, planning, runtime, recipe, and command
   tests;
2. root host build and complete root tests;
3. Android manifest resolution and supported cross-compilation checks;
4. toolchain, AOSP, Chromium, native SDK, and publication behavioral suites;
5. capacity-one and production-capacity scheduler replays;
6. clean second-run verification for every component entrypoint;
7. portable restore and corruption tests;
8. macOS-runner and Linux-runner equivalence for every container-executed
   entrypoint;
9. SourceKit-LSP configuration and semantic checks;
10. planning, hashing, invocation-count, resource-wait, and critical-path
    comparison against the phase 1 baseline.

The architecture is complete only when:

- no engine target contains component-specific workflow terminology;
- a component workflow change touches only its recipe and generic contract
  extensions;
- commands select entrypoints without reconstructing task arrays;
- no command drives a build system outside a planned action;
- execution accepts only immutable plans;
- one compatible Swift context produces one root SwiftPM invocation;
- a task's execution environment follows its declared target, never its runner;
- no task producing a target artifact depends on an ambient host tool;
- generated artifacts flow through typed producer/output references;
- every published path has exactly one producing task;
- every mutable effect is scoped and recorded;
- concurrency is safe across tasks and Collider processes;
- portable restoration is content-verified and explicitly audited.

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
- portable caching claims for opaque external build trees.

Collider remains a compiled, explicit, deterministic Nucleus meta-build system:

```text
recipes own declarations and actions
commands select component entrypoints
planning validates, assesses, places, and lowers
runtime schedules and executes
persistence records and restores
```
