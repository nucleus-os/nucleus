# Nucleus Runtime Architecture Master Plan

## Invariant

Nucleus has one explicit ownership, synchronization, and type boundary for every
mutable runtime subsystem.

Resource destruction is a logical release whose physical reclamation is proven
safe by the subsystem's completion protocol. Public APIs encode actor,
directionality, and concurrency contracts in types. Transaction and frame work
scales with changed or referenced data rather than unrelated retained state.

Collider is one typed command layer over one asynchronous task and process
runtime. A normal invocation enters the public ArgumentParser command tree. The
reserved first argument `__android-apex-mount` enters one isolated privileged
helper before workspace resolution, run creation, signal installation, or
normal command dispatch. The executable chooses between those two modes from
the first argument, and the selected invocation is parsed exactly once.

The parsed normal command is the single source of truth for its options,
validation, capabilities, resumability, and operation. No command serializes
typed values back into Collider option tokens, no implementation reparses an
`ArraySlice<String>`, and no runtime guard reconstructs command capabilities
after parsing.

Collider carries no manual schema counters for its own task declarations, state
records, manifests, provenance, or diagnostics. Current typed structures define
the only supported shape. Task identities derive from declared inputs,
dependencies, outputs, cache policy, and operation encoding. Version fields
required by external protocols remain part of those protocols.

The complete system preserves these concrete invariants:

- A Vulkan queue, its submission ledger, buffer layout state, and deferred
  destruction queues are mutated under one GPU synchronization boundary.
- A GPU buffer is physically destroyed only after its last successful queue
  submission completes.
- A retained-tree transaction validates atomically without copying or walking
  the complete tree when it touches a sparse subtree.
- Every retained-tree walk terminates safely on malformed topology.
- React Native command callbacks execute on the actor declared by their Swift
  type.
- A shared command ring has exactly one logical producer and one logical
  consumer, cannot lose a wakeup, and does not signal when no peer is waiting.
- Frame-plan resource discovery happens once and produces the deterministic
  dependency summary used by resolution, damage, and submit preparation.
- Collider command leaves expose exactly the controls they support.
- Collider runtime responsibilities live in focused workflows around one
  generic task engine.
- Collider is asynchronous from executable entry through run accounting,
  subprocess execution, structured child ownership, cancellation, and shutdown.
- Long-lived children are owned by lexical structured-concurrency scopes.
- Decode workers block on stable synchronization storage and join before their
  state is destroyed.
- Replaced paths are deleted. The implementation contains no compatibility
  parser, duplicate workflow, deprecated wrapper, feature-flagged old path,
  semaphore bridge into async code, or unstructured process-lifetime task.

## Target architecture

The end state has eight major seams:

1. **One Android GPU lifetime domain.** Queue submission, image layout tracking,
   submission completion, and deferred destruction share one serialized ledger.

2. **One retained-tree topology authority.** External code reads topology but
   mutates it only through validated package operations. Transaction validation
   uses a sparse overlay.

3. **Typed actor and direction contracts.** RN callbacks declare their actor,
   and ring producer/consumer roles are distinct endpoint types.

4. **One frame preflight.** `PresentationWalk` produces operations and their
   complete resource summary together. `FrameDriver` consumes one render request
   and one resolver interface.

5. **One typed public Collider topology and one isolated internal mode.**
   ArgumentParser subcommands and typed fields are authoritative. Genuine
   passthrough arguments remain byte-preserving `[String]` payloads.

6. **Exact Collider command capabilities and resumability.** Task controls,
   reporting, command-specific preview behavior, and run resumption exist only
   on the leaves that own them.

7. **One partitioned Collider runtime.** `TaskEngine.swift` owns the generic
   engine. Host-toolchain, Android-SDK, Git, AOSP, browser, download,
   installation, source-management, and validation-fixture concerns live in
   focused files and resources.

8. **One asynchronous Collider lifetime.** The executable has an asynchronous
   `@main`; bounded commands are awaited directly; long-lived children execute
   inside structured `withRunningCommand` scopes.

## Sequencing and verification discipline

The phases below land strictly in order. A phase completes its behavioral,
build, benchmark, qualification, and sanitizer gates before the next phase
starts.

All host verification runs after:

```sh
source tools/host-env.sh
```

Collider phases keep both SwiftPM packages green:

```sh
swift test --package-path collider/engine
swift test --package-path collider
```

Tests assert behavior and runtime contracts. They do not inspect source
declaration presence or absence.

## Phase 1: Make Android GPU ownership and reclamation correct

**Status: Complete.**

Implemented with one GPU mutex, submission and completion serials, per-buffer
last-use tracking, immediate and fence-retired reclamation, post-submit state
publication, terminal fence-error diagnostics, and live/retired/reclaimed
resource counters. Deterministic failure-path and concurrency tests, the
dedicated thread-sanitizer lifetime harness, Android runtime build/tests,
AddressSanitizer coverage, the gfxstream host probe, and the sustained
two-generation workload pass with live and retired buffer counts returned to
zero before GPU teardown.

### 1.1 Establish one GPU synchronization boundary

Add a GPU-owned synchronization primitive to `NucleusAndroidDrmC`. Initialize it
with the GPU and destroy it after every GPU-owned child and Vulkan object is
gone.

The boundary serializes:

