# Collider Repository CLI Plan

## Invariant

`collider` is the sole public developer and build-control entry point for the
Nucleus repository. It owns command parsing, workflow planning, artifact
identity, invalidation, locking, logging, validation, retention, and atomic
publication across every first-party component.

All first-party workflow policy and orchestration is Swift. Collider launches
leaf tools as an executable plus an argument vector and never constructs a
shell command string. `tools/collider` is the only first-party bootstrap shell
entry point. An upstream shell program remains only when the upstream build
system itself requires that program; it receives all paths, environment,
lifecycle, logging, validation, and publication policy from Collider.

Component packages continue to own their code and leaf build recipes. SwiftPM,
Gradle, CMake/Ninja, GN/Siso, and the upstream Swift build system remain
execution engines. They do not independently define public workflows, logs,
locks, generations, or publication policy.

The Collider executable is a lightweight control-plane product. It does not
link the render core, `NucleusLinuxPlatform`, the session implementation,
React Native, Chromium, or another product graph merely to parse a command or
run a prerequisite check. It depends only on control-plane libraries and
recipe targets whose dependency graphs contain no product implementation.

Replaced entry points are deleted when their behavior lands in Collider. There
is no `tools/nucleus` compatibility wrapper and no second orchestration path.

## Current Assessment

The root Swift workspace executable is the correct starting point for Collider.
It already contains the repository-level command model, process execution,
runtime launch, profiling, audits, Android, Chromium, and toolchain adapters.
Rename and restructure that implementation instead of introducing a second CLI
and later reconciling them.

The current architecture splits ownership of the same concerns across four
layers: the `tools/nucleus` bootloader, the root Swift executable, component
shell and Python orchestrators, and SwiftPM command plugins. Several of those
layers independently choose environment variables, acquire locks, compute
fingerprints, create timestamped logs, retain generations, and update active
pointers. A command can therefore succeed according to one layer while leaving
another layer with stale state or no usable diagnostic trail.

The first structural problem is the root executable's product dependency graph.
A repository control plane cannot depend on the runtime implementation it is
responsible for bootstrapping. The second is the absence of one typed artifact
graph: ordering exists procedurally in several scripts, but input identity,
validation, publication, and rollback are not shared abstractions. The third is
that component-specific launchers are treated as public workflows instead of
leaf recipes invoked inside one run.

The fourth problem is that process execution, descriptor ownership, hashing,
locking, and publication are implemented piecemeal with `Foundation.Process`,
shell pipelines, Python helpers, and platform scripts. Collider needs one Swift
runtime built on typed system and subprocess primitives rather than another
layer of wrappers around those implementations.

Preserve the mature parts of the current setup: component ownership, upstream
build engines, native SDK boundaries, immutable generation directories, and
candidate validation. Collider unifies the policy and lifecycle around those
parts; it does not become a replacement compiler, package manager, or meta-build
engine.

## Surface Collider Subsumes

| Area | Current owner | Collider destination |
| --- | --- | --- |
| Workspace bootstrap, build, and test | `tools/nucleus`, `NucleusWorkspace` | Typed component graph under `collider bootstrap`, `build`, and `test` |
| Toolchain and host environment selection | `tools/host-env.sh` and component environment scripts | One toolchain resolver and child-environment builder |
| Host prerequisite checks | `Doctor.swift`, Chromium doctor shell code, toolchain scripts | One capability registry exposed by `collider doctor` |
| Third-party downloads | `curl` invocations and component download helpers | One in-process `ColliderDownloads` service with HTTPS, resumption, size, and digest policy |
| Runtime assembly and launch | `Install.swift`, `Run.swift`, profiling and sanitizer helpers | `collider install session` and `collider run` |
| Tracy, Valgrind, sanitizers, and benchmarks | `ProfileCapture.swift`, `Profiling.swift`, `Sanitizer.swift`, `Benchmark.swift` | Shared instrumentation model used by `run`, `test`, and `benchmark` |
| API, native ABI, and linkage gates | `PublicAPIAudit.swift`, `CrossLanguageABI.swift`, API-tier and libc++ verification scripts | `collider audit api|abi|linkage` |
| Swift host toolchain and Android SDK | `Toolchain.swift`, `swift-toolchain/*.sh`, `swift-android-sdk/*.sh` | One platform-generation graph under `collider toolchain` |
| Android host | `Android.swift`, Gradle wrapper, Swift Android helper scripts | `collider android build|native|verify` |
| Chromium, CEF, and browser installation | `Chromium.swift`, Chromium/CEF shell orchestrators and Python metadata tools | `collider browser doctor|bootstrap|build|test|install` |
| Skia, Hermes, React Native, and code generation | SwiftPM command plugins and component scripts | `collider generate` and graph-owned bootstrap nodes backed by shared component recipes |
| Vulkan and Wayland regeneration | SwiftPM command plugins and `tools/update-vendored.sh` | `collider generate vulkan|wayland` |
| Compositor diagnostics | Vulkan validation and freeze-capture scripts | `collider diagnose compositor` and `collider validate vulkan` |
| Cache inspection and retention | `.nucleus/`, Chromium pruning, toolchain fingerprints, per-script cleanup | `collider cache status|prune` with typed ownership |
| Run discovery | Several timestamp formats and `latest` links | One run registry exposed by `collider logs` and `collider status` |

