# Collider Kernel, Planning, and Execution Architecture

**Status: active.** This is the sole authority for Collider graph declaration,
planning, execution, persistence, caching, output ownership, input auditing, and
resource-aware scheduling.

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
- Collider synthesizes one stock Swift build or test per compatible context;
- `SwiftBuildContext` separates incompatible toolchain, target, sanitizer,
  trait, flag, and standard-library configurations;
- recipe targets live under `collider/Sources`;
- `TaskGraph` validates dependencies and returns deterministic topological
  order;
- declared inputs, outputs, postconditions, task locks, state records, run
  records, and artifact digests already exist;
- cross-process file locks already protect shared mutable state.

The remaining architectural debt is concentrated in four places:

1. `TaskOperation` is a closed enum containing generic and domain-specific
   behavior.
2. `ColliderRuntime` is both the execution implementation and a namespace for
   AOSP, Chromium, Android SDK, browser, and toolchain workflows.
3. `ComponentRegistry` reconstructs different task arrays for each command and
   owns component-specific selection behavior.
4. planning, state assessment, synthesized SwiftPM execution, and serial
   execution remain coupled inside `TaskEngine`.

## Target Package Graph

The final engine package exposes six products with one-way dependencies:

```text
ColliderMacros ───────────────→ ColliderCore
ColliderPlanning ─────────────→ ColliderCore
ColliderPersistence ──────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderCore
ColliderRuntime ──────────────→ ColliderPlanning
ColliderRuntime ──────────────→ ColliderPersistence
ColliderTesting ──────────────→ ColliderCore
ColliderTesting ──────────────→ ColliderPlanning
```

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
- execution-contract validation;
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
- downloads;
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

Task identity contains:

