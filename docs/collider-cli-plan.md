# Collider Repository CLI Plan

## Invariant

`collider` is the sole public developer and build-control entry point for the
Nucleus repository. It owns command parsing, workflow planning, artifact
identity, invalidation, locking, logging, validation, retention, and atomic
publication across every first-party component.

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

The root package contains a small composition root and two reusable control
plane targets:

- `Collider` is the executable entry point. It declares the command tree and
  translates parsed arguments into workflow requests.
- `ColliderCore` owns processes, child environments, task graphs, artifact
  identities, runs, events, locks, validation results, and publication.
- `ColliderCommands` owns repository command definitions and assembles tasks
  from component recipes. It does not contain a second process or artifact
  implementation.

Each owning package exposes a dependency-light recipe target, such as a runtime,
Swift-platform, Android, or browser recipe target. These targets describe tasks
and parse leaf results without importing the component implementation. The root
`ColliderCommands` target composes them into the complete repository graph.

The session configuration and readiness wire records live in a separate
`NucleusSessionProtocol` target. Collider and `nucleus-session` both depend on
that target; neither depends on the other.

Swift Argument Parser is pinned as a root-managed third-party submodule and used
through a relative package dependency. Building `collider doctor` never needs a
network dependency resolution. SwiftPM plugins that must remain invoke a small
component-owned executable tool which links the same recipe library; plugin
source does not duplicate the recipe.

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

The task engine computes content identities before execution. A task is clean
only when its recorded identity matches and every declared output passes its
structural check. Timestamp changes do not invalidate artifacts by themselves.
Source identities include relevant uncommitted file contents, not only repository
revisions. Environment identities include an explicit allowlist of
artifact-affecting variables and resolved tool versions; credentials and
incidental shell state never enter an identity or manifest.
Interrupted tasks retain resumable outputs only when the task explicitly
declares them safe to resume.

Publication is a shared primitive. Collider assembles into a private candidate,
validates the candidate, moves it into an immutable generation, and atomically
updates the active pointer. Runtime prefixes, Swift platform generations, CEF
SDKs, browser distributions, and browser installations use the same state
machine.

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
- Runtime session, compositor, shell, and browser executables.

Shell and Python code that only adapts one of these engines remains beside its
component until an equivalent typed Swift recipe lands. It is internal, receives
all paths and policy from Collider, and does not acquire its own outer lock,
create a separate run, or publish an artifact.

Upstream utilities inside first-party-owned `third-party/` trees are not
Collider commands. Collider invokes the narrow upstream leaf tools required by
a declared recipe; it does not mirror or wrap the rest of Skia, React Native,
Hermes, Folly, or Chromium's internal developer surfaces.

## Phase 1: Establish the Collider Binary

Rename the root executable product and target to `collider`. Replace the manual
top-level parser with typed subcommands, options, validation, generated help,
and shell completion. Add the pinned Swift Argument Parser source as a
root-managed submodule and relative package dependency.

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

Replace the current synchronous process helper with one process runtime that
supports inherited output, captured output, stage log teeing, cancellation,
signal forwarding, timeouts, and exact termination diagnostics.

Add the run registry, structured event stream, atomic `latest` pointer,
credential scrubbing, file locks, and stable result schema. Move every existing
Collider command onto these primitives before adding new workflows.

## Phase 3: Add the Task Graph and Artifact State Machine

Introduce typed task declarations, dependency resolution, content identities,
output validation, dry-run rendering, invalidation explanations, and safe
resumption.

Introduce the shared private-candidate, validated-generation, atomic-activation
publication primitive. Delete the existing `.nucleus/state` and
`.nucleus/artifacts` layouts when the new schema lands; the first Collider run
creates new state. Do not add a legacy-layout reader or migration path.

## Phase 4: Migrate Runtime Workflows

Move workspace doctor, bootstrap, build, test, API audit, ABI audit, sanitizer,
benchmark, runtime installation, session launch, Tracy capture, Valgrind, and
runtime diagnostics into typed Collider tasks.

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

Reduce the host-toolchain and Android SDK scripts to internal leaf recipes.
Remove their independent run metadata, outer locks, package publication, and
active-pointer updates. Feed their phase events into the enclosing Collider run.

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
Reject direct execution of any remaining internal leaf script unless Collider
provides its orchestration environment.

## Phase 9: Qualify the Complete Control Plane

Test parser behavior, task ordering, content invalidation, failure propagation,
signal forwarding, timeout handling, lock contention, log durability, resume
eligibility, credential scrubbing, candidate rollback, atomic activation, and
cache retention.

Run the complete doctor, bootstrap, build, test, audit, sanitizer, benchmark,
toolchain, Android, Chromium, CEF, browser-package, and installation gates
through Collider. Perform the compositor session and graphical browser checks
as the final user-owned interactive validation.

The cutover is complete when no documented repository operation requires a
direct SwiftPM plugin command, component shell script, Python orchestration
tool, or the old workspace executable.
