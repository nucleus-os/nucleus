# Collider Architecture Simplification Plan

Status: complete.

## Invariant

Collider orchestrates repository-scale work that no individual build system owns:
container execution, cross-system dependency ordering, typed artifact handoff, and
run attribution. SwiftPM, llbuild, CMake, ninja, ccache, and package managers own
their internal incrementality. Collider invokes those systems and reports their
results; it does not reproduce their build databases, output layouts, or caches.

The completed architecture has these properties:

- Host SwiftPM actions always invoke SwiftPM. SwiftPM and llbuild decide whether
  the invocation has work to perform.
- OCI actions retain a Collider-level input gate because avoiding container
  startup and mount preparation is materially useful.
- Downloaded bytes live only in the digest-addressed `ColliderDownloads` cache.
- Deterministic generators rerun when their declared inputs change. Collider
  does not snapshot their outputs into a second content-addressed cache.
- A successful process exit is the primary execution result. Output validation
  remains only where it proves a cross-task artifact contract or host visibility
  across a container boundary.
- SwiftPM reports public product paths. Collider does not depend on SwiftPM
  private intermediate-directory conventions.
- Scheduling protects overlapping filesystem effects and bounds concurrent
  execution classes. It does not model fractional CPU, memory, or I/O capacity.
- Run records contain data used for diagnostics and attribution. Unconsumed
  audit mirrors and no-op controls do not exist.
- Active runs are never pruned. Completed-run retention preserves recent
  diagnostics, including the newest failed run.
- Existing standard-library and `swift-system` APIs replace unsafe local code
  when they provide the complete required semantics. Collider does not add a
  package dependency solely to shorten small loops.

## Evidence

The audit covers the `collider/` package and `collider/engine/`, including all
recipe modules. The measurements below describe the tree when this plan was
written and are evidence, not permanent architectural constants.

- Recent complete plans select approximately 25–29 tasks for execution. A run
  manifest can contain the full declared graph as well; one observed manifest
  contained 147 entries, with 25 planned and 122 locally clean.
- Per-task input lists generally contain 5–20 entries. Planner algorithmic
  complexity at this scale is a clarity and correctness concern, not a
  performance concern.
- `.nucleus/runs` contained more than 470 run directories and approximately
  564 MB. Individual large runs reached approximately 78 MB.
- In one measured manifest, unused audit records occupied 61 percent of the
  manifest bytes. This is not 61 percent of total run storage; logs dominate the
  retained run footprint.

File and symbol names below are the durable anchors for the work. Line numbers
are deliberately omitted because the plan must remain useful while the code
moves.

## Findings

### Dead and unobserved surface

`SwiftPackageRequirementBuilder` has tests but no production caller. Production
recipes already construct requirements through `swiftPM.product(...)` and
`swiftPM.testProduct(...)`.

`LoadedLibrary`, `LoadedLibraryFailure`, and
`collider_copy_loaded_library_path` form a complete unused vertical slice across
`ColliderRuntime` and `ColliderPlatformC`.

The `--explain` option is parsed and carried into `TaskExecutionOptions`, but the
engine never consumes it. Its rendered result duplicates `--dry-run`.

`PlannedTaskAudit` and its nested audit records make a second pass over task
inputs, tools, effects, build contexts, and outputs. They are serialized into
every run manifest but have no typed reader and no CLI presentation.

Output-derived scheduler claims are inert. Graph validation already rejects
equal or nested output paths from distinct tasks, so output claims cannot add a
runtime conflict that validation has not already rejected. Explicit locks and
action effects remain authoritative.

### Duplicate artifact caching

`ArtifactSnapshotStore` implements a second content-addressed cache with
publication, corruption handling, restoration, permissions, pruning, and
locking. `ColliderDownloads` already owns digest-addressed downloaded bytes.

The tasks using `.artifactCached` fall into two groups:

- GN, Boost, the AOSP Repo launcher, and Swift SDK inputs are downloads or
  extraction of downloaded content. They resolve from the download cache.
- Vulkan and Wayland source generation are deterministic transforms. They rerun
  when their declared inputs change.

Neither group requires a general snapshot-and-restore subsystem. Removing the
snapshot store also removes its eligibility validator and plan representation.

### Duplicate SwiftPM incrementality