## Command Model

The initial complete command surface is:

```text
collider doctor [all|runtime|toolchain|android|browser]
collider bootstrap [all|runtime|browser|COMPONENT]
collider build [all|runtime|toolchain|android|browser|COMPONENT]
collider test [all|runtime|android|browser|COMPONENT]
collider run [runtime, instrumentation, and session options]
collider install session|browser
collider toolchain rebuild|status|install|uninstall [options]
collider android build|native|verify [options]
collider browser doctor|bootstrap|build|test|install
collider generate rn-spec|vulkan|wayland [options]
collider audit api|abi|linkage
collider benchmark [SUITE]
collider diagnose compositor [freeze-capture options]
collider validate vulkan
collider cache status|prune
collider logs list|show|tail [RUN] [--kind KIND]
collider status
```

Commands accept the same global controls:

- `--dry-run` prints the resolved task graph without executing it.
- `--explain` reports why every selected task is clean or dirty.
- `--verbose` streams leaf command lines and full stage output.
- `--json` emits stable machine-readable status and result records.
- `--run-id` selects an existing interrupted run for explicit resumption when
  every recorded input identity still matches.

Runtime instrumentation remains a single composable option model. `run`
supports duration, output scale, presentation mode, DRM device, wallpaper,
Vulkan validation, diagnostics, Tracy capture, Valgrind, and sanitizers without
separate launch paths.

## Package Topology

The reusable control-plane libraries live in a dependency-leaf first-party
package at `collider/`. The root package contains only the executable
composition and repository-wide command assembly. This direction prevents a
SwiftPM package cycle when component recipe targets consume `ColliderCore` and
the root executable consumes those recipes.

- `Collider` is the executable entry point. It declares the command tree with
  Swift Argument Parser, constructs the single runtime, and translates parsed
  arguments into workflow requests. It remains in the root package.
- `ColliderCommands` remains in the root package. It owns repository command
  definitions and assembles tasks from component recipes. It does not contain
  a second process, digest, filesystem, lock, log, or artifact implementation.
- `ColliderCore` owns the pure `Sendable` domain model: task declarations,
  dependency graphs, artifact and run identifiers, events, validation results,
  stable manifest schemas, typed command specifications, and `DownloadSpec`.
  It uses `SystemPackage.FilePath` as the path currency but contains no
  subprocess, HTTP transport, descriptor operation, hashing implementation, or
  platform implementation. It lives in the `collider/` package.
- `ColliderRuntime` is the sole executor of `ColliderCore` operations. It owns
  child processes, environments, clocks, digests, filesystem access, locks,
  logs, run persistence, validation execution, and publication. It lives in the
  `collider/` package and has no dependency on a component package.
- `ColliderDownloads` is the sole HTTP download implementation. It owns one
  policy-constrained `URLSession`, redirect and response validation, resumable
  transfer state, progress events, candidate files, and download diagnostics.
  It lives in the `collider/` package and is internal to `ColliderRuntime`.
- `ColliderPlatformC` is a minimal C target for platform calls not publicly
  exposed by Swift System, including advisory locking and durability barriers.
  It contains no orchestration policy and lives in the `collider/` package.

