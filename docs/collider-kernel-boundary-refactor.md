# Collider Kernel Boundary Refactor

## Invariant

The Collider kernel owns execution, artifact identity, caching, locking, and
scheduling. It knows nothing about AOSP, Chromium, Skia, Hermes, the Swift
toolchain, or Vulkan. Domain build logic lives in the package that owns the
artifact being built and reaches the kernel through a single protocol seam that
carries opaque handles and scalars. Adding a component means writing a recipe in
that component's package and registering it in one list; it never means editing
the kernel.

## Current State

`TaskOperation` in `collider/engine/Sources/ColliderCore/TaskGraph.swift:877`
declares 44 cases. Fifteen are generic filesystem or process primitives. The
other 29 name specific consumers: `compileAOSPProduct`, `prepareChromiumSource`,
`assembleAndroidSDK`, `installBrowser`, `assembleCEFArtifact`,
`validateHostToolchain`. The kernel enumerates its clients, and three structural
problems follow from that single inversion.

**The runtime is a god actor.** `ColliderRuntime` is one `actor`
(`collider/engine/Sources/ColliderRuntime/ColliderRuntime.swift:24`) carrying
roughly 10k lines of `extension ColliderRuntime` across `AOSPProductWorkflow`,
`AOSPSourceWorkflow`, `AndroidSDKWorkflow`, `HostToolchainWorkflow`,
`ChromiumSourceWorkflow`, and six more files. The extensions exist because the
`perform` switch at `TaskEngine.swift:834` must dispatch to methods on `self`.
Every operation body therefore shares one isolation domain and one mutable state
bag (`toolIdentityCache`, `taskOutputPresentation`).

**Execution is serial.** `TaskEngine.swift:113` walks the topological order in a
plain `for` loop. It cannot do otherwise: every operation body is isolated to the
single `ColliderRuntime` actor. The `TaskGroup` uses elsewhere in the engine
handle process-I/O streaming and concurrent downloads, not task scheduling. The
lock machinery at `TaskEngine.swift:1371` and the deadlock-avoiding total order
in `lockOrdering` at `TaskEngine.swift:1399` are effectively vestigial.

**The digest tag space is a global registry.** `encode(operation:into:)` assigns
canonical tags from one flat integer space — `65`–`70` for git patch
application, `183`–`184` for AOSP source specifications, `89` for cache policy.
Every domain operation claims numbers the kernel hands out. A collision silently
corrupts task identity rather than failing.

**Recipes drifted because nothing constrains their shape.** There is no recipe
protocol. `ReactNativeColliderRecipe` exposes 13 public statics,
`CoreColliderRecipe` 8, `CompositorColliderRecipe` 8 including
`testHeadlessGPU`/`preflightHeadlessGPU`/`testDRMGPU`/`preflightDRMGPU`, and
`LinuxColliderRecipe` 2. Signatures diverge: `build(root:environment:)` against
`tasks(root:repositoryRoot:environment:)` against
`aospImageTasks(root:environment:)`. `ComponentRegistry.buildTasks()`
hand-assembles all of them with a bespoke call per recipe.

**Component identity is triplicated.** `ComponentID` in `ColliderCore`,
`ComponentSelection` with 17 cases in
`collider/Sources/ColliderCommands/ComponentRegistry.swift:17`, and
`WorkspaceComponent` with 8 cases in
`collider/Sources/ColliderCommands/Orchestrator.swift:5`, plus roughly 20
hand-written per-component path properties in `WorkspaceLayout`. Introducing a
component touches five files, none of which belong to the component.

## Phase 1 — Replace the operation enum with an action protocol

`TaskOperation` is deleted. `ColliderCore` gains:

```swift
public protocol TaskAction: Sendable {
    /// Stable identity for digests and state records, namespaced by owning
    /// component. Never renamed after a task ships; renaming invalidates every
    /// cached identity that used it.
    static var kind: ActionKind { get }

    /// Environment consulted when the engine resolves declared tool identity.
    var toolEnvironment: [String: String] { get }

    func encode(into encoder: inout ActionDigestEncoder)
    func run(_ context: ActionContext) async throws
}
```