Host Swift tasks hash `Package.swift` and entire source and test trees before
invoking SwiftPM. This duplicates llbuild's finer-grained dependency database to
avoid only a warm no-op invocation.

Host SwiftPM actions must therefore become always-invoked actions. Removing host
tree hashes without that rule would allow Collider to classify a task as clean
indefinitely and skip SwiftPM incorrectly.

OCI SwiftPM actions retain their input gate. Avoiding a container startup is a
meaningful boundary-level optimization that SwiftPM inside the unstarted guest
cannot provide.

### SwiftPM private layout reconstruction

`SwiftBuildContext` reconstructs SwiftPM product paths through
`productsSuffix`, `targetProductsSuffix(forTriple:)`, and `productsPlatform`.
It also names `Intermediates.noindex/GeneratedModuleMaps`, which is a private
backend layout.

`swift build --show-bin-path` authoritatively reports the product directory but
does not report arbitrary private intermediate roots. The correct endpoint is:

- query and cache `--show-bin-path` for each invocation context;
- pass the selected build system explicitly;
- consume declared package products and public artifacts from that directory;
- eliminate dependencies on generated module maps inside private intermediates;
- move any genuinely required module map into a declared package or generated
  artifact owned by Nucleus.

Collider must not replace one hardcoded private path with another inferred path.

### Incorrect identity inputs

The host SwiftPM scratch path incorporates `NUCLEUS_SWIFT_SOURCE_ID`, a digest of
the Linux and Android Swift SDK source closure. Host compilation uses Xcode's
Swift compiler, whose executable is already a declared tool input. Advancing a
target-SDK source submodule must not cold-rotate the host scratch directory.

`maximumParallelism` also participates in `SwiftBuildContext.identityBytes`.
Job count changes scheduling, not produced artifacts, and must not select a new
scratch directory.

### Subsumption duplicates SwiftPM semantics

Subsumption spans planning, identities, run records, scheduling, CLI rendering,
and SwiftPM lowering to encode that `swift test` builds the products under test.
Only `LinuxColliderRecipe` uses the behavior in production. The recipe can
declare the test action directly and let SwiftPM own its native build-before-test
semantics.

### Scheduler resource arithmetic is the wrong abstraction

The scheduler performs weighted CPU, memory, and I/O bin packing. Dominant host
SwiftPM actions are exclusive, while OCI actions already receive concrete CPU,
memory, and job limits.

Per-container limits do not constrain aggregate host pressure. Replace weights
with explicit execution-class concurrency caps:

- one host-exclusive lane for actions that cannot overlap safely;
- a bounded OCI lane sized for the machine's supported concurrent builders;
- a bounded lightweight lane for short host operations;
- filesystem claim conflict detection across every lane.

This expresses the actual policy directly without pretending to perform a
general-purpose resource allocation calculation.

### Output validation needs a narrower contract

Output validation is redundant for terminal host products when a successful
SwiftPM invocation is the complete contract. It remains useful when another task
consumes a specific artifact or when an OCI process must publish an artifact
through a host mount.

Validation therefore follows artifact boundaries, not simply the `.host` or
`.oci` execution enum:

- keep validation for every declared downstream artifact;
- keep host-visible validation for OCI-produced artifacts;
- remove validation from terminal host products with no artifact consumer;
- do not parse generated JSON a second time unless its parsed shape is itself a
  consumer contract.

### Run retention is manual

Run directories grow without automatic reclamation. Retention belongs in run
terminalization, after all logs and records are closed. It must exclude active
runs and preserve the newest failed run in addition to the configured recent
completed set.

### Targeted API cleanup

Several local operations should use existing typed APIs:

- Replace string-prefix path containment with one component-aware `FilePath`
  helper in `ColliderCore`.
- Store typed `DeviceID` and `Inode` in `PlanningArtifactDigestCache` when their
  `Codable` representation is supported by the pinned `swift-system` version.
- Replace the force-unwrapped `Subprocess.Environment.Key` construction with a
  throwing validation path.
- Route the `xcodebuild -version` probe in `SwiftSDK` through
  `ColliderRuntime.execute` for cancellation, bounded output, credential
  scrubbing, and run attribution.
- Replace `FileHandle` inside `AppleContainerPipe` with typed file descriptors,
  while retaining an explicit asynchronous readiness mechanism.