```text
root Collider executable
├── root ColliderCommands ──> component recipe products ──> ColliderCore
└── ColliderRuntime ──────────────────────────────────────> ColliderCore
    ├── Subprocess ──> SystemPackage
    ├── ColliderDownloads ──> Foundation URLSession
    │   ├── Crypto
    │   └── SystemPackage
    ├── Crypto
    └── ColliderPlatformC

collider/ package ──X──> component packages
```

Each owning package exposes a dependency-light recipe target, such as a runtime,
Swift-platform, Android, or browser recipe target. Recipe targets depend only on
the `ColliderCore` product from the relative `collider/` package; they describe
tasks and parse leaf results without importing the component implementation or
`ColliderRuntime`. The root `ColliderCommands` target composes them into the
complete repository graph. The `collider/` package never depends back on those
component packages.

The session configuration and readiness wire records live in a separate
`NucleusSessionProtocol` target. Collider and `nucleus-session` both depend on
that target; neither depends on the other.

The root-managed third-party source contains Swift Argument Parser,
Swift Subprocess, Swift Crypto, and the repository's single Swift System copy.
Swift System moves from `core/third-party/swift-system` to
`third-party/swift-system`; every first-party package and Swift Subprocess
resolves `SystemPackage` from that one source. All four packages are relative
dependencies, so building `collider doctor` never performs network dependency
resolution.

`ColliderCore` depends on `SystemPackage` for `FilePath`. `ColliderRuntime`
depends on the `Subprocess`, `SystemPackage`, and `Crypto` products. It uses
only Swift Crypto's `Crypto` product; `CryptoExtras` is not in the graph. The
cost of Swift Crypto's Linux BoringSSL/XKCP implementation is accepted because
content hashing is a pervasive control-plane primitive and must not spawn a
checksum process per input.

`ColliderDownloads` uses `URLSession` from Foundation on Darwin and
FoundationNetworking on Linux. It introduces no additional package dependency.
On Linux this removes the `curl` executable and subprocess boundary, while the
toolchain-provided FoundationNetworking implementation continues to use its
libcurl transport backend. Collider owns the complete download policy above
that transport.

SwiftNIO is not part of the Collider dependency graph. Swift Subprocess already
owns asynchronous child-pipe I/O, Swift System owns low-level descriptors, and
Dispatch owns parent signal sources. URLSession supplies the required HTTP
client without NIO, NIOSSL, HTTP/2, logging, tracing, or service-lifecycle
packages. Collider is not a network server, and its current workflows do not
justify a second event-loop runtime or NIO's experimental filesystem product.
A future remote cache or daemon introduces a separate protocol architecture
rather than adding NIO to the local task engine.

SwiftPM plugins that must remain invoke a small component-owned executable tool
which links the same recipe library; plugin source does not duplicate the
recipe.

## Execution Model

Collider resolves each command into typed tasks. Every task declares:

- A stable task identifier and owning component.
- Ordered dependencies.
- Source, configuration, toolchain, patch, and environment inputs that affect
  its artifacts.
- Produced files, directories, manifests, and active-generation pointers.
- Required exclusive locks.
- The leaf command or in-process operation that performs the work.
- The validation that makes the result publishable.

Tasks carry typed in-process operations or a `ColliderCore.CommandSpec`. A child
command contains a typed executable reference, argument vector,
`SystemPackage.FilePath` working directory, explicit environment, input/output
policy, process-group policy, timeout, and teardown sequence. ColliderRuntime
translates that value into `Subprocess.Executable` at the execution boundary.
No task stores shell syntax, performs word splitting, or invokes `sh -c` or
`bash -c`.

### Process Runtime

`ColliderRuntime` wraps Swift Subprocess directly. Every non-interactive leaf
task receives its own process group so cancellation and timeout teardown reach
all descendants. Parent `SIGINT`, `SIGTERM`, and terminal-control signals arrive
through Dispatch signal sources and are forwarded to the active process group.
Timeouts use `ContinuousClock`; expiration cancels the structured task and runs
the declared graceful-to-forced teardown sequence.