- `vkQueueSubmit` calls on the shared queue;
- submission-list insertion and collection;
- submission serial allocation and completion advancement;
- every read and write of `nucleus_android_gpu_buffer.layout`;
- buffer last-use tracking;
- retired-buffer insertion and reclamation.

Keep immutable physical-device properties and format/modifier capabilities
outside the hot locked state after initialization. Do not add a narrow lock only
around `retired_buffers`; that leaves the queue, submission ledger, and layout
state racy while Swift device and buffer types remain `Sendable`.

`nucleus_android_gpu_destroy` remains an exclusive terminal operation. Swift
buffers and timelines retain `GraphicsDeviceResource`. C and C++ callers release
child resources before destroying the GPU.

### 1.2 Tie buffer reclamation to successful submissions

Give each successful queue submission a monotonically increasing serial. Store
it in `nucleus_android_submission`, record the most recent successful serial on
every buffer used by that submission, and track the greatest completed serial on
the GPU.

Change `nucleus_android_gpu_buffer_destroy` into a thread-safe logical release:

- destroy a never-submitted buffer immediately under the GPU boundary;
- destroy a buffer immediately when its last-use serial is complete;
- otherwise enqueue it with its last-use serial in the GPU retirement queue.

Extend the existing collector so it advances completion state from signaled
fences and then destroys every retired buffer whose last-use serial is complete.
Invoke it at submit-time and during GPU teardown. Released buffers no longer
survive until GPU teardown.

Treat only `VK_NOT_READY` as an ordinary pending fence state. Record any other
fence-status result as a terminal GPU failure rather than silently retaining the
submission forever.

### 1.3 Fix state after successful queue submission

Update the buffer's tracked layout to `VK_IMAGE_LAYOUT_GENERAL` and record its
last-use serial immediately after a successful `vkQueueSubmit`.

Semaphore-fd export or syncobj import can fail after the GPU accepts the command
buffer. Those failures still retain the submission and return an error, but they
must not leave `buffer->layout` or last-use state describing the pre-submit
image.

### 1.4 Acceptance gates

- Destroying a never-submitted buffer reclaims it without GPU teardown.
- Destroying an in-flight buffer reclaims it only after its last fence signals.
- Repeated allocate/render/release cycles return live-buffer diagnostics to
  baseline while the GPU remains alive.
- A post-submit semaphore export/import failure preserves actual image layout,
  last-use, and submission state.
- Releases from multiple Swift tasks do not corrupt retirement or submission
  state.
- Multiple render calls respect the single queue synchronization domain.
- Android runtime builds, tests, host probes, and graphics qualification pass.

Expose live, retired, and reclaimed buffer counts through runtime diagnostics
when direct memory observation is nondeterministic.

Risk surface: Vulkan external synchronization, post-submit failure paths,
device-loss handling, and C/Swift/C++ lifetime ordering.

## Phase 2: Make retained-tree commits sparse, bounded, and fail-closed

**Status: Complete.**

Implemented with a transaction-local parent overlay that applies detaches before
ordered insertions, reads unchanged ancestors lazily, and validates property
updates against removal roots without constructing full-tree parent or child
maps. Malformed cycles and dangling ancestor chains fail with a typed topology
error. Retained topology storage is externally read-only, arbitrary-map
construction is removed, validated application reuses stable dictionary
indices, and first-party cross-package fixtures now build trees through
transactions.

The full core and compositor-core host suites pass. The release headless
benchmark passes with a 10,000-layer tree: a one-layer property update visits
two topology nodes and performs one apply-time dictionary probe, while a
one-layer reparent visits three topology nodes and performs three apply-time
dictionary probes.

### 2.1 Replace the full topology shadow with a sparse overlay

Introduce a private validation topology containing only:

- identities created by the transaction;
- parent overrides produced by transaction insertions;
- removal roots;
- helper access to unchanged parents in the authoritative tree.

Process insertions in transaction order. Resolve existence and parent links by
checking the sparse overlay first and the retained tree second. Detect cycles by
walking only the proposed ancestor chain.

Delete the unconditional `tree.layers.mapValues(\.parent)` copy and the
full-tree parent-to-children dictionary. To validate a property update against
removals, walk that node's final ancestor chain and reject it when the node or an
ancestor is a removal root. Application already enumerates the removed subtree;
validation does not enumerate it again.

Validation becomes proportional to transaction size and touched ancestor-chain
height instead of two unconditional full-tree constructions plus a possible
full-subtree traversal.

### 2.2 Make malformed topology terminate safely

Add visited-node tracking to `wouldCreateCycle`. A repeated node means the input
topology is already cyclic, so the function returns `true`.

Apply the same fail-closed rule to validation parent walks. Return a typed
invalid-topology failure when the authoritative tree is malformed.

Keep `LayerTree.layers` and `contextRoots` publicly readable but make mutation
package-scoped. Remove the public arbitrary-map initializer and fix first-party
construction sites to use validated operations.

### 2.3 Remove repeated dictionary probing

Resolve stable dictionary indices once for the child, previous parent, and new
parent. Rewrite `detach`, `attachRoot`, and `attachChild` around indexed value
mutation.

Add an internal validated attachment operation for
`TransactionApplier.applyValidated`. Public attachment validates existence and
cycles; the application path does not repeat validation already completed by
the sparse topology.

### 2.4 Acceptance gates

- Transactions atomically reject missing nodes, missing parents, and cycles
  introduced across multiple insertions.
- Property updates reject explicitly removed nodes and descendants of removed
  nodes.
