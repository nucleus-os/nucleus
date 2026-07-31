# Collider Task Engine and Package Root Plan

## Invariant

Every Collider task declares its complete input set, verified by execution against a
constructed filesystem view rather than by inspection. Every task whose outputs are
narrow and materialized is recoverable from its identity without re-executing it. The
task graph executes concurrently up to the limits its own lock model expresses. Every
first-party Swift module compiles once per configuration per build root, and the number
of build roots is the minimum the component architecture requires.

Status: active

## Current Disposition

The current-state audit predates framework unification, the single-root
Collider package, explicit runner/executor/artifact coordinates, and
backend-neutral OCI execution. Its package counts, source paths, line numbers,
and operation-identity description are not implementation inputs. Re-audit the
current SwiftPM graph before executing Phases 1 through 3; do not recreate a
package merge that a later framework boundary made unnecessary. The undeclared
input audit, recoverable output store, and lock-aware capacity scheduler in
Phases 4 through 6 remain active architectural work after that rebase.

## Current State

The task engine is a content-addressed action graph. `TaskDeclaration`
(`collider/engine/Sources/ColliderCore/TaskGraph.swift:912`) carries inputs, outputs,
locks, a cache policy, and an operation. `identity(of:dependencies:)`
(`collider/engine/Sources/ColliderRuntime/TaskEngine.swift:173`) mixes dependency
identities, input digests, output declarations, and the operation's own encoding —
including the command environment filtered through `artifactEnvironment` — into one
`ArtifactDigest`. Native third-party builds are leaves that shell out to their upstream
build systems: GN/Ninja for Skia and Chromium, Meson for Mesa, Soong for AOSP, AGP for
the Android application surface, SwiftPM for all first-party Swift.

Four properties are missing.

**Outputs are never stored.** `assess` (`TaskEngine.swift:781`) compares a recorded
`TaskStateRecord` identity against the freshly computed one and re-runs on mismatch.
Outputs are validated for existence and type (`TaskEngine.swift:1069`), never captured.
A digest already built and then displaced is unrecoverable, so any input revert re-runs
the native build that produced it.

**Execution is strictly serial.** `TaskEngine.swift:119` iterates the topological order
one task at a time. `tracy.build`, `vulkan.build`, and `wayland.build` are mutually
independent and all gate `core.build` (`core/Sources/CoreColliderRecipe/CoreColliderRecipe.swift:5`);
they run in sequence. Downloads, patch applications, publications, and validations never
overlap a long build.

**Input completeness is unverified.** Nothing checks that a task reads only what it
declares. Dependency edges do carry content identity, so the published native SDK reaches
`core.build`'s key through the `core.native-sdk` edge, and `.tool` inputs digest the
resolved binary. The gaps are `.dependencyOutput`, which encodes only a path
(`TaskEngine.swift:206`), manifest-evaluation-time `pkg-config` reads of host system
libraries (`compositor/compositor/Package.swift:33`), and any environment variable not
declared as an `.environment` input.

**First-party modules compile once per build root.** There are eight build roots.
`NucleusUI.swiftmodule` exists thirteen times on disk: six roots that compile core's
modules — `core`, `platform-linux`, `react-native`, `compositor/compositor-core`,
`compositor/compositor`, `shell` — across Debug and Release, plus core's
`nucleus-api-build`. Scratch across all `.build` directories totals roughly 24 GB, led by
`compositor/compositor-core` at 5.8 GB, `shell` at 4.0 GB, `core` at 3.4 GB, and
`compositor/compositor` at 2.1 GB. SwiftPM has no cross-root artifact sharing: a build
graph is per-root, sharing a scratch path clobbers, and Linux has no binary library
target. An umbrella root does not help the test lanes, because `swift test` runs only the
root package's test targets and target paths cannot escape the package directory. The
only lever is fewer roots.

## Scope Boundary

Collider keeps ownership of the graph and continues to delegate each foreign build system
to a single task with declared inputs and outputs — the pattern already used for
`gradlew` (`collider/Sources/ColliderCommands/ComponentRegistry.swift:323`). That
boundary is correct and this plan does not move it. Recipes stay inside the packages they
describe, as SwiftPM targets type-checked against `ColliderCore`.

Two designs from Gradle's task model land here directly, named in the phases that adopt
them: opt-in output caching (phase 5) and capacity-bearing resource locks (phase 6).

## Phase 1 — Collapse the compositor application package into the compositor library package