The process closure consumes stdout and stderr as bounded asynchronous byte
sequences. One log actor applies backpressure, writes the stage log, appends the
run log, emits structured output events, and mirrors bytes to the terminal when
requested. Per-stream order is preserved. Tasks that require one exact combined
order connect stderr to stdout in the child before collection. Captured output
always declares a byte limit and reports overflow as a typed task failure.

Interactive runtime commands explicitly inherit terminal descriptors. Detached
session commands explicitly create their session and readiness descriptors.
There is no `Foundation.Process` fallback and no second process implementation.

### Artifact Identity

`ColliderRuntime` computes every content identity with streaming
`Crypto.SHA256`. `ArtifactDigest` stores the algorithm and bytes and serializes
as `sha256:<lowercase-hex>`. Manifests never contain an unlabelled digest.

Digest input uses one versioned canonical binary framing with explicit field
tags and lengths. Task identities include the task schema version, ordered
dependency identities, normalized arguments, the allowlisted artifact
environment, resolved tool identities, configuration, and declared source
trees. A tree identity walks sorted relative path bytes and hashes each entry's
kind, executable permissions, symlink target, and file contents. It does not
hash timestamps, ownership, credentials, or incidental shell state. Relevant
uncommitted contents participate directly rather than being represented only by
a repository revision.

Digest equality proves identity against a declared value; it is not a signature
or an independent authenticity claim. Collider adds signing only when a future
signed-artifact trust model defines key ownership, rotation, and revocation.

A task is clean only when its recorded identity matches and every declared
output passes its structural validation. Interrupted tasks retain resumable
outputs only when the task explicitly declares them safe to resume.

### Download Runtime

Every downloaded input is a `DownloadSpec` declared by its owning recipe. The
specification contains the initial HTTPS URL, permitted redirect origins,
expected SHA-256 digest, maximum response size, accepted media types, request
and inactivity timeouts, bounded retry policy, and resumption policy. A recipe
cannot declare an unverified or unlimited download.

`ColliderDownloads` is an actor-backed service around one dedicated ephemeral
`URLSession`. It disables URL caching, cookies, automatic credential storage,
and persistent website data. It uses the platform trust store and exposes no
certificate-validation bypass. URLs with embedded credentials are rejected.
Requests send `Accept-Encoding: identity`, and a response with another content
encoding is rejected so the pinned digest always names the received archive
bytes.

Redirects are handled by the session delegate. Every hop must remain HTTPS,
must target an origin listed in the `DownloadSpec`, and consumes one step from a
fixed redirect limit. Authorization and cookie headers never cross an origin.
A complete transfer accepts only status `200`; a resumed transfer accepts only
a validated `206` with the requested `Content-Range`. Other successful-looking
responses are typed download failures.

The common Darwin and Linux implementation uses `URLSessionDownloadTask`, not
Darwin-only asynchronous byte APIs. Foundation streams each response to a
temporary file. The delegate validates response headers, reports progress,
cancels when the declared size is exceeded, and immediately transfers the
completed temporary file into a private Collider candidate. Collider then
checks the actual file size and streams the candidate through `Crypto.SHA256`.
A digest mismatch deletes the candidate before extraction or publication.

Resumable transfers store a partial file plus non-secret metadata keyed by the
expected artifact digest: original and final URLs, ETag, Last-Modified value,
received byte count, and total size. A resumed request sends `Range` and
`If-Range`; Collider appends only after a matching `206` and `Content-Range`.
If the validator, range, origin, or total size differs, Collider discards the
partial file and restarts from zero. Opaque URLSession resume data is not a
durable Collider format.

Retries apply only to idempotent GET requests and declared transient transport
or HTTP failures. Cancellation, policy rejection, size overflow, malformed
range responses, and digest mismatch are terminal. Download manifests record
the redirect chain, validators, response size, final digest, and diagnostic
status, but never request credentials or secret headers.

### Filesystem, Locks, and Publication

Collider uses Swift System paths, descriptors, permissions, and typed `Errno`
values for control-plane filesystem operations. The minimal platform C target
supplies only missing advisory-lock, atomic-rename, and `fsync`/directory-sync
operations. Foundation remains available for Codable and other value-level
facilities; `FileManager` does not define lock or publication semantics.