`ActionKind` is a component-namespaced string (`"aosp.compile-product"`,
`"toolchain.assemble"`). `ActionDigestEncoder` wraps `CanonicalDigestEncoder` and
prefixes every append with the action's `kind`, so tag numbers become local to an
action instead of global. This closes the collision hazard permanently.

`ActionContext` is the complete capability surface an action may touch:

```swift
public struct ActionContext: Sendable {
    public let stage: TaskID
    public let outputs: [OutputDeclaration]
    public let options: TaskExecutionOptions
    public let cancellation: RuntimeCancellation

    public func execute(_ command: CommandSpec) async throws -> CommandResult
    public func download(_ spec: DownloadSpec, to candidate: FilePath) async throws
    public func log(_ bytes: [UInt8]) async throws
    public func perform(_ action: some TaskAction) async throws
}
```

`perform` is what lets composite actions delegate to primitives the way
`configureMeson` and `mergeStaticArchives` currently recurse into
`perform(.command(...))`.

Fifteen actions stay in the kernel as concrete types, because they carry no
domain knowledge: `RunCommand`, `Sequence`, `CreateDirectory`, `CopyFile`,
`CopyMatchingFile`, `MergeStaticArchives`, `RemovePath`, `ReplaceSymlink`,
`WriteFile`, `ApplyGitPatch`, `Download`, `PublishSymlink`, `PublishDirectory`,
`PruneDirectories`, `ActivateGeneration`.

`TaskDeclaration.operation` becomes `any TaskAction`. `TaskDeclaration` loses its
`Hashable` conformance derived through the operation and gains an explicit one
keyed on `id`; identity for caching flows through `encode` alone, which is
already the case in practice.

`identity(of:)` at `TaskEngine.swift:173` stops calling
`operationEnvironment(task.operation)` and reads `action.toolEnvironment`. The
`encode(operation:into:)` cascade and the `perform` switch are both deleted.

Files touched: `ColliderCore/TaskGraph.swift`, `ColliderCore/Model.swift`,
`ColliderRuntime/TaskEngine.swift`, and every recipe's operation construction
sites.

**Verification gate.** A differential test replays every `TaskStateRecord`
present in a populated state root through the new encoder and asserts byte
equality of the resulting `ArtifactDigest` for the fifteen retained primitives.
This gate lands before any other phase-1 work merges into the engine. Without
it, an encoding slip either invalidates every cached task in every checkout or,
worse, validates a task whose inputs changed.

## Phase 2 — Dissolve the runtime actor and relocate the workflows

With `run` on the action, `extension ColliderRuntime` has no reason to exist.
The 29 domain operations become action types in their owning packages. Ownership
is determined by the recipe that constructs them today, not by subject matter —
several Android-named operations belong to `swift-toolchain`, which builds the
Android SDK sysroot for Swift.

| Destination | Actions |
|---|---|
| `swift-toolchain/Sources/SwiftPlatformColliderRecipe` | `prepareSwiftSource`, `prepareHostToolchainBuild`, `assembleHostToolchain`, `validateHostToolchain`, `assembleAndroidSDK`, `wireAndroidSDK`, `validateAndroidSDK`, `validateAndroidRuntimeLinkage`, `sanitizeLinkMetadata` |
| `android-runtime/Sources/AndroidRuntimeColliderRecipe` | `verifyAOSPSourceLock`, `prepareAOSPSource`, `prepareAOSPBuildContainer`, `prepareAOSPSigningIdentity`, `compileAOSPProduct`, `signAOSPProduct`, `assembleAOSPProductImages`, `validateAOSPProduct`, `publishAOSPProduct`, `configureMeson` |
| `chromium/Sources/ChromiumColliderRecipe` | `prepareChromiumDepotTools`, `prepareChromiumSource`, `buildChromiumProduct`, `assembleBrowserArtifact`, `validateBrowserArtifact`, `assembleCEFArtifact`, `validateCEFArtifact`, `installBrowser`, `validateAptPackages` |
| `core/Sources/CoreColliderRecipe` | `validateAndroidHost` |