- Convert hardcoded `NSRegularExpression` patterns to checked Regex literals.
  Dynamic and hashable stored patterns keep the representation required by their
  domain model.
- Consolidate elapsed-nanosecond conversion into one helper. Keep the persisted
  integer nanosecond representation rather than coupling run records to
  `Duration`'s encoded representation.

`ArtifactHasher` keeps its deliberate streaming buffer until measurement shows
another size is better. `Stat.preferredIOBlockSize` describes filesystem block
geometry and is not evidence for an optimal userspace hashing buffer.

Small order-preserving deduplication loops converge on one local helper. The
repository does not vendor `swift-algorithms` solely for `uniqued`, partitioning,
pair combinations, or prefix trimming at graph sizes this small.

## Correct Boundaries to Preserve

- `ColliderPlatformC` shims for `flock`, `fsync`, atomic rename, symlink, and
  pseudo-terminal operations remain; `swift-system` does not replace them.
- `FileManager` remains for directory creation, enumeration, copying, and
  removal where `swift-system` has no equivalent.
- `RuntimeELF` continues to invoke platform ELF tools. Collider does not grow an
  ELF parser.
- `ColliderRuntime` continues to own process cancellation, teardown, output
  streaming, and credential handling.
- Apple-container stop and deletion verification remains. Defensive lifecycle
  handling is part of the container boundary, not a build-system duplicate.
- OCI execution, cross-system sequencing, typed artifact references, and run/log
  attribution remain Collider responsibilities.
- Temporary paths converge on one collision-safe helper. A process identifier
  alone is insufficient because Collider executes concurrent work within one
  process.

## Sequential Implementation Plan

### Phase 1 — Remove dead and unobserved surface (complete)

Delete `SwiftPackageRequirementBuilder` and its tests. Delete `LoadedLibrary`,
`LoadedLibraryFailure`, and the associated platform-C function and declaration.
Delete `--explain` and its parsing tests. Delete `PlannedTaskAudit`, its nested
types and construction pass, and the `TaskPlanEntry.audit` field. Remove
output-derived normalized claims.

Preserve manifest decoding only for fields that remain part of active run
observation. Reset incompatible local run records rather than retaining a second
reader for an obsolete internal manifest shape.

Phase 1 is complete when planning, dry-run rendering, normal execution, and run
inspection work without any replacement audit model.

Completed: the dead SwiftPM builder and loaded-library slice, `--explain`, the
planning audit model, its manifest payload, and output-derived scheduler claims
are removed. Explicit locks and action effects remain the scheduler authorities.

### Phase 2 — Correct identities (complete)

Remove `NUCLEUS_SWIFT_SOURCE_ID` from host SwiftPM context identity. Keep the
resolved Xcode Swift executable as the host toolchain input. Remove
`maximumParallelism` from artifact identity while retaining it in invocation
construction.

These changes land together so the host scratch path rotates once. Phase 2 is
complete when changing target-SDK source gitlinks or host job count does not
change the host scratch directory, while changing the selected Swift compiler
does.

Completed: host SwiftPM contexts derive their toolchain identity from the
resolved compiler executable, target-SDK source identity is excluded from host
SwiftPM commands, and job count remains an invocation argument without entering
artifact or scratch identity.

### Phase 3 — Remove duplicate cache and subsumption systems (complete)

Delete `ArtifactSnapshotStore`, its tests, `.artifactCached`, eligibility
validation, snapshot plan records, and snapshot planning services. Connect
download tasks directly to `ColliderDownloads`. Give deterministic generation
tasks ordinary declared inputs and outputs so they rerun when inputs change.

Then remove subsumption end to end. `LinuxColliderRecipe` declares test actions
without separate build prerequisites that `swift test` already performs. Delete
the planner fixed point, identity fields, plan fields, run outcomes, scheduling
cases, CLI presentation, and SwiftPM covered/uncovered product split.

Phase 3 is complete when a fresh checkout can restore downloads from the digest
cache, regenerate derived sources, and run Linux tests without either concept in
the task model.

Completed: artifact snapshots and their cache-only policy are deleted; downloads
remain digest-addressed through `ColliderDownloads`; deterministic generators use
ordinary task inputs and outputs; and task subsumption is deleted across the
declaration, identity, plan, runtime, persistence, and CLI layers. Linux test
entrypoints invoke `swift test` directly without a redundant build prerequisite.