Publication is one crash-durable primitive. Collider assembles on the target
filesystem into a private candidate, validates it, synchronizes written files,
moves it into an immutable generation with an atomic rename, synchronizes the
containing directory, atomically replaces the active pointer, and synchronizes
that directory. Runtime prefixes, Swift platform generations, CEF SDKs, browser
distributions, and browser installations use the same state machine.

Locks are descriptor-backed and held for the full mutation or publication
scope. A diagnostic ownership record names the process, run, task, and start
instant, but deleting that record never breaks a live kernel lock. Collider
does not delegate locking, renaming, symlink activation, or durability to shell
utilities.

## State, Cache, and Logs

Repository workflow state lives under `.nucleus/`:

```text
.nucleus/
  state/                 task identity and result records
  locks/                 locks for checkout-local state and artifacts
  runs/<run-id>/
    manifest.json        command, arguments, environment identity, result
    run.log              complete ordered output
    stages/<task>.log    task-local output
    events.jsonl         structured task lifecycle records
  latest -> runs/<run-id>
```

Large source trees, compiler caches, build outputs, and immutable distribution
generations remain under their owning package or `$XDG_CACHE_HOME/nucleus`.
Collider records those paths but never duplicates large artifacts into
`.nucleus/`.

Resumable download state lives under
`$XDG_CACHE_HOME/nucleus/downloads/sha256/<digest>/` with a partial file and its
validator metadata. The expected digest is the cache identity. Completion moves
the verified file into the owning task's candidate or immutable shared download
object; `.nucleus/` retains only the run and task records that reference it.

Lock scope follows artifact scope. Checkout-local tasks lock under
`.nucleus/locks`; tasks that mutate a shared cache, source generation, or active
platform generation lock beside that shared state under `$XDG_CACHE_HOME`.
This prevents two checkouts from concurrently publishing the same toolchain,
native SDK, Chromium source generation, or browser distribution.

Run identifiers use one UTC timestamp format plus the process identifier. The
`latest` pointer updates atomically when a run starts. Each manifest records the
final status, failed task, durable diagnostic path, task durations, and active
artifact identities. `collider logs show latest --kind runtime|toolchain|android|browser`
resolves the newest matching manifest from the same registry, so an unrelated
doctor or build command cannot hide the latest domain-specific diagnostic.

Leaf processes receive a minimal allowlisted base environment plus the task's
declared additions; Collider does not forward the interactive session wholesale.
A centralized credential scrub is a second defense applied before any child can
serialize its environment. Both policies cover Chromium, Swift toolchain,
Android, profiling, and runtime workflows.

## Component Recipe Boundary

Human-facing SwiftPM command plugins stop being independent workflows. Each
component exposes one reusable recipe implementation with a typed input and a
machine-readable result. A thin SwiftPM plugin may call the same implementation
when package-manager integration is required, while Collider remains the only
documented repository entry point.

Component recipe targets remain dependency-light and must not import their
component's runtime or native implementation targets. Runtime session
configuration and readiness records move into a small protocol target shared
by Collider and `nucleus-session`; Collider no longer imports
`NucleusLinuxSession` to encode launch configuration or decode readiness.

The following remain leaf executors rather than being reimplemented:

- SwiftPM compilation and test commands.
- Gradle and the Android Gradle Plugin.
- GN and Siso/autoninja for Chromium-owned Ninja graphs.
- CMake and Ninja for native dependencies.
- The upstream Swift `build-script` product graph.
- Upstream CEF distribution generation.
- Upstream archive tools for formats Collider does not implement.
- Runtime session, compositor, shell, and browser executables.

First-party shell and Python adapters are temporary. Their argument assembly,
environment construction, fingerprints, metadata, pruning, locking, logging,
validation, retention, and publication move into Swift in the phase that owns
the workflow. An unavoidable upstream script remains an opaque leaf command;
Collider invokes it directly without a first-party shell wrapper and retains
all lifecycle and artifact policy.

Upstream utilities inside first-party-owned `third-party/` trees are not
Collider commands. Collider invokes the narrow upstream leaf tools required by
a declared recipe; it does not mirror or wrap the rest of Skia, React Native,
Hermes, Folly, or Chromium's internal developer surfaces.