1. task ID and component ID;
2. dependency identities keyed and sorted by dependency `TaskID`;
3. named declared inputs in canonical order;
4. typed output-slot contracts;
5. execution properties that can affect results;
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
- absolute resolved output paths for portable artifacts.

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
bootstrap
generate
install
qualify
```

A task may be reachable from any number of entrypoints. `TaskMetadata` may carry
facets, lanes, and tags for reporting and ad hoc filtering, but those labels do
not duplicate tasks or determine identity.

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
- overlapping output ownership.

`RecipeContext` contains declared repository layout and build-context values. It
does not inspect hardware, resolve tools, hash trees, or execute commands.

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
7. expand command selection into component entrypoints;
8. compute selected dependency closure;
9. normalize execution and resource contracts for the selected closure;
10. request tool and container snapshots for the selected closure;
11. hash selected declared inputs through the persistent digest index;
12. calculate logical task identities in deterministic graph order;
13. assess logical local state and output postconditions;
14. run registered deterministic lowerings, including SwiftPM coalescing;
15. calculate identities and assessments for synthesized execution tasks;
16. freeze output ownership, resource indexes, attribution, and reporting order;
17. produce the immutable `ExecutionPlan`.

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

## Phase 1 — Freeze the production invariants

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
6. record planning duration, selected input-hashing duration, invocation count,
   and critical-path execution duration as the baseline.

The existing synthesized SwiftPM behavior remains the enforced reference while
the later planner is extracted.

### Verification gate

Collider command and engine tests pass. A dry-run of the complete build reports
one root Swift invocation for the ordinary host context. A dry-run of complete
tests reports one root test and no redundant root build.

## Phase 2 — Replace `TaskOperation` with the action seam

Create in `ColliderCore`:

- `ActionKind`;
- `ActionIdentity`;
- `ActionIdentityEncoder`;
- `ColliderAction`;
- `AnyColliderAction`;
- `ActionRequirements`;
- `ActionContext`;
- cancellation, logger, filesystem, command, and download capability protocols;
- the canonical replacement identity encoding.

Convert operations in strict order:

1. command and process actions;
2. create, copy, write, remove, and symlink actions;
3. download and archive actions;
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

- delete `TaskOperation`;
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
digest. Duplicate kinds and invalid namespaces fail graph validation. A clean
second run performs no work. No domain term remains in engine source. No
identity version, compatibility decoder, or legacy state remains.

## Phase 3 — Unify components and command entrypoints

Add `ColliderComponent`, `ComponentDescriptor`, `ComponentDefinition`,
`ComponentEntrypoint`, `RecipeContext`, and immutable task collection builders
to `ColliderCore`.

Convert every recipe module to one `makeComponent(in:)` implementation. Move all
build, test, bootstrap, generate, install, and qualification declarations into
that graph. Define named entrypoints rather than separate recipe methods.

Replace:

- `ComponentSelection`;
- `WorkspaceComponent`;
- per-command recipe calls;
- command-owned task reconstruction;
- hard-coded component path switches.

Create one explicit root component list and registry-owned selection groups in
`ColliderCommands`. Commands parse component/group/entrypoint arguments and
perform generic selection only.

Graph construction remains pure. Move DRM-node discovery, lavapipe resolution,
container inspection, and tool discovery into selected planning requirements.

### Verification gate

Every accepted CLI spelling resolves through registry metadata. Frozen public
CLI tables preserve intended aliases. Expanding all component graphs produces
no duplicate IDs, aliases, kinds, entrypoints, or output ownership. Building an
unrelated component does not probe optional hardware.

## Phase 4 — Introduce typed artifacts and scoped effects

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
artifact identity. Representative AOSP, Chromium, SwiftPM, and publication
actions operate only within declared scopes.

## Phase 5 — Extract deterministic planning and persistence

Create `ColliderPlanning` and move graph normalization, selection, identity,
assessment, output ownership, and plan construction out of `TaskEngine`.

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

Delete the serial planning/execution coordinator from `TaskEngine`. Keep only a
thin runtime orchestration entrypoint that obtains planning snapshots, invokes
the planner, and hands the frozen plan to execution.

### Verification gate

The same declarations and planning snapshots produce byte-identical plans.
Unselected trees are not hashed, unselected tools are not resolved, and
unselected hardware is not probed. Execution cannot mutate task identities or
add tasks. Persistence tests cover interrupted writes, corrupt state, and
bounded artifact retention.

## Phase 6 — Move SwiftPM aggregation into explicit plan lowering

Create `ColliderSwiftPM` with logical build/test requirement declarations and
one deterministic lowering. Register it explicitly in the command-layer planner
configuration.

Move the existing synthesized-build behavior out of runtime execution and into
the lowering. Preserve:

- complete `SwiftBuildContext` grouping;
- one root package invocation;
- shared context scratch paths and locks;
- test-over-build subsumption;
- expected output validation;
- logical component attribution;
- stock SwiftPM command arguments.

Delete synthesized Swift planning from `ColliderRuntime`. Runtime sees ordinary
physical execution tasks and attribution metadata only.

### Verification gate

The Phase 1 invocation-count tests pass unchanged against the new planner.
Editing one component may dirty multiple logical dependents but still produces
one SwiftPM process for their compatible context. Root build and root test pass
with the stock patch-free toolchain.

## Phase 7 — Add the resource-aware scheduler

Replace serial task execution with a bounded ready queue.

Implement:

- dependency counters and dependent indexes;
- stable ready ordering;
- weighted CPU, memory, and I/O admission;
- atomic shared/exclusive resource reservation;
- canonical output-tree reservation;
- cancellation-aware cross-process locks;
- execution-session tracking;
- failure propagation and cleanup;
- stable final reporting;
- critical-path and resource-wait measurements.

Assign explicit resource requests to every task class. The root SwiftPM task
reserves its scratch database exclusively and receives a high CPU weight.
AOSP, Chromium, native SDK, downloads, and publication tasks declare their real
checkout, cache, memory, I/O, container, and output constraints.

First execute all acceptance suites with scheduler capacity one. Then enable the
production capacity policy.

### Verification gate

Capacity-one and concurrent executions select the same tasks and produce
artifact-equivalent outputs. Stress tests show no overlapping output mutation,
lock-order deadlock, leaked process group, leaked container session, or state
publication after failure. Logs remain task-local and final reports remain
stable.

## Phase 8 — Add macro authoring support

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

## Phase 9 — Add audited portable caching

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
non-portable unless a later complete audit proves otherwise.

### Verification gate

Deleting a portable local output and restoring it reproduces the complete
validated tree, metadata, permissions, and symlinks. Corrupt snapshots are
quarantined and rebuilt. Relocation tests prove that absolute checkout paths are
not artifact identity.

## Phase 10 — Remove superseded architecture and validate the end state

Delete:

- obsolete operation payloads and digest encoders;
- component-specific runtime extensions;
- command-specific graph construction;
- duplicate component identity types;
- raw generated-output path dependencies;
- serial executor code;
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
8. SourceKit-LSP configuration and semantic checks;
9. planning, hashing, invocation-count, resource-wait, and critical-path
   comparison against the Phase 1 baseline.

The architecture is complete only when:

- no engine target contains component-specific workflow terminology;
- a component workflow change touches only its recipe and generic contract
  extensions;
- commands select entrypoints without reconstructing task arrays;
- execution accepts only immutable plans;
- one compatible Swift context produces one root SwiftPM invocation;
- generated artifacts flow through typed producer/output references;
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
- portable caching claims for opaque external build trees.

Collider remains a compiled, explicit, deterministic Nucleus meta-build system:

```text
recipes own declarations and actions
commands select component entrypoints
planning validates, assesses, and lowers
runtime schedules and executes
persistence records and restores
```