### Phase 4 — Hand host Swift work fully to SwiftPM (complete)

Make host SwiftPM actions always invoke SwiftPM and remove host source-tree
hashing from Collider. Retain OCI input assessment. Narrow output validation to
declared downstream and container-publication boundaries.

Query `swift build --show-bin-path` once per invocation context and pass the
build system explicitly. Replace consumers of private generated-module-map
paths with declared package or Nucleus-owned generated artifacts. Delete the
manual product-layout reconstruction only after all consumers use the queried
public path.

Phase 4 is complete when a warm host build reaches SwiftPM and exits as SwiftPM's
own no-op, target builds still avoid unnecessary container startup, and no
Collider code names `Intermediates.noindex`.

Completed: host SwiftPM work always reaches the explicit `swiftbuild` build
system and carries no Collider source-tree assessment. OCI SwiftPM work retains
its outer input gate so an unchanged target build does not start a container.
SwiftPM's public `--show-bin-path` result is published through a stable
Collider-owned products link; production consumers and target-SDK validation no
longer reconstruct product or generated-module-map paths. Output validation now
applies to lowered artifact boundaries instead of repeating logical Swift
product checks.

### Phase 5 — Simplify scheduling and storage lifecycle (complete)

Replace weighted CPU, memory, and I/O claims with explicit concurrency lanes and
filesystem effect conflicts. Delete normalized resource weights, host capacity
probing, and impossible-capacity planner errors. Keep concrete OCI resource
limits and guest job counts.

Apply run retention after terminalization. Never prune active runs. Preserve the
configured recent completed set and the newest failed run. Make explicit cache
pruning use the same retention implementation.

Phase 5 is complete when independent arm64 and x86_64 OCI work can overlap within
the configured OCI cap, conflicting paths cannot overlap, host-exclusive work
remains serialized, and repeated runs keep bounded diagnostic storage.

Completed: the scheduler uses fixed lightweight-host and OCI concurrency limits
plus a single host-exclusive barrier. Action filesystem reads become shared claims
and writes become exclusive claims across every lane. Host-capacity probing,
normalized CPU/memory/I/O weights, and impossible-capacity planning failures are
deleted; concrete OCI limits and guest job counts remain execution inputs.
Terminalizing a run now applies the same retention selection used by explicit
cache pruning: all running records, the configured newest terminal records, and
the newest failed record are preserved. Scheduling delay records lane and
filesystem-claim waiting rather than obsolete resource-bin-packing time.

### Phase 6 — Apply targeted safety cleanup (complete)

Adopt the component-aware path helper everywhere, validate environment keys
without force unwraps, route the Xcode probe through `ColliderRuntime`, migrate
`AppleContainerPipe` off `FileHandle` without removing readiness handling,
consolidate elapsed-time conversion, and replace eligible static regular
expressions with checked Regex literals. Adopt typed stat identifiers only after
compiling their persistence use against the pinned dependency.

Do not add `swift-algorithms`, change the file hashing buffer, or convert
persisted timing fields as part of this phase.

Phase 6 is complete when the focused engine and command tests pass, the complete
Collider test suites pass, and one complete bootstrap/build run exercises both
target architectures without obsolete code paths or compatibility layers.

Completed: one shared component-aware `FilePath` implementation now owns path
normalization, containment, overlap, and relative-subpath semantics. Runtime
environment construction validates names and values without force unwraps, and
the Xcode and host-Swift probes execute through `ColliderRuntime` with bounded
output. Apple-container pipes own Swift System file descriptors while retaining
dispatch-source readiness and expose `FileHandle` only at the Apple API adapter.
Elapsed-time conversion is centralized, static patterns use checked Regex
literals, and persisted file signatures retain the pinned Swift System
`DeviceID` and `Inode` types directly. The focused tests, 97-test engine suite,
complete Collider suites, bootstrap, and complete arm64/x86_64 build all pass.

## Completion State

Collider now contains one orchestration path for each operation, delegates
incrementality to the build system that owns it, preserves only boundary-level
caching and validation, and has no compatibility wrappers for the deleted
task-model concepts.