## Phase 1: Establish the Collider Binary

Rename the root executable product and target to `collider`. Replace the manual
top-level parser with typed subcommands, options, validation, generated help,
and shell completion.

Create the dependency-leaf `collider/` package with `ColliderCore`,
`ColliderRuntime`, `ColliderDownloads`, and `ColliderPlatformC`. Keep
`ColliderCommands` and the `Collider` executable in the root package. Establish
the acyclic dependency direction before component recipe targets begin
consuming `ColliderCore`.

Place Swift Argument Parser, Swift Subprocess, Swift Crypto, and Swift System in
the root-managed third-party source and consume them only through relative
package dependencies. Move the existing Swift System source to
`third-party/swift-system` and update its existing consumers in the same phase;
there is one `SystemPackage` identity in the complete package graph.

Remove the root package's dependency on `NucleusLinuxPlatform`. Extract the
session configuration and readiness wire types into the dependency-free
protocol target, then make both Collider and the session executable consume
that target. Verify that `collider doctor --help` builds in a checkout with no
render SDK, React Native SDK, browser source tree, or runtime installation.

Add `tools/collider` as the minimal bootstrap launcher. It resolves the
workspace, selects the bootstrap or active Nucleus Swift toolchain, incrementally
builds the Collider binary, and executes it. It contains no workflow policy.

Delete `tools/nucleus` and rename `NucleusWorkspace` source and test targets as
part of this phase. Runtime product names such as `nucleus-compositor` and
`nucleus-shell` do not change.

## Phase 2: Build the Shared Runtime

Replace the current synchronous process helper and every direct
`Foundation.Process` call with the single Swift Subprocess-backed runtime.
Implement typed commands, minimal environments, process groups, inherited and
captured descriptors, bounded asynchronous output, log teeing, Dispatch signal
forwarding, `ContinuousClock` timeouts, structured cancellation, and declared
graceful-to-forced teardown. Delete the replaced process APIs and fix every
caller in this phase.

Implement Swift System-backed paths, descriptor ownership, temporary files,
permissions, and descriptor-backed locks. Add only the missing advisory-lock,
atomic-rename, and durability operations to `ColliderPlatformC`. No first-party
script owns the Collider run registry, its state files, or its locks after this
phase; component-local state disappears in that component's migration phase.

Add the run registry, structured event stream, atomic `latest` pointer,
credential scrubbing, file locks, and stable result schema. Move every existing
Collider command onto these primitives before adding new workflows.

## Phase 3: Add the Task Graph and Artifact State Machine

Introduce typed task declarations, dependency resolution, content identities,
output validation, dry-run rendering, invalidation explanations, and safe
resumption.

Introduce the versioned canonical digest encoder and the streaming
Swift Crypto-backed `ArtifactDigest`. Apply it to task inputs, file and tree
contents, tools, manifests, downloaded archives, and generation identities.
Replace command-specific fingerprints and external checksum implementations
when their owning recipe lands on this engine.

Introduce `DownloadSpec`, durable partial-download metadata, redirect records,
validator-aware range resumption, retry classification, and download manifests.
Key download state by the expected artifact digest and keep credentials outside
all state and identity records.

Implement `ColliderDownloads` with a dedicated ephemeral URLSession, delegate-
owned redirect and response validation, progress events, bounded download tasks,
private candidates, explicit cancellation, and typed diagnostics. Use
FoundationNetworking on Linux and Foundation on Darwin. Do not add SwiftNIO,
AsyncHTTPClient, or a `curl` subprocess fallback.

Introduce the shared private-candidate, validated-generation, atomic-activation
publication primitive with file and directory durability barriers. Delete the
existing `.nucleus/state` and `.nucleus/artifacts` layouts when the new schema
lands; the first Collider run creates new state. Do not add a legacy-layout
reader or migration path.

## Phase 4: Migrate Runtime Workflows

Move workspace doctor, bootstrap, build, test, API audit, ABI audit, sanitizer,
benchmark, runtime installation, session launch, Tracy capture, Valgrind, and
runtime diagnostics into typed Collider tasks.