`compositor/compositor` exists to hold the app half of an app/library split. It costs a
full recompile of core, vulkan, wayland, tracy, platform-linux, and all of compositor-core
in order to link one executable.

Six targets move from `compositor/compositor/Package.swift` into
`compositor/compositor-core/Package.swift`, with their sources physically relocated under
the compositor-core package root because SwiftPM requires target sources inside the
package directory: `NucleusCompositorSignalC`, `NucleusCompositorRenderSession`,
`NucleusCompositorRenderSessionTests`, `NucleusCompositorRuntime`,
`NucleusCompositorThreadSanitizerHarness`, and the `NucleusCompositor` executable
(`compositor/compositor/Package.swift:217`). Compositor-core gains two executable
products, `NucleusCompositor` and `NucleusCompositorThreadSanitizerHarness`.

The app package's dependencies are already present in compositor-core's dependency list —
`Nucleus`, `swift-tracy`, `NucleusLinuxPlatform`, `engine` — so the merged manifest gains
no new package edges.

The documented reason for the split survives without the split.
`compositor/compositor/Package.swift:1` records that C++ interoperability is scoped to
the composition root and executable rather than forced over the non-C++ test target.
`.interoperabilityMode(.Cxx)` is a per-target `swiftSettings` value, so
`NucleusCompositorRenderSession` and `NucleusCompositorRenderSessionTests` carry no
interop setting after the move and the property holds at target granularity.

`CompositorAppColliderRecipe` merges into `CompositorColliderRecipe`. The `compositor.build`
and `compositor.test` task identifiers are deleted and their dependents re-point at
`compositor-core.build` and `compositor-core.test`. `WorkspaceComponent.compositor`
(`collider/Sources/ColliderCommands/Orchestrator.swift:5`) resolves to
`compositor/compositor-core`, and the `packagePath` discriminator used by
`releaseStructuralSuites` for the compositor entry is removed. Every remaining reference
to the app package path is updated, including the sanitizer lane in
`collider/Sources/ColliderCommands/Sanitizer.swift` and the host contract in
`collider/Sources/ColliderCommands/Doctor.swift`. The `compositor/compositor` directory is
deleted.

Risk surface: the shell package consumes compositor-core products and is unaffected by
added executable products. The thread-sanitizer harness and the DRM render-session test
target change package identity, so their lane invocations move with them.

Gate: `collider build compositor` and `collider test compositor` pass, the DRM
render-node lane passes, and the on-disk count of `NucleusUI.swiftmodule` outside module
caches falls from thirteen to eleven.

## Phase 2 — Fold the Linux platform package into the core package

`platform-linux` declares the package name `NucleusLinuxPlatform`, depends only on `core`,
`collider/engine`, and `third-party/swift-system`, and is consumed by compositor-core and
shell — both of which already depend on core.

Its targets move into `core/Package.swift` and its libraries become core products, with
sources relocated under the core package root. Core's dependency list gains
`third-party/swift-system`. Consumers rewrite `.product(name:package: "NucleusLinuxPlatform")`
to `package: "Nucleus"` in `compositor/compositor-core/Package.swift` and
`shell/Package.swift`. `LinuxColliderRecipe` merges into `CoreColliderRecipe`; the
`linux.build` and `linux.test` identifiers are deleted and their dependents re-point at
`core.build` and `core.test`. `WorkspaceComponent.linux` is removed along with its
registry entries. The `platform-linux` directory is deleted.

Risk surface: core's target graph grows by the Linux substrate targets, several of which
are C targets with `publicHeadersPath`. Core must not gain a dependency on anything the
Linux targets pull in beyond swift-system; if a Linux target reaches a package core does
not already depend on, that edge is added explicitly rather than transitively assumed.

Gate: `collider build all` and `collider test all` pass, and the `NucleusUI.swiftmodule`
count falls from eleven to nine.

## Phase 3 — Reduce each root to the configurations its lanes require

After phases 1 and 2 the roots that compile core's modules are `core`, `react-native`,
`compositor/compositor-core`, and `shell`. Every root currently carries both
`Debug-linux-x86_64` and `Release-linux-x86_64` product directories, but
`releaseStructuralSuites` (`collider/Sources/ColliderCommands/Orchestrator.swift:44`)
declares release lanes for core, shell, and compositor-core only.

Each recipe's build and test tasks are audited against the lanes that consume them. Where
a root produces release output no lane requires, the release invocation is removed from
its recipe. Where a lane genuinely needs release output, the recipe declares it and the
configuration becomes an explicit part of the task identifier rather than an accident of
which command ran last.