- Reparenting before removal validates against the transaction's final topology.
- Already malformed cyclic topology terminates with a typed failure.
- Subtree removal, root ordering, and reparenting preserve behavior.
- A large-scene benchmark with a one-node transaction does not visit unrelated
  nodes.
- Core and `NucleusRenderModel` build, test, and benchmark gates pass.

Record validation nodes visited, ancestor steps, and apply-time dictionary
probes through benchmark diagnostics.

Risk surface: transaction-order semantics, public topology access, dictionary
index validity, and atomic rejection.

## Phase 3: Encode the RN command-handler actor contract

**Status: Complete.**

Implemented with a public `@MainActor @Sendable` handler contract, a JS-thread C
trampoline that copies its borrowed strings before scheduling main-actor
delivery, and a sendable retained box whose task capture survives C++ entry
retirement. The existing shared-entry replacement protocol remains the single
ownership mechanism.

A worker-owned Hermes runtime now exercises the real `NucleusHostCommand`
TurboModule and verifies main-actor delivery. Dedicated lifetime coverage
replaces a handler during a blocked invocation, verifies that the retired
context survives until the invocation returns, and verifies exact release of an
installed but unused replacement during teardown. The full React Native Swift
and C++ test suites and the targeted thread-sanitizer harness pass.

### 3.1 Make native command delivery main-actor-owned

Change the public handler type to:

```swift
@MainActor @Sendable (String, String) -> Void
```

`Host` and `RuntimeHost` are main-actor-owned, and native command consumers route
into main-actor-owned shell services. Preserve that ownership.

The C trampoline receives the command on the JS thread, copies the command and
JSON strings, creates a task explicitly isolated to `MainActor`, and invokes the
handler there. It returns without waiting because the command has no synchronous
result.

Make `CommandHandlerBox` safely `Sendable` by storing only the main-actor
`@Sendable` closure. Ensure the scheduled task retains the box or handler before
the C++ shared entry can release its context.

### 3.2 Preserve replacement and teardown ownership

Keep `HostCommandHandler`'s shared-entry lifetime protocol. Replacement and
teardown release each Swift context exactly once and only after in-flight
JS-thread invocations drop their shared entries.

Update documentation to say JavaScript initiates the command on the JS thread
and Swift handles it asynchronously on the main actor.

### 3.3 Acceptance gates

- A JS-thread host command invokes its Swift handler on `MainActor`.
- Replacing a handler during an in-flight command causes no use-after-free or
  duplicate release.
- Runtime destruction balances an installed but unused handler context.
- The public signature prevents non-`Sendable` cross-actor captures.
- React Native Swift and C++ bridge builds and runtime-host tests pass.

Risk surface: callback ordering, actor transfer, retained context release, and
teardown during an in-flight command.

## Phase 4: Redesign the shared command ring around its SPSC contract

**Status: Complete.**

Implemented with a setup-only raw mapping and distinct producer and consumer
attachments in C, Swift, and C++. Role claims reject duplicate attachments, and
the unrestricted `@unchecked Sendable` Swift wrapper is gone. Each Swift
direction serializes operations with `Synchronization.Mutex`; the host pump and
guest stream carry directional C types throughout.

The versionless 128-byte header now places producer and consumer indices,
diagnostics, and wait states on separate asserted cache lines and caches
validated slot metadata in every local endpoint. Reads allocate uninitialized
storage once and transfer it into `Data` without zero-fill or a trimming copy.
Both notification directions use arm, recheck, conditional signal, poll, and
drain; close consumes and wakes either armed waiter.

Packet-boundary, zero-length, maximum-size, duplicate-role, backpressure,
cross-task, close-wakeup, and notification-coalescing tests pass. The full
40-test Android runtime suite, focused AddressSanitizer suite, expanded
ThreadSanitizer harness, UndefinedBehaviorSanitizer cross-process stress,
Collider build, and 48-frame gfxstream workload pass. The release cross-process
stress recorded 84,206 packets/second for 8-byte messages and 82,010
packets/second for 4 KiB messages in default 64 KiB slots, with bounded
occupancy and balanced notification writes/drains. Hardware cache counters
remain a host-validation step because this machine sets
`perf_event_paranoid=4`; cache-line size, alignment, and offsets are enforced by
C ABI assertions.

### 4.1 Introduce directional endpoint types

Separate the raw mapping from its roles:

- a producer exposes write, space-wait preparation, and producer diagnostics;
- a consumer exposes read, data-wait preparation, and consumer diagnostics;
- a duplex side owns one command producer and one response consumer; its peer
  owns the inverse pair.

Remove `@unchecked Sendable` from the unrestricted read/write wrapper.
Directional Swift endpoints use `Synchronization.Mutex` to serialize calls
through one endpoint instance. The cross-process protocol remains SPSC, and a
duplicate producer or consumer attachment is an explicit contract violation.

Apply the same directional vocabulary to C++ host and workload wrappers.

### 4.2 Correct the shared-memory layout

Retain the fixed 128-byte header. Remove the schema-version field and check:
the memfd is ephemeral, both endpoints come from the same opinionated build,
and mixed-version peers are not supported. Validate the magic value, exact
mapping size, slot bounds, atomic requirements, and endpoint-role claims.

Place producer-owned hot fields on the first cache line:

- `write_index`;
- write-backpressure count;
- maximum occupancy;
- producer wait-arm state.