Port first-party argument construction, environment policy, download
verification, archive staging, installation, diagnostics, and metadata from the
workspace shell helpers into Swift. Move every workspace download to
`ColliderDownloads`, delete its `curl` invocation and external checksum path,
and invoke `swift`, `git`, archive tools, profilers, and runtime products
directly as typed child commands.

Replace component-name string switches with a component registry that declares
package paths, products, dependencies, build commands, tests, native SDK needs,
and supported audits. Preserve the repository's required dependency order in
the resolved graph.

## Phase 5: Migrate Swift Platform and Android Workflows

Make Collider the sole owner of Swift platform generation paths, locks, logs,
component identities, validation, Android SDK wiring, rollback, retention, and
activation.

Move system toolchain installation and uninstallation behind a narrow
privileged helper. Collider resolves and validates the immutable generation as
the invoking user, then passes only the artifact identity and explicit target
paths across the privilege boundary. The full Collider process never runs as
root.

Move host-toolchain and Android SDK orchestration into Swift recipes. Retain
only upstream build programs that cannot be expressed as direct executable
invocations. Remove the scripts' independent run metadata, outer locks,
fingerprints, package publication, and active-pointer updates. Feed leaf output
and phase events into the enclosing Collider run.

Move Android host build and ELF/JNI validation into the same platform graph so
the selected host toolchain, Swift Android SDK, NDK, and produced application
library have one recorded identity chain.

## Phase 6: Migrate Chromium, CEF, and Browser Workflows

Move Chromium host checks, source-generation identity, locks, run lifecycle,
stage execution, build metadata, storage reporting, cache retention, candidate
assembly, validation, publication, and installation into Collider.

Keep GN and Siso/autoninja as the Chromium leaf executor. Keep upstream CEF
automation as the CEF leaf executor. Delete the Bash orchestration layer and
port the Python metadata, pruning, and atomic-publication behavior into typed
Swift models with direct tests.

Represent CEF and the browser as separate artifact tasks sharing one immutable
source generation. Preserve their deliberate sequential build order.

## Phase 7: Migrate Generators and Component Bootstrap Recipes

Expose Skia, React Native specification generation, Hermes, React Native native
libraries, Vulkan headers, and Wayland protocols through Collider tasks.

Move each SwiftPM command plugin's implementation into component-owned shared
recipe code. Retain only thin plugin adapters required by SwiftPM. Delete direct
shell entry points after Collider and the plugin adapter consume the shared
recipe.

## Phase 8: Complete Repository Cutover

Delete every superseded public script, duplicated log implementation, duplicated
lock, duplicated active-generation updater, and stale workflow state file.

Update repository instructions and automation to invoke `tools/collider` only.
Delete every first-party orchestration shell and Python program. Reject direct
execution of a remaining upstream leaf script unless Collider provides its
orchestration environment. `tools/collider` remains the only first-party shell
entry point and contains only bootstrap logic. Remove `curl` and host checksum
executables from Collider's prerequisite contract.

## Phase 9: Qualify the Complete Control Plane

Test parser behavior, task ordering, literal argument transport, environment
isolation, failure propagation, stdout/stderr backpressure, output limits,
process-group signal forwarding, timeout teardown, cancellation races, and
descriptor closure.

Test canonical digest framing, streaming large files, executable-bit and
symlink identities, timestamp independence, uncommitted-content invalidation,
manifest round trips, lock contention, log durability, resume eligibility,
credential scrubbing, candidate rollback, crash injection across every
publication boundary, atomic activation, and cache retention.

Test downloads against controlled loopback HTTP and HTTPS services: allowed and
rejected redirects, HTTPS downgrade rejection, status handling, missing and
incorrect lengths, size overflow, identity content encoding, cancellation,
bounded retry, truncated bodies, ETag and Last-Modified resumption, invalid
ranges, changed validators, digest mismatch rejection, temporary-file cleanup,
and redaction of credentials from events and manifests.

Run the complete doctor, bootstrap, build, test, audit, sanitizer, benchmark,
toolchain, Android, Chromium, CEF, browser-package, and installation gates
through Collider. Perform the compositor session and graphical browser checks
as the final user-owned interactive validation.

The cutover is complete when no documented repository operation requires a
direct SwiftPM plugin command, component shell script, Python orchestration
tool, or the old workspace executable.