Risk surface: a release configuration removed from a root that a sanitizer, benchmark, or
profiling lane silently depended on. The audit enumerates lane invocations in
`ColliderCommands` rather than inferring need from on-disk output.

Gate: `collider test all`, the GPU DRM lane, the sanitizer lanes, and the benchmark lanes
all pass, and total `.build` scratch is measured and recorded against the 24 GB baseline.

## Phase 4 — Input declaration audit lane

A wrong cache key today produces a stale clean verdict, which is self-limiting because the
outputs on disk are whatever the task last built there. Once phase 5 stores and restores
outputs, a wrong key restores artifacts built from different inputs. Input completeness is
therefore verified before anything is stored.

`TaskExecutionOptions` (`collider/engine/Sources/ColliderRuntime/TaskEngine.swift:5`)
gains an `auditInputs` mode. Under it, a task's command executes inside a mount namespace
entered through `unshare --mount --map-root-user`, the mechanism already used by
`BrowserInstallationWorkflow.swift:268`. A helper constructs the view: a tmpfs root,
read-only binds for every declared `.file`, `.tree`, and `.optionalTree` path and for
every resolved `.tool` prefix, read-write binds for each declared output path and its
parent, and a fixed floor of `/proc` and `/dev`. The task then runs against that view and
nothing else.

An undeclared read fails the task, and the failure is the finding. The lane surfaces as
`collider verify inputs [<task>…]`, selecting tasks by identifier or by component, and
reports the first missing path per failing task.

Two classes of finding get resolved rather than suppressed. Where a task reads a path
produced by a dependency, the input is declared `.dependencyOutput` so the producing task's
identity carries it. Where a task reads a host system library resolved at manifest
evaluation time, the resolved flags are captured as a `.value` input so a host change
invalidates the key.

Scope: the lane runs first over the narrow-output task class enumerated in phase 5, where
declarations should already be complete. The SwiftPM build and test tasks declare a whole
`.build` directory as output (`core/Sources/CoreColliderRecipe/CoreColliderRecipe.swift:295`)
and reach the toolchain prefix, so they are audited after the narrow class is clean and
their findings are resolved by declaration, not by exemption.

Risk surface: the tool prefix binds. A Swift or clang invocation needs its entire
toolchain directory, not the driver binary alone, so `.tool` resolution grows a prefix
concept used by the audit view while the identity encoding continues to digest the
resolved executable.

Gate: `collider verify inputs` passes clean over every task carrying the `.stored` policy
introduced in phase 5, and the audit is wired into the required CI lane.

## Phase 5 — Output content-addressed store

This phase adopts Gradle's `@CacheableTask` design. Gradle caches only tasks explicitly
marked cacheable, because caching everything is wrong. The same conclusion holds here and
becomes an explicit policy rather than a heuristic.

`TaskCachePolicy` (`collider/engine/Sources/ColliderCore/TaskGraph.swift:907`) gains a
third case, `.stored`. Only `.stored` tasks are captured and restored. The policy is
already mixed into the identity encoding (`TaskEngine.swift:180`), so adopting it on a
task invalidates that task's prior state exactly once.

A new `ColliderArtifactStore` in `ColliderRuntime` owns the layout, rooted beside the
native SDK under the workspace cache root rather than in the repo-local `.nucleus`
state directory, because objects are large and state is not:

```
store/objects/<aa>/<digest>     content, mode 0444
store/manifests/<identity>.json declared output path → object digest, mode, symlink target
```

Two insertion points in `execute`. Before dispatch, where `assess` returns dirty: if a
manifest exists for the computed identity, materialize the declared outputs by hardlink,
run `validate(task)`, persist the `TaskStateRecord`, and record a new `.taskRestored`
event beside the existing `.taskSkipped` path at `TaskEngine.swift:112`. After
`validate(task)` succeeds at `TaskEngine.swift:135`: ingest each declared output into
`objects/`, write the manifest, then persist as today.

Objects are written read-only so a later in-place mutation of a restored output cannot
rewrite the cached content. The store takes a `ColliderFileLock` for concurrent runs.
Manifests record mode and symlink targets, and record directory structure for outputs
declared `.nonEmptyDirectory`.