Place consumer-owned hot fields on the second cache line:

- `read_index`;
- read-empty count;
- consumer wait-arm state.

Keep immutable metadata and the infrequently written closed state out of the
consumer's per-message mutation path. Cache validated `slot_count` and
`slot_size` in each process-local ring object.

Add C ABI assertions for header size, cache-line offsets, and alignment.

### 4.3 Remove receive allocation and errno hazards

Allocate uninitialized packet storage with `malloc`, read directly into it, and
transfer it to `Data(bytesNoCopy:count:deallocator:)`. The Linux Foundation
`Data` implementation in the pinned toolchain does not expose
`Data(unsafeUninitializedCapacity:initializingWith:)`. Do not zero-fill a 64 KiB
scratch array and do not copy a trimmed prefix into a second allocation.

Do not introduce a reusable scratch array followed by `Data(bytes:)`; that still
copies each returned packet.

Capture the C result and `errno` before every unsafe-bytes closure returns.
Convert the captured value into the typed transport error afterward.

### 4.4 Replace unconditional notifications with an armed-wait protocol

Do not signal solely from an empty-to-nonempty or full-to-nonfull observation
based on a potentially stale remote index.

Use this data-wait protocol:

1. A consumer that reaches empty arms its data waiter.
2. It rechecks `write_index`.
3. If data appeared, it disarms and continues without polling.
4. Otherwise it polls the data eventfd.
5. A producer publishes data, atomically consumes the armed state, and signals
   only when a waiter was armed.

Use the symmetric protocol for producer backpressure and the space eventfd. Ring
close consumes both armed states and wakes both directions.

Update every Swift and C++ poll loop to arm, recheck, poll, drain, and process
until the ring reaches its stopping condition.

### 4.5 Acceptance gates

- Packet boundaries, zero-length packets, maximum-size packets, and
  backpressure preserve behavior.
- Directional endpoints serialize supported cross-task use.
- Arm-and-recheck races cannot lose a wakeup.
- Close wakes either direction during wait preparation.
- Cross-process stress repeatedly alternates empty/nonempty and full/nonfull.
- Burst notification counters remain coalesced.
- Small-message and default-slot benchmarks record throughput, notification
  writes, drains, empty reads, backpressure, and cache behavior.
- Android transport, C/C++ host workload, and sanitizer-supported stress gates
  pass.

Risk surface: shared-memory ABI, poll integration, close semantics, endpoint
aliasing, and wakeup proof.

## Phase 5: Build one frame resource summary and one resolver boundary

**Status: Complete.**

Implemented with an ordered `FrameResourceSummary` maintained by every
resource-bearing append and finalized alongside the existing occlusion-cull
counter pass, so the authoritative summary contains only visible operations.
Client surfaces, role-qualified texture references, paint requests, and shadow
materials are unique and stable in presentation order; backdrop damage consumes
the recorded blur regions directly. Successful and missing generic textures and
paint-image dependencies are each attempted at most once per frame.

`RenderCore` now owns one package-scoped `FrameResourceResolver`. A
`FrameRenderRequest` carries frame inputs into the two-argument `renderFrame`
entry point, and every acquire, paint, decode, snapshot, client-surface, and
renderer-texture lookup completes before recording begins. Diagnostic plan
logging formats the final operations and summary counts without performing
resource lookups.

Telemetry now records final operation count, unique dependency counts, and
resource-summary construction time. The 83-test core renderer product, the
164-test compositor renderer product, focused ordering/culling/missing-resource
tests, localized and backdrop damage tests, release renderer build, Collider
build, and all 11 release headless benchmark workloads pass. GPU-dependent
interactive cases remain explicitly hardware-gated.

### 5.1 Populate a resource summary during plan construction

Extend `FramePlan` with a deterministic summary containing:

- ordered unique client surface IDs;
- ordered unique texture references;
- unique paint requests;
- unique shadow materials;
- backdrop blur regions.

Populate it when `PresentationWalk` appends each operation. Do not walk
`plan.ops` again to rediscover dependencies.

Deduplicate failed texture resolutions as well as successful ones. A missing
reference resolves at most once per frame.

### 5.2 Consume the summary in every frame phase

Change paint production, shadow production, acquire collection, generic texture
resolution, and backdrop damage reconciliation to consume the summary.

Preserve deterministic client-surface order through the ordered summary. Remove
the temporary `Set` plus `sorted()` construction and the five release-build
resource traversals. Debug logging may format operations but does not perform
resource discovery.

### 5.3 Replace per-frame resolver closures with one owned interface

Introduce a package-scoped `FrameResourceResolver` owning:

- client acquire semaphore lookup;
- paint-content lookup;
- paint-image resolution;
- generic plan-texture resolution.

Install one resolver owned by `RenderCore` and pass it to `FrameDriver`.
Resolution remains confined to pre-recording. Move image-decode access behind
the resolver so it does not call back through a per-frame closure.

Replace the 12-parameter `renderFrame` call with:

- a `FrameRenderRequest` containing the tree, target, frame, scanout, submission
  mode, and root/lock selection;
- the stable resolver interface.

This change is an ownership and API improvement. Do not claim the four existing
nonescaping closures allocate heap contexts without profile evidence.

### 5.4 Acceptance gates