`configureMeson` and `validateAptPackages` move to their sole consumers rather
than staying kernel-side; neither is used twice, and both encode assumptions
about a specific dependency toolchain.

Workflow implementation files move with their actions. `AOSPProductWorkflow.swift`
(1601 lines), `AOSPSourceWorkflow.swift` (1117), `AndroidBPFDelegation.swift`,
and `AndroidApexMount.swift` leave `collider/engine` for `android-runtime`.
`ChromiumSourceWorkflow.swift`, `ChromiumProductWorkflow.swift`,
`BrowserArtifactWorkflow.swift`, `CEFArtifactWorkflow.swift`, and
`BrowserInstallationWorkflow.swift` go to `chromium`. `HostToolchainWorkflow.swift`
and `AndroidSDKWorkflow.swift` go to `swift-toolchain`. `ManagedSourceWorkflow.swift`
follows `prepareSwiftSource`.

The recipe packages gain a dependency on `ColliderCore` only. They must not
depend on `ColliderRuntime`; every capability they need arrives through
`ActionContext`. If an action needs something `ActionContext` does not expose,
the correct move is to widen `ActionContext` with a generic capability, not to
import the runtime.

`ColliderRuntime` retains process execution, downloads, the run registry,
cancellation, file locks, pseudo-terminal logging, `DurableFile`,
`GenerationPublisher`, `DirectoryLifecycle`, and `ArtifactHasher` — roughly 1.5k
lines. It becomes the provider behind `ActionContext` and stops being a
namespace.

`collider/engine` stops accumulating every component's build logic, which brings
it in line with the ownership model the rest of the monorepo already follows.

The action bodies themselves are unchanged in this phase. Only their host type,
module, and access level change.

**Verification gate.** `collider test all` passes, and
`collider build android-runtime`, `collider bootstrap browser`, and
`collider toolchain rebuild` each replay to a fully clean plan on a warm state
root — proving no identity shifted during relocation.

## Phase 3 — One component protocol, one component identity

`ColliderCore` gains the recipe seam:

```swift
public protocol ColliderComponent: Sendable {
    static var id: ComponentID { get }
    static var directoryName: String { get }
    static func tasks(_ context: RecipeContext) throws -> [TaskDeclaration]
}
```

`RecipeContext` carries the component's resolved root, the repository root, and
the task environment — the union of what recipes take as ad hoc parameters
today.

Lane and stage variation moves onto the declaration rather than the recipe's
method list. `TaskDeclaration` gains:

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

`CompositorColliderRecipe.testHeadlessGPU` and `preflightHeadlessGPU` become two
declarations tagged `.test(lane: "gpu-headless")` and
`.qualify(lane: "gpu-headless")`, both returned from the single `tasks` entry
point. The same collapse applies to `ReactNativeColliderRecipe`'s 13 statics and
`CoreColliderRecipe`'s 8.

`ComponentRegistry` then reduces to a registered component list plus filtering:

```swift
private static let components: [any ColliderComponent.Type] = [
    TracyColliderRecipe.self, VulkanColliderRecipe.self, /* ... */
]
```

`buildTasks()`, `testTasks(selection:)`, and their siblings become facet filters
over one flattened task list instead of hand-assembly.

`WorkspaceComponent` in `Orchestrator.swift` is deleted; `Orchestrator` reads
`directoryName` off the registered components. `ComponentSelection` is derived
from registered `ComponentID`s rather than hand-maintained. `WorkspaceLayout`'s
per-component properties collapse to `layout.directory(for: ComponentID)`;
the non-component paths (`state`, `runs`, `locks`, `work`, `installPrefix`)
stay as they are.

**Constraint.** `ComponentSelection` raw values are a public CLI surface
consumed by `collider-setup.sh` and by muscle memory. The derived selection must
preserve every existing spelling, including the abbreviations `rn`,
`android-runtime`, `gpu-headless`, and `gpu-drm`.

**Verification gate.** `collider build <component>` and `collider test
<component>` resolve for every previously accepted selection string, and
`ComponentRegistryTests` covers the derived selection set against a frozen list
of accepted spellings.