The initial `.stored` set is the narrow-output task class: `download`, `publishDirectory`,
`assembleHostToolchain`, `assembleAndroidSDK`, `assembleBrowserArtifact`,
`assembleCEFArtifact`, `publishAOSPProduct`, `sanitizeLinkMetadata`, and the render SDK
publications. The SwiftPM build and test tasks stay `.contentAddressed`: their declared
output is an llbuild-owned scratch directory full of absolute paths, and restoring it
would corrupt SwiftPM's own incremental state. `activateGeneration` and `publishSymlink`
stay as they are; they select a generation, and the store sits underneath them.

Retention moves onto the store. `DirectoryRetentionPlan` and `pruneDirectories` keep a
fixed number of generations by directory naming; with content-addressed outputs, retention
becomes reachability from live manifests plus an age bound on unreferenced objects.

Risk surface: hardlink restore requires the store and the output path to share a
filesystem. Where they do not, the store copies and records that it did. A task admitted
to `.stored` before passing the phase 4 audit can restore artifacts built from different
inputs, so admission is gated on a clean audit for that task.

Gate: for every `.stored` task, executing it, reverting its inputs, and re-executing
restores rather than rebuilds, with the restored outputs digest-identical to the originals;
`collider test all` passes with a populated store and with an empty one.

## Phase 6 — Lock-aware parallel scheduler

This phase adopts Gradle's `BuildService` resource model. A shared resource carries a
capacity, and the scheduler admits work against it.

`TaskLock` (`collider/engine/Sources/ColliderCore/TaskGraph.swift:902`) gains a mode.
`.checkout` remains exclusive. `.shared` becomes genuinely shared: a capacity-bearing
resource that admits concurrent readers and excludes writers, which is what the case name
has always implied and what `ColliderFileLock` — always exclusive via
`collider_lock_exclusive` (`collider/engine/Sources/ColliderRuntime/ColliderFileLock.swift:37`)
— has never provided.

`TaskDeclaration` gains a weight. Wide tasks are those whose leaf saturates the machine on
their own: ninja, soong, and SwiftPM invocations. Narrow tasks are downloads, patch
applications, file publications, and validations. The scheduler admits one wide task plus
a bounded number of narrow ones, because unbounded admission over wide leaves thrashes.

The loop at `TaskEngine.swift:119` becomes a ready queue over the same topological order,
driven by `withThrowingTaskGroup`. A task is admitted when its dependencies are complete,
its lock set is compatible with every in-flight task's lock set, and the weight budget
allows it. Compatibility needs no new modelling: the key function in `lockOrdering`
(`TaskEngine.swift:1375`) already produces canonical `checkout:` and `shared:` names.

In-process arbitration happens before `acquireTaskLocks`. Two separate open file
descriptions in one process still conflict under `flock`, so a blocking acquire inside the
task group would park a cooperative thread on a lock the same process holds.
`ColliderFileLock` remains the cross-process guard, acquired with
`waitForExistingOwner: false`, and `alreadyOwned` requeues the task.

Two behaviours change with concurrency. Output presentation is currently a single global
set at `TaskEngine.swift:67`; `.stream` stays valid only at admitted concurrency one, and
otherwise every task buffers through the existing `registry.appendLog(stage:)` path and
flushes on completion. Failure currently throws straight out of the loop; in the group it
becomes cancel-siblings, drain, first failure wins, with `taskFailed` records preserved for
every task that recorded one.

Risk surface: a task pair that is genuinely conflicting but declares no overlapping lock
will now overlap. The lock declarations are the contract, and any pair found to conflict
gets a declared lock rather than an ordering hack. The existing suites in
`collider/engine/Tests/ColliderCoreTests/TaskEngineTests.swift` pin sequential semantics
in places and are rewritten to assert admission and exclusion behaviour instead of
execution order.

Gate: `collider build all` and `collider test all` pass at admitted concurrency one and at
the default budget with identical task outcomes; a graph containing tasks that share a
`.checkout` lock never overlaps them; `tracy.build`, `vulkan.build`, and `wayland.build`
overlap and the run registry records it.

## Outcome

Roots compiling core's modules fall from six to four, and the compositor component stops
paying for its own stack twice. Every stored task's outputs survive input reverts. Input
declarations are verified by execution. The graph runs concurrently to the limits its lock
model expresses, and that model can now express shared access.

The remaining four roots are the price of the component split. Removing it entirely means
one desktop-stack root spanning core, compositor-core, and shell with products preserving
the seams, leaving react-native and the bindings packages separate. That is an
architecture decision about the component boundary, not a continuation of this plan, and
it is not taken here.