- Each unique texture resolves at most once, including missing resources.
- Client acquire waits remain deterministic.
- Paint, shadow, blur, and damage results preserve operation semantics.
- No resolver call occurs during recording or submission.
- Structural, localized-content, and backdrop damage remain unchanged.
- Renderer telemetry records operation count, unique dependency counts, and
  summary construction cost.
- Renderer, compositor renderer, frame-damage, and render benchmark gates pass.

Risk surface: plan construction, resource ordering, missing-resource behavior,
snapshot resolution, and callback-free recording.

## Phase 6: Declare the capability of every public Collider command leaf

**Status: Complete.**

Implemented with distinct task-control and report option groups, leaf-owned
diagnostic controls, typed run-ID parsing, a real four-leaf installation group,
one browser installation path, post-terminator-only passthrough arguments, and
exact hidden privileged-mode selection. The complete command-capability matrix,
installation and browser help, unsupported-control rejection, and hidden helper
selection are covered by parser tests. Both Collider package test suites pass.

`GlobalOptions` currently places task controls on commands that do not drive the
task graph. `rejectUnsupportedControls` reconstructs the actual capability
boundary at runtime. Installation and browser commands also vary their
capabilities through runtime strings or overly broad option groups.

This phase makes the command tree authoritative.

### 6.1 Introduce exact option groups

Introduce:

- `TaskControlOptions` containing `--dry-run`, `--explain`, `--verbose`,
  `--json`, and a typed `RunIDArgument` for `--run-id`;
- `ReportOptions` containing only `--json`;
- `TaskControlledCommand`, whose `taskOptions` produces `TaskControls`.

Apply this complete capability matrix:

| Capability | Command leaves |
| --- | --- |
| Task controls and resumption | `bootstrap`, `build`, `test`, `generate rn-spec`, `generate vulkan`, `generate wayland`, `toolchain rebuild`, `android build`, `android native`, `android verify`, `android-runtime source-lock`, `android-runtime source`, `android-runtime image`, `browser bootstrap`, `browser build`, `browser test`, `install browser` |
| JSON report only | `status`, `logs list`, `cache status`, `toolchain status` |
| Command-specific dry run and JSON | `doctor`, `browser doctor`, `validate vulkan`, `cache prune` |
| Command-specific dry run only | `toolchain install`, `toolchain uninstall` |
| No shared controls | `run`, `sanitize`, `benchmark`, `logs show`, `logs tail`, `qualify android-presentation`, `android-runtime framework-boot`, `install session`, `install compositor`, `install shell` |

Commands with distinct preview behavior keep a command-specific flag rather than
adopting task-plan controls.

### 6.2 Isolate the privileged APEX helper

`__android-apex-mount` remains hidden from root help and completion.

The executable recognizes it only as the exact first post-executable argument
and dispatches it before normal initialization.
`AndroidApexMountPrivilegedCommand` parses only the root filesystem, source,
target, payload filesystem, and payload offset required to construct
`AndroidApexMountRequest`.

The helper owns no shared controls, workspace context, RunRegistry entry,
logging runtime, or public command capability conformance.

### 6.3 Make installation and browser topology unambiguous

Make `install` a subcommand group with `session`, `compositor`, `shell`, and
`browser` leaves.

- `install browser` owns `TaskControlOptions` and its optional prefix.
- Runtime installation leaves own only their optional prefix.
- Delete `browser install`.
- Browser doctor owns diagnostic controls.
- Browser bootstrap, build, and test own task controls.

`cache prune` retains its command-specific `--dry-run` and `--json`.
`toolchain install` and `uninstall` retain command-specific dry runs.
`benchmark` deletes its dormant optional suite argument.

Delete `GlobalOptions`, `rejectUnsupportedControls`, `unavailable`, and the
"has not migrated" diagnostic language.

### 6.4 Acceptance gates

- Parser tests cover every row of the capability matrix.
- Every supported control parses on every listed leaf.
- `--run-id`, `--explain`, and `--verbose` fail on every non-task leaf before a
  run is created.
- Command-specific preview and JSON behavior remains intact.
- Installation help exposes one browser installation command.
- Root help never exposes `__android-apex-mount`.
- Only an exact sentinel in first position enters the privileged helper without
  creating a normal run.
- Both Collider package test suites pass.

Risk surface: command topology, help output, option defaults, and preservation
of command-specific preview behavior.

## Phase 7: Move resumability onto parsed task commands

**Status: Complete.**

Implemented with `ResumableRun`, a single `TaskControlledCommand`
implementation derived from the typed run-ID option, and executable
orchestration that reads only the parsed leaf. Raw argument scanning and command
classification for resumability are deleted. The capability matrix proves that
every task leaf carries its run ID into orchestration while every non-task leaf
rejects it during parsing. RunRegistry resumption and completion behavior and
both Collider package test suites pass.

Phase 6 ensures that only task-controlled leaves parse `--run-id`. This phase
makes parsed command values own the remaining run decision.

### 7.1 Add typed resumability

Introduce:

```swift
protocol ResumableRun {
    var requestedRunID: RunID? { get }
}
```

Make `TaskControlledCommand` refine `ResumableRun` and implement
`requestedRunID` once from `TaskControlOptions.runID.value`. Every
task-controlled leaf in the Phase 6 matrix conforms through that shared
protocol.

After ArgumentParser returns the leaf command, normal executable orchestration
reads:

```swift
(command as? ResumableRun)?.requestedRunID
```