## Phase 4 — Parallel scheduling

Reachable only after phase 2, because until the actions leave `ColliderRuntime`
every operation body is isolated to one actor.

`TaskEngine.execute` keeps its existing two-pass shape: compute identities and
assessments for the full ordered set, then execute. The execution pass changes
from the serial loop at `TaskEngine.swift:113` to level-scheduled concurrency —
partition `orderedTasks` into dependency levels, then run each level under
`withThrowingTaskGroup` with a concurrency limit defaulting to active core
count and overridable by `--jobs`.

Three existing mechanisms become load-bearing:

- `acquireTaskLocks` and `lockOrdering` already encode mutual exclusion and a
  total acquisition order. Under concurrency they prevent the deadlock they were
  written for.
- `OutputDeclaration` paths give write-conflict detection at plan time. Two
  tasks schedulable in the same level that declare overlapping output paths is a
  graph error, surfaced by `validate` rather than discovered as a race.
- `RunRegistry` event recording is already `async` and must be verified to
  interleave without reordering a single task's log stream. Per-stage log
  buffering in `PseudoTerminalLog` handles this; interleaving across stages is
  acceptable, interleaving within a stage is not.

`toolIdentityCache` moves behind an explicit lock or becomes a preresolved
snapshot computed during the identity pass, since it is currently protected only
by actor isolation that no longer applies.

**Verification gate.** A full `collider build all` from a cold state root
produces byte-identical artifacts and an identical executed-task set to a serial
run forced with `--jobs 1`, repeated across three runs to catch ordering
nondeterminism.

## Phase 5 — Content-addressed artifact cache

`ArtifactDigest` per task already folds in dependency identities, so the cache is
purely additive. A store under the state root maps task identity to the declared
outputs of that task. `assess` at `TaskEngine.swift:801` consults the store
before scheduling and restores outputs on a hit instead of executing.

Only tasks with `cachePolicy == .contentAddressed` are eligible; `.always` tasks
bypass the store entirely, which already matches their semantics.

Restoration must respect `OutputDeclaration.validation` — a restored output that
fails its declared validation is a store corruption, and the correct response is
to evict the entry and execute the task rather than to fail the build.

This phase is what buys the shared-cache property across checkouts and machines,
on a key the engine already computes correctly.

**Verification gate.** A task executed in one state root and restored from cache
in a second, cold state root produces identical outputs and reports as clean on
the immediately following plan.

## Risk Surface

**Digest encoding (phase 1) is the only silent-failure path in the plan.** Every
other mistake here fails loudly at compile time or in a test. An encoding slip
produces a build that appears to work and is wrong. The differential replay gate
is not optional and lands first.

**Test relocation (phases 1 and 2).** `TaskEngineTests.swift` is 1791 lines and
constructs `TaskOperation` cases directly across the full domain surface. Those
tests migrate to the packages that receive the actions; what remains in
`ColliderCoreTests` covers the fifteen kernel primitives, graph ordering,
identity computation, and locking. Per the repository test directives, the
migrated tests assert runtime behavior, not the presence or shape of the
declarations that moved.

**Phase 2 is large but low-risk.** It is mechanical relocation with no behavior
change, and its gate is a clean replay rather than a functional diff.

**Phase 3 touches a public CLI surface.** The selection-string constraint above
is the specific failure mode.

**Phase 4 is where genuine concurrency defects can appear**, which is why it is
ordered after the isolation domain has been broken up and before the cache
depends on it.

**The empty `NucleusAOSP*` module directories** under
`collider/engine/Sources/` — `BuildAuthority`, `SigningAuthority`,
`CapsuleImage`, `CapsuleRootLock`, `ComparisonAuthority`, and 13 others — split
AOSP inward, into more kernel-resident modules. Phase 2 moves that logic out of
`collider/engine` entirely. These directories are either removed or their
intended contents land in `android-runtime` as part of phase 2; leaving them in
place multiplies module count while preserving the inverted dependency this plan
exists to remove.