A present ID selects `RunRegistry.resume`; an absent ID selects
`RunRegistry.begin`.

### 7.2 Delete duplicated command discovery

Delete `selectedRunID(in:)`, `isResumableTaskCommand(_:)`, and every raw argument
inspection used to infer a normal command's options or identity.

Preserve raw process arguments only at explicit process boundaries:

- first-token privileged-mode selection;
- current executable identity resolution;
- scrubbed invocation recording;
- inherited descriptor or role decoding.

Run creation remains after successful ArgumentParser parsing. Unsupported
`--run-id` input creates no failed run. Invalid or non-resumable run identities
retain their RunRegistry diagnostics and status behavior.

### 7.3 Acceptance gates

- Tests enumerate every task-controlled leaf and prove its run ID reaches
  executable orchestration.
- Android-runtime task leaves and `install browser` participate.
- Non-task leaves reject `--run-id` during parsing.
- Normal invocations never scan raw arguments for resumability.
- Beginning, resuming, interrupted identity mismatch, clean completion, and
  failed completion preserve manifests and events.
- The privileged helper still bypasses normal run orchestration.
- Both Collider package test suites pass.

Risk surface: type-erased parsed-command casting and begin/resume selection.

## Phase 8: Remove every second Collider parser and string dispatch seam

**Status: Complete.**

Implemented with typed doctor, component, sanitizer, optimization, present-mode,
Android-operation, browser-operation, runtime-installation, and toolchain-
architecture values. Parsed leaves now construct `RunOptions`,
`AndroidOperation`, `RebuildOptions`, and installation inputs directly.
Command-layer slice parsers, usage blocks, prefix parsing, token reconstruction,
and benchmark suite input are deleted. Only post-terminator Android Gradle and
compositor payloads remain opaque arrays. Typed validation, defaulting,
incompatible-option, invalid-value, and passthrough behavior tests and both
Collider package suites pass.

ArgumentParser currently produces typed values that several leaves flatten back
into tokens. Implementations then repeat parsing, validation, and usage text.
This phase makes the parsed value authoritative across the command layer.

### 8.1 Introduce typed implementation boundaries

Use `ExpressibleByArgument` enums for bounded domains including doctor scope,
component selection, sanitizer, optimization mode, present mode, Android
operation, browser operation, and toolchain architecture.

Replace every implementation parser:

- `Run` constructs `RunOptions` directly. `RunOptions.validated()` owns
  cross-field rules including Tracy-only fields, sanitizer/Valgrind exclusion,
  positive finite scale, and Tracy's default release optimization.
  Delete `RunOptions.parse` and `RunCommand.usage`.
- `ChromiumCommand.run` accepts `ChromiumOperation` and typed install options.
  Delete `ChromiumCommand.parse` and its usage block.
- `AndroidCommand.run` accepts an `AndroidOperation` with associated values for
  build passthrough arguments, optional verification library, or native build.
  Delete its token switch and arity checks.
- `ToolchainCommand.rebuild` accepts a `RebuildOptions` constructed by the
  ArgumentParser leaf. Delete `RebuildOptions.init(_:)` and token-based
  `ToolchainCommand.run(_:)`.
- Runtime installation accepts a typed `RuntimeInstaller.Component` and
  normalized optional prefix. Delete `InstallCommand.parsePrefix`.
- `SanitizerCommand.run` accepts a typed sanitizer.
- `BenchmarkCommand.run` accepts no argument slice or suite selection.
- Build, test, bootstrap, and doctor pass typed selections downstream.
- Vulkan validation and Android presentation qualification pass typed present
  mode and option values.

The only retained `[String]` command fields are genuine passthrough payloads:
Android Gradle arguments and compositor arguments following `--`. Forward them
without interpreting them as Collider options.

Delete `append(_:_:to:)`, `taskControlArguments(_:)`, implementation usage
constants, and command-layer methods accepting `ArraySlice<String>`.

### 8.2 Retarget behavioral tests

- Invoke ArgumentParser command types with representative argument arrays.
- Inspect resulting typed operations.
- Exercise cross-field `validated()` methods directly.
- Preserve invalid-value, incompatible-option, defaulting, and passthrough
  coverage.

### 8.3 Acceptance gates

- No command dispatch boundary accepts `ArraySlice<String>`.
- No parsed option is serialized back into a Collider option token.
- No implementation type owns public command usage text.
- Bounded command values are enums rather than downstream-validated strings.
- ArgumentParser and typed validation behavior tests pass.
- Both Collider package test suites pass.

Risk surface: option defaults, enum spellings, passthrough preservation, and
cross-field validation.

## Phase 9: Partition the Collider runtime engine

`TaskEngine.swift` combines the generic engine with host-toolchain assembly,
Android-SDK assembly and wiring, Git synchronization, validation fixtures,
JSON-RPC framing, and workflow-specific filesystem helpers.

This phase establishes final runtime ownership before asynchronous lifetime
changes.

### 9.1 Keep the generic engine in `TaskEngine.swift`

`TaskEngine.swift` retains:

- `TaskExecutionOptions`, `TaskPlanEntry`, and `TaskExecutionReport`;
- graph execution, task identity, assessment, operation encoding, operation
  dispatch, output validation, and task-state persistence;
- task-lock acquisition, tool resolution, command rendering, artifact
  environment normalization, and elapsed-time accounting;
- `RuntimeFailure`;
- the two distinct exhaustive `perform` overloads.

`ColliderRuntime.execute` remains the orchestration entry point.

### 9.2 Move workflows to focused owners

- `HostToolchainWorkflow.swift` receives host-toolchain preparation, assembly,
  and Swift/C++/SourceKit-LSP validation orchestration.
- `AndroidSDKWorkflow.swift` receives Android-SDK assembly, metadata rewriting,
  wiring, runtime-linkage validation, host validation, and NDK ELF inspection.
- `GitCheckoutWorkflow.swift` receives checkout synchronization and its
  validation helpers.
- Existing AOSP, Chromium, browser, download, installation,
  `AndroidApexMount.swift`, and `BinderFS.swift` partitions remain intact.

Provisioning entry points remain methods on `ColliderRuntime`. Helpers moving
with one caller remain private. Shared helpers move behind a narrowly named
existing support type when that type already owns the concern. Introduce a new
support type only when no existing type owns it.

Do not create an undifferentiated filesystem, publication, or utility namespace.
Workflow-specific symlink, archive, version, and filesystem helpers stay beside
their sole caller.

### 9.3 Move validation projects to real resources

Move host Swift, C++ interop, SourceKit-LSP, Android SDK consumer, and host plugin
fixture contents out of multiline Swift constants and into resource trees owned
by the Collider runtime target.

`ToolchainValidationFixtures.swift` owns:

- named fixture lookup;
- materialization into task staging directories;
- the JSON-RPC framing and parsing used by SourceKit-LSP validation;
- substitutions for genuinely generated values.

Static manifests and source files remain ordinary resource files.

Declare the resources in `collider/engine/Package.swift`. Ensure the engine test
product, root Collider test product, bootstrap-built release executable, and
launcher-invoked `.build/release/collider` all resolve the generated resource
bundle. Collider continues refusing to run outside a clone; resource lookup
does not introduce a second workspace-discovery path.

Delete the embedded constants after all consumers use the materializer.

### 9.4 Acceptance gates

- Task identities remain byte-for-byte stable for unchanged declarations.
- Task plans, cache decisions, locks, validation, and state persistence preserve
  behavior.
- `TaskEngine.swift` contains only the generic responsibilities listed above.
- Host-toolchain and Android-SDK focused tests pass.
- Fixture materialization produces compilable or parseable projects.
- Release and bootstrap Collider products locate validation resources.
- Command-layer tests pass without changes from the Phase 8 typed boundary.
- Both Collider package test suites pass.

Risk surface: access control, overload resolution, resource-bundle publication,
helper ownership, and task identity stability.

## Phase 10: Make Collider command and child-process lifetimes asynchronous

`waitForAsyncResult` blocks a thread while a detached task enters the
asynchronous runtime. `WorkspaceManagedCommand` separately stores a detached
task and uses a `DispatchGroup` plus polling state for long-lived subprocesses.
This phase removes both lifetime inversions.

### 10.1 Introduce one asynchronous executable entry

Replace `collider/Sources/Collider/main.swift` with `ColliderMain.swift`.
Declare an asynchronous `@main` wrapper owning exact first-token mode selection.

- The reserved sentinel parses and runs
  `AndroidApexMountPrivilegedCommand`, then returns without normal
  initialization.
- A normal invocation parses the public root once, creates or resumes its run
  from `ResumableRun`, and awaits the command.
- The public root and every public leaf become `AsyncParsableCommand`.
- The privileged helper keeps its narrow synchronous mount syscall inside the
  isolated entry path.

### 10.2 Propagate async through bounded operations

- Make `WorkspaceContext.run`, `WorkspaceContext.execute`, and task-graph
  component methods `async throws`.
- Make `withExclusiveVerification` accept and await an async closure while its
  filesystem lock remains alive.
- Propagate async through command implementations and their compiler-required
  caller chain.
- Await RunRegistry begin, resume, append, finish, and cancellation queries.
- Await ordinary bounded subprocesses directly, including each `sudo` re-exec
  of `collider __android-apex-mount`.
- Await runtime shutdown on success, failure, clean exit, and interruption.

### 10.3 Replace stored process lifetime with structured ownership

Delete `WorkspaceContext.start`, `WorkspaceManagedCommand`, and
`ManagedCommandState`. Introduce `withRunningCommand`.

`withRunningCommand`:

- starts one child;
- provides a typed `RunningCommand` handle to an async closure;
- uses a throwing task group and cancellation handler;
- always terminates and awaits the child before returning;
- stores no `Task`, uses no `Task.detached`, semaphore, `DispatchGroup`, or
  polling mutex.

`RunningCommand` exposes asynchronous readiness, status, and wait operations.

Profile capture and Android presentation qualification nest
`withRunningCommand` scopes so the compositor session lexically owns every
receiver, exporter, broker, worker, and qualifier.

Android framework boot owns `lxc-start` through the same scope and completes
container stop, image unmount, binderfs unmount, and instance-directory cleanup
before returning.

The privileged APEX helper remains a short ordinary awaited command. Framework
boot records each completed mount before its next suspension and unmounts
recorded mounts in reverse order on success, error, timeout, or cancellation.

Cancellation closes the process tree, runtime descriptors, and retained session
resources before RunRegistry records final status.

Delete `waitForAsyncResult` and its synchronization support.

### 10.4 Preserve finalization semantics

- Successful commands finish as `succeeded`.
- ArgumentParser clean exits remain successful.
- The privileged helper returns its parser or mount status and never creates a
  RunRegistry entry.
- Signal interruption and resumption identity changes finish as `interrupted`.
- Other thrown failures are scrubbed into the run log and finish as `failed`.
- No child remains running after its owning scope returns.

### 10.5 Acceptance gates

- Command, task, RunRegistry, and subprocess paths contain no
  synchronous-over-async bridge.
- The privileged sentinel selects only the isolated helper, and every normal
  invocation reaches the public parser once.
- Cancellation tests prove nested children terminate and are awaited.
- Qualification, framework-boot, and profile-capture tests cover success, early
  failure, timeout, and interruption cleanup.
- Framework-boot tests prove completed mounts are always unmounted.
- Run manifests and events preserve completion semantics.
- Both Collider packages pass with strict concurrency and warnings as errors.

Risk surface: cancellation ordering, process-tree teardown, mount cleanup,
runtime shutdown, and RunRegistry finalization.

## Phase 11: Replace movable Swift pthread storage in `ImageDecodeQueue`

**Status: Complete.**

Implemented with a dedicated `NucleusBlockingSynchronizationC` target whose
opaque heap allocation owns the pthread mutex and condition variable.
`ImageDecodeQueue.WorkerState` now owns only a Swift reference to that stable
handle. Ordinary critical sections use one `withLock` façade; the worker wait
loop explicitly locks, waits, and unlocks against the same C-owned mutex.

The generation ledger, cancellation rules, completion-burst wake coalescing,
worker-creation fallback, and dedicated decode threads are unchanged. Shutdown
sets the stopping state and clears pending work under the lock, broadcasts,
joins every created worker, and releases the final state reference so the
synchronization allocation is destroyed before shutdown returns.

All 20 focused image-decode queue tests and the full 84-test core renderer
product pass. The release renderer target builds, and the expanded
ThreadSanitizer harness passes concurrent submission/cancellation plus 128
idle, active, pending, cancelled, multi-worker, and no-worker construction and
destruction cycles.

### 11.1 Introduce a stable blocking synchronization owner

Keep the dedicated decode-worker model and condition-based blocking.
`Synchronization.Mutex` alone does not replace a condition variable.

Move the pthread mutex and condition variable into an opaque heap-allocated C
synchronization object with create, lock, wait, signal, broadcast, unlock, and
destroy operations. Swift owns one stable opaque handle for the worker state's
lifetime. No pthread object remains inline in a movable Swift property.

Wrap ordinary critical sections in a Swift `withLock` helper. Keep condition
waits in the worker loop, where the same C-owned mutex is released and reacquired
atomically.

### 11.2 Preserve queue shutdown and wake semantics

Retain the generation ledger, cancellation behavior, completion-burst
coalescing, and join-on-destruction contract.

Shutdown:

1. sets `running = false` under the lock;
2. clears pending work;
3. broadcasts;
4. joins every created worker;
5. destroys the synchronization object.

Do not replace the dedicated worker with unbounded detached tasks or a
cooperative-executor blocking loop.

### 11.3 Acceptance gates

- Submission deduplication and generation-safe cancellation preserve behavior.
- Completion bursts produce one wake until drained.
- Shutdown succeeds while idle, decoding, and holding pending work.
- Worker-creation failure retains inline fallback behavior.
- Repeated construction and destruction pass ThreadSanitizer stress.
- Renderer image-decode tests and sanitizer-supported queue gates pass.

Risk surface: lock/wait ownership, shutdown ordering, thread join, and fallback
execution.

## Preserved verified invariants

Do not change these paths without new failing evidence:

- Vulkan dma-buf import fd ownership transfers only through successful
  `vkAllocateMemory`. Pre-allocation failures close the fd; post-success paths
  do not.
- `DrmPageFlipToken` remains retained through both binding-retirement paths
  until late kernel callbacks can no longer reference it.
- React Native `Unmanaged` retain/release pairs remain balanced, including the
  text-layout-manager handle when Fabric installation never consumes it.
- `LinuxHostReactor` retains its SPSC ordering, context-generation ledger, and
  deferred-completion budget protocol.

The RN command-handler phase preserves C++ shared-entry ownership while
correcting actor delivery. The GPU phase preserves dma-buf ownership while
correcting in-process Vulkan lifetime.

## Master completion criteria

The master plan is complete when:

- released Android GPU buffers return to baseline without GPU teardown and no
  queue, layout, submission, or retirement state is concurrently mutated;
- sparse commits do not visit unrelated retained-tree nodes;
- malformed topology cannot hang a public tree operation;
- RN host commands arrive on the main actor with balanced context ownership;
- ring endpoints encode direction, allocate one returned packet buffer, and
  pass arm/recheck stress without per-message notification writes;
- frame resource discovery occurs once and each unique dependency resolves at
  most once;
- every Collider command leaf exposes only its declared capabilities;
- normal Collider commands are parsed once and carry typed operations through
  implementation boundaries;
- run resumption derives only from the parsed command;
- `TaskEngine.swift` contains only the generic engine;
- validation fixtures live as packaged resource trees;
- Collider has one asynchronous executable, no synchronous-over-async bridge,
  and no child that outlives its structured owner;
- image decode workers no longer pass inline Swift-stored pthread objects by
  address;
- all phase-specific host build, test, benchmark, qualification, resource,
  strict-concurrency, and sanitizer gates pass.
