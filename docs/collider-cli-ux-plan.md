# Collider CLI, Terminal UX, and TUI Foundations Plan

## Invariant

Collider has one execution model, one typed run-event model, one output policy, one headless observation and control model, and one human presentation layer.

Every command writes requested machine data to stdout, human diagnostics and progress to stderr, and complete task output to durable per-run logs. Interactive child processes retain direct terminal ownership. Non-interactive task output streams to the invoking terminal by default while the durable log remains the authoritative replay source.

The CLI is verb-first. Parser types describe valid domains, invalid command combinations fail during parsing, and replaced spellings are deleted with their callers in the same phase. The task graph remains the source of truth for dependency selection, caching, execution, resumption, and reporting.

The persistent interactive TUI is not implemented by this plan. The plan does implement every non-terminal foundation the TUI consumes: versioned snapshots and events, incremental run discovery, replayable state reduction, indexed log access, cross-process control, a language-neutral external observation protocol, and machine-readable command equivalents. Starting TUI development after this plan requires only a protocol client, terminal input, layout, widgets, and screen rendering; it does not require changing execution, persistence, logs, control, or command semantics.

Status: active

## Current Progress

Collider already owns typed task planning, durable run manifests and logs,
structured failures, cancellation-aware child-process teardown, cache
diagnostics, and machine-readable command output. Those are prerequisites, not
phase completion evidence for this plan. The external observation/control
protocol, incremental readers, branch-scoped task cancellation, anchored
console renderer, and headless dashboard contract have not passed their phase
gates. No phase in this document is currently marked complete, and
`collider-ratatui-tui-plan.md` remains blocked on Phase 9.

## Final User Contract

### Output behavior

Collider exposes four disclosure levels:

| Level | Behavior |
| --- | --- |
| `-q` | Print only the terminal result or failure block. |
| Default | Show framed task progress and stream leaf output under the active task. |
| `-v` | Add scrubbed resolved commands and working directories. |
| `-vv` | Add scrubbed environment deltas and detailed runtime diagnostics. |

The output contract is:

- stdout contains only the report requested by `--format`.
- stderr contains human progress, warnings, remediation, and failures.
- `--format=text` is the default.
- `--format=json` writes one stable final JSON value to stdout.
- `--events=<path>` writes versioned NDJSON events to the selected path.
- `--events=-` writes NDJSON to stdout and is rejected when `--format=json` is also selected.
- `--color=auto|always|never` defaults to `auto`.
- `--progress=auto|always|never` defaults to `auto`.
- `auto` progress requires an interactive stderr terminal and a usable terminal type.
- `NO_COLOR`, `CLICOLOR_FORCE`, and `TERM=dumb` participate in automatic capability resolution.
- Redirected and CI output is append-only and contains no cursor-control sequences.
- Log paths remain plain usable paths even when an OSC 8 hyperlink is also emitted.

`--json` is removed. Machine-readable final reports use `--format=json`; streaming automation uses `--events`.

### Failure behavior

A task failure prints one structured block containing:

- Run ID
- Failed task ID
- Operation and command index
- Exit status or terminating signal
- Scrubbed executable and arguments
- Working directory
- The last 30 logical lines of the stage log, bounded by bytes
- Full stage-log path
- Exact resumable command when the run is resumable

The first SIGINT, SIGTERM, or SIGHUP starts graceful child teardown and prints the active teardown state. A second terminating signal immediately kills remaining child process groups. Collider returns `128 + signal` for signal termination, `2` for parser and usage failures, `69` for unmet host prerequisites, and `1` for task or workflow failure.

An explicit task cancellation is branch-scoped. Collider cancels the selected incomplete task and every incomplete transitive dependent, allows independent branches to finish, records the run as `cancelled`, and preserves the completed clean state that can be reused when the run resumes.

### Human progress behavior

Interactive build-style commands use an anchored stderr frame without the alternate screen:

- Run ID and elapsed time
- Completed and total task counts
- Active tasks and their elapsed times
- Download byte count, rate, and ETA when total size is known
- A bounded tail of active leaf output at `-v`

Completed task lines move into append-only scrollback. The renderer restores the terminal before returning, throwing, or responding to a signal. Interactive `.terminal` child commands suspend the anchored frame and receive the real terminal descriptors until the child exits.

Every task run ends with a summary in this form:

```text
14 tasks · 11 clean · 3 executed · 2m14s
```

Executed tasks over the configured display threshold are listed with duration. Quiet mode omits the duration list.

### TUI foundation behavior

The completed plan does not add `collider ui` or enter raw or alternate-screen terminal mode. It does provide a headless dashboard client with the same capabilities the future TUI requires:

- Discover current and historical runs.
- Attach to a run after any known event sequence.
- Reconstruct task, download, artifact, failure, and wait state.
- Follow state changes without polling complete files.
- Page, follow, and search ongoing or historical task logs with bounded memory.
- Inspect command boundaries and stdout/stderr attribution.
- Request graceful or forced cancellation through a typed local protocol.
- Preview and cancel one task's incomplete dependent branch while independent work continues.
- Resume an interrupted run from its typed invocation.

These capabilities are usable from Swift APIs, the external observer protocol, and stable noninteractive CLI commands. The future TUI adds a protocol client, presentation, and input only.

### Command topology

Shared operations are verb-first:

```text
collider doctor [all|runtime|toolchain|android|browser|vulkan]
collider bootstrap [all|runtime|browser|<component>]
collider build [all|runtime|toolchain|android|android-native|browser|<component>]
collider test [all|runtime|android|browser|<component>] [--lane <lane>]
collider check <android|android-runtime-source-lock>
collider generate <rn-spec|vulkan|wayland>
collider install <session|compositor|shell|browser|toolchain> [--prefix <path>]
collider uninstall toolchain [--prefix <path>]
collider status [toolchain] [--watch]
collider runs <list|show|cancel|resume>
collider runs cancel <run-id> [--task <task-id>] [--force]
collider events tail <run-id> [--after-sequence <sequence>]
collider tasks [--operation <operation>] [--component <component>] [--format text|json]
collider graph <operation> [target] [--format text|json|dot]
collider cache <status|prune>
collider logs <list|show|tail|path>
collider run [session options] [-- <compositor arguments>]
collider qualify android-presentation [qualification options]
```

The following old trees and aliases are removed:

- `browser doctor|bootstrap|build|test`
- `android build|native|verify`
- `toolchain rebuild|status|install|uninstall`
- `validate vulkan`
- `android-runtime source-lock|source|image`
- The top-level single-child `validate` namespace

Specialized Android runtime control operations that do not share a repository-wide verb remain under `android-runtime`, including `android-runtime framework-boot`.

`test android` executes Android tests and validation. It never aliases `build android`. If no genuine Android test declaration exists when this topology lands, `test android` is omitted until that declaration is implemented.

`doctor` is limited to fast, read-only host and workspace readiness checks with remediation. Artifact and workflow integrity checks use `check`. Build-dependent verification never runs as part of `doctor`.

Components, aggregates, operations, doctor scopes, check targets, generator targets, install targets, and test lanes are separate parser enums. Help output never advertises a value that the selected command rejects at runtime.

## Architectural Boundaries

### Presentation

Add a `ColliderConsole` implementation in `ColliderCommands`. It owns Collider-authored stdout and stderr writes but never claims ownership of descriptors passed directly to an interactive child.

The console contains:

- Descriptor-specific terminal capability detection
- Color and progress policy resolution
- Terminal-width observation through `TIOCGWINSZ`
- `SIGWINCH` resize handling
- Plain append-only rendering
- Anchored-frame rendering
- Structured report rendering
- Failure-block rendering
- Path hyperlink rendering
- Credential-safe command rendering

All existing command-side `print()` calls move behind the console or a typed report renderer. Fixture programs under runtime resources are not part of this migration.

Console dependencies are injected. Tests use in-memory descriptors and explicit terminal capabilities; they do not inspect source declarations.

### Durable run events

Replace the stringly `ColliderEvent.message` model with a versioned `RunEvent` envelope in `ColliderCore`:

```swift
struct RunEvent: Codable, Sendable {
    let schemaVersion: Int
    let sequence: UInt64
    let timestamp: String
    let runID: RunID
    let payload: Payload
}
```

`Payload` has typed cases for:

- Run started, resumed, and finished
- Plan resolved
- Task queued, started, skipped, succeeded, failed, and cancelled with a typed cancellation reason
- Task progress with completed units, total units, unit label, and optional phase
- Operation and command started and finished
- Task duration recorded
- Download started, progressed, and finished
- Lock wait started and finished
- Artifact validated and published
- Graceful interruption started
- Forced interruption started

Failure payloads carry structured status, signal, task, operation, scrubbed command metadata, and log paths. Download payloads carry digest, received bytes, optional expected bytes, and stable download identity. Renderers calculate rate and ETA from monotonic local samples; those derived display values are not persisted as authoritative state.

Task progress is emitted only by operations with authoritative completed and total units. Opaque external build commands expose state, elapsed time, command metadata, and activity without a fabricated percentage.

Durable events remain low-volume. Download progress is coalesced before persistence by byte and time thresholds. Compiler and build-tool output is never copied into `events.jsonl`.

An actor-owned `RunEventHub` assigns sequence numbers and sends each event in order to registered sinks. The run registry is one sink. The console is another sink. An explicitly requested NDJSON destination is another sink. Sink failure policy is explicit:

- Registry persistence failure fails the run because resumability and diagnostics are part of the execution contract.
- Explicit `--events` destination failure fails the run because the user requested a machine output.
- Console rendering failure disables enhanced rendering, restores terminal state, and falls back to plain stderr.

### Live command output

Add a separate bounded `LiveOutputSink` interface for command stdout and stderr chunks. `CommandOutputSink` continues to write complete scrubbed bytes to `run.log` and the stage log, then forwards bounded chunks to the live sink.

The live sink:

- Preserves stdout/stderr identity.
- Associates every chunk with a task and command index.
- Uses bounded memory per active task.
- Drops old display chunks rather than blocking a child process.
- Records truncation in the renderer.
- Is not part of the durable event schema.

### Structured execution failure

Replace `RuntimeFailure.commandFailed(status:)` at the task boundary with a structured `TaskExecutionFailure`. It contains:

- `task`
- `operationIndex`
- `commandIndex`
- `status`
- `signal`
- `timedOut`
- Scrubbed executable and arguments
- Working directory
- Stage log path
- Underlying runtime failure description

Nested `TaskOperation.sequence` execution propagates indices. Non-command operation failures use the same envelope without command fields.

The registry never derives failed-task state from the final outer error. Task failure records it once, and `finish` preserves an existing failed task unless a non-nil replacement is supplied.

### Invocation and resumption

Introduce a typed `RunInvocation` after parsing and before run creation. It stores:

- Canonical command path
- Canonical typed arguments
- Presentation options excluded from task identity
- Task execution options included where they affect execution
- Post-terminator arguments
- Credential-scrubbed display argv

The invocation generates the exact resume command. Resumption does not splice strings into the original command line.

Only commands conforming to a `TrackedRunCommand` seam create run registry entries. `status`, `logs`, `cache status`, task discovery, and graph inspection do not create runs and no longer require filtering themselves out of repository history.

### Headless observation model

Add a presentation-independent observation library consumed by plain CLI commands now and the deferred TUI later. It exposes:

- `RunRepository`: discover, resolve, and retain run records.
- `RunEventReader`: replay or follow events after a sequence cursor.
- `RunStateReducer`: reduce a manifest and ordered events into an immutable dashboard snapshot.
- `RunRepositoryWatcher`: emit added, changed, and removed run IDs.
- `StageLogReader`: read bounded windows, tails, and searches by byte cursor.
- `RunControlClient`: inspect and control a live run through its local control endpoint.

The immutable snapshot model includes:

- Workspace summary
- Current and historical runs
- Canonical invocation and resumption state
- Plan and aggregate counts
- Task state, dependencies, cache assessment, duration, and wait reason
- Active command metadata
- Downloads and byte progress
- Artifacts and output paths
- Failure detail
- Log descriptors and cursors

`RunStateReducer` is the only code that derives a dashboard view from events. The anchored console, `status --watch`, JSON commands, and the future TUI consume the same snapshots. Historical replay and live following therefore produce the same state for the same event prefix.

The observation library has no dependency on ArgumentParser, terminal descriptors, ANSI rendering, or `ColliderCommands`.

### External observation protocol

The future TUI is a separate Rust process and does not use Swift FFI or decode Collider's internal run directory directly. Add a dependency-light `collider-observer` Swift executable that exposes `ColliderObservability` through a versioned NDJSON request, response, and notification protocol over stdin and stdout.

The normative protocol lives under `collider/protocol/` as language-neutral JSON Schema documents for:

- Envelope and protocol negotiation
- Requests
- Responses
- Notifications
- Workspace and run snapshots
- Task, download, artifact, failure, and log records
- Event and log cursors
- Typed errors

Every message carries an exact protocol version. Requests and responses carry request IDs. Notifications carry stable run IDs plus event-sequence or log-byte cursors. Unknown fields are tolerated, unknown message kinds return a typed error, oversized messages are rejected, and credentials never enter the protocol.

The initial observer operations are:

- Negotiate protocol version and capabilities
- List and watch runs
- Fetch workspace, run, and task snapshots
- Subscribe to a run after an event sequence
- Read, follow, and search a task log by byte cursor
- Request graceful or forced cancellation
- Resume an interrupted run from its typed invocation

`collider-observer` has no recipe, ArgumentParser, terminal, ANSI, or product-runtime dependency. Its stdout is protocol-only and its diagnostics go to stderr. It exits when stdin closes and does not become a daemon. The future Rust TUI launches one observer for the selected workspace and supplies the absolute version-matched public `collider` path.

For resumption, the observer launches `collider runs resume <run-id>` through that absolute path in a new process group with no inherited protocol or terminal descriptors. The resumed run remains independent if the observer or TUI exits. The observer does not link command implementations.

Swift protocol conformance tests validate every emitted message against the schemas and round-trip golden fixtures. The later Rust plan consumes the same schemas and fixtures. Exact version mismatch fails with a rebuild/reinstall diagnostic; no compatibility translation layer is added.

### Incremental journals and logs

`RunEventReader` reads complete NDJSON records incrementally, validates schema version and sequence continuity, tolerates an incomplete final line while a writer is active, and resumes from a caller-supplied sequence cursor. It distinguishes temporary end-of-file from a finished run.

`RunRepositoryWatcher` uses filesystem notifications as a wake-up mechanism and performs periodic directory reconciliation for correctness. Notifications never become authoritative state.

Each stage log gains a durable metadata journal. Metadata entries associate scrubbed byte ranges with:

- Task ID
- Operation and command index
- stdout or stderr
- Monotonic append sequence
- Command boundary
- Optional wall timestamp

The text log remains the durable source for output bytes. The metadata journal is the durable source for stream and command attribution. A separate sparse line-offset index accelerates paging and is disposable and rebuildable from the text log. All three files are removed alongside their run. `StageLogReader` never loads an entire log into memory and never interprets terminal control sequences while searching.

### Cross-process run control

Each active tracked run exposes a versioned Unix-domain control socket inside its run directory with owner-only permissions. The executing Collider process owns the socket and removes it during orderly shutdown. Stale sockets are identified from manifest status and process liveness.

The initial protocol supports:

- Ping
- Fetch current live snapshot
- Preview the affected closure of a task cancellation
- Request graceful cancellation
- Request forced cancellation
- Request graceful cancellation of one task branch
- Request forced cancellation of one task branch

Every request and response has a request ID, protocol version, typed payload, and typed error. Cancellation uses the same runtime cancellation path as signals; it does not introduce a second teardown mechanism.

Completed-run resumption uses the stored typed `RunInvocation`, not the live socket. `collider runs resume <run-id>` executes that invocation through the same command runner as an explicitly entered command.

Task cancellation semantics are fixed:

- The selected task must be pending, ready, waiting, or running.
- The cancellation closure contains the selected task and every incomplete transitive dependent.
- Completed, skipped, and already-cancelled tasks remain unchanged.
- Dependencies and unrelated branches are not cancelled.
- No new task in the cancellation closure starts after the request is accepted.
- A running selected task receives targeted graceful cancellation; `force` hard-terminates only process groups owned by tasks in the closure.
- Tasks cancelled directly use reason `userRequested`.
- Descendants use reason `dependencyCancelled` and name the nearest cancelled dependency.
- The scheduler continues independent work, then finishes the run as `cancelled`.
- Cancelled runs are resumable. Completed clean tasks remain reusable and the cancelled branch is assessed and executed normally.
- Cancellation never treats partial outputs as a valid completed task state.

Every observation and control capability has a stable noninteractive command. No fact or action is reserved for the future TUI.

### Executable and module boundaries

Split the current monolithic `ColliderCommands` target into dependency-directed Swift library targets:

- `ColliderCommandSupport`
- `ColliderPresentation`
- `ColliderWorkspaceCommands`
- `ColliderToolchainCommands`
- `ColliderBrowserCommands`
- `ColliderAndroidCommands`
- `ColliderSessionCommands`
- `ColliderCLI`

`ColliderCLI` owns root parsing and imports the command modules. Shared execution, presentation, and observability types remain below command modules. Domain modules depend only on their required recipe products.

Keep ordinary operational commands in the single user-facing `collider` executable. Module separation improves dependency ownership, incremental invalidation, and focused testing without introducing helper-version or dispatch failure modes. It does not claim to reduce the complete clean-build dependency closure because `ColliderCLI` still exposes every command.

Extract the privileged Android entry points into minimal private executables with only their required runtime dependencies. Install private helpers in an absolute versioned libexec directory and resolve them from the installed Collider cohort, never from `PATH`. The public `collider` process uses `exec` so the helper receives the terminal, signals, and final exit status directly.

Do not split ordinary commands into separate binaries in this plan. Record per-target compile time, incremental rebuild time, link time, peak linker memory, and installed size after module separation. A later coarse binary split requires measured evidence and uses domain binaries rather than one binary per subcommand.

## Phase 1 — Establish the Output and Error Contracts

### Implementation

1. Add `OutputFormat`, `ColorPolicy`, `ProgressPolicy`, and `OutputVerbosity` value types.
2. Add reusable `PresentationOptions`, `TaskExecutionOptions`, and `ReportOptions` parser groups. Embed only the groups supported by each leaf command.
3. Change task verbosity from a Boolean to `OutputVerbosity`.
4. Add an output-routing abstraction with distinct stdout and stderr writers.
5. Route final reports to stdout and all human diagnostics to stderr.
6. Add credential-safe renderers for commands and environment deltas.
7. Replace `--json` at every command leaf with `--format=json`.
8. Add `--events`, `--color`, and `--progress` validation.
9. Preserve `.terminal` as an explicit interactive command mode.
10. Rename non-interactive output modes to state their behavior:
    - `.streamAndLog`
    - `.logOnly`
    - `.file`
    - `.capture`
    - `.combineAndCapture`
    - `.terminal`
11. Require task recipe helpers to select their output policy explicitly. Repository task commands use `.logOnly`.
12. Remove the implicit machine-readable override that currently changes command output to `.logged`.

### Files and structures

- `collider/Sources/ColliderCommands/CommandSupport.swift`
- `collider/Sources/ColliderCommands/ColliderCommand.swift`
- New console/output files under `collider/Sources/ColliderCommands/`
- `collider/engine/Sources/ColliderCore/Model.swift`
- `collider/engine/Sources/ColliderRuntime/ColliderRuntime.swift`
- All first-party `*ColliderRecipe` constructors

### Verification

- A text report contains no JSON.
- A JSON report contains one valid JSON value on stdout and no progress text on stdout.
- Redirected stderr contains no ANSI or cursor movement in automatic mode.
- `NO_COLOR`, `CLICOLOR_FORCE`, and `TERM=dumb` resolve deterministically.
- Interactive child commands retain stdin, stdout, stderr, job-control signals, and terminal dimensions.
- Secrets in argv and environment values do not appear in verbose output or logs.
- Existing task behavior remains unchanged apart from presentation and default leaf-output visibility.

## Phase 2 — Introduce Typed Run Events and Correct Run Lifecycle

### Implementation

1. Replace `ColliderEvent` with the versioned typed `RunEvent` envelope.
2. Add a presentation-independent `ColliderObservability` target and product to `collider/engine`.
3. Define immutable, `Codable`, `Sendable` snapshot types for workspace, run, task, download, artifact, failure, log, and control state.
4. Implement `RunStateReducer` as a pure reducer from an ordered event prefix to an immutable run snapshot.
5. Add `RunEventSink` and actor-owned `RunEventHub`.
6. Move sequence assignment from `RunRegistry` into `RunEventHub`.
7. Make `RunRegistry` persist events delivered by the hub.
8. Add an NDJSON sink for `--events`.
9. Convert download progress from a formatted message into typed fields.
10. Emit typed operation, command, authoritative task-progress, and artifact events.
11. Coalesce persisted byte and unit progress without coalescing phase or completion transitions.
12. Emit plan size, clean count, and dirty count when planning completes.
13. Add `TrackedRunCommand` and stop creating runs for observational commands.
14. Preserve `failedTask` during finalization.
15. Record the terminating signal rather than a Boolean interrupted flag.
16. Add `cancelled` to `RunStatus` and allow failed, interrupted, and cancelled runs to resume.
17. Add typed task cancellation reasons and affected-task IDs to run events and snapshots.
18. Extend the run manifest with schema version, typed invocation, exit classification, cancellation summary, and total duration.
19. Replace the local run-record schema directly. Existing raw log files remain readable by path, but old manifests and event files are not carried through a compatibility decoder.

### Files and structures

- `collider/engine/Sources/ColliderCore/RunRecords.swift`
- `collider/engine/Sources/ColliderObservability/`
- `collider/engine/Sources/ColliderRuntime/RunRegistry.swift`
- `collider/engine/Sources/ColliderRuntime/ColliderRuntime.swift`
- `collider/engine/Sources/ColliderRuntime/RuntimeCancellation.swift`
- `collider/Sources/ColliderCommands/ColliderCommand.swift`
- `collider/Sources/ColliderCommands/RepositoryState.swift`

### Verification

- Event sequence numbers are ordered and unique under concurrent producers.
- Replaying the same event prefix always produces the same immutable snapshot.
- Registry and explicit NDJSON sinks receive semantically identical events.
- New run history is readable through `status` and `logs`; old raw log files remain intact on disk.
- `status`, `logs`, and discovery commands do not create run directories.
- A failed task remains in the finished manifest.
- A cancelled run preserves its cancellation closure and reason without manufacturing a failed task.
- Unknown download size is represented as `nil`, not embedded text.
- Event sink failures follow the declared failure policy.

## Phase 3 — Make Failures and Interruptions Actionable

### Implementation

1. Add `TaskExecutionFailure`.
2. Thread task, operation, and command indices through task execution.
3. Record the executable, arguments, working directory, status, signal, timeout state, and log path when a leaf fails.
4. Add `RunInvocation` and canonical resume-command generation.
5. Add a bounded UTF-8-safe stage-log tail reader.
6. Render the standard failure block.
7. Change runtime cancellation to retain the first terminating signal and a terminating-signal count.
8. On the first signal:
    - Emit interruption-started.
    - Stop scheduling new work.
    - Forward the signal to active process groups.
    - Begin the existing graceful teardown sequence.
9. On the second terminating signal:
    - Emit forced-interruption-started.
    - Send SIGKILL to remaining process groups.
    - Cancel outstanding operations.
10. Map parser, prerequisite, task, and signal failures to the defined exit statuses.
11. Ensure terminal restoration runs before failure or interruption output.

### User-visible failure form

```text
FAILED  core.build
status: 1
command: swift build --package-path core
working directory: /workspace/core

… bounded stage-log tail …

log: /workspace/.nucleus/runs/<run>/stages/core-build.log
resume: collider build core --run-id <run>
```

### Verification

- A failing command reports the correct task and working directory.
- A failure inside a sequence reports its exact operation and command index.
- The manifest, failure block, status command, and resume command agree on the failed task.
- The resume command reparses into the same execution selection.
- Post-terminator arguments survive resume-command generation.
- SIGINT exits 130 and SIGTERM exits 143.
- A second interrupt hard-terminates remaining process groups.
- Failure tails remain valid UTF-8 and respect byte and line bounds.

## Phase 4 — Build the Console Renderer

### Implementation

1. Implement descriptor-specific `isatty` detection.
2. Resolve color and progress policies.
3. Read terminal width with `TIOCGWINSZ`.
4. Route `SIGWINCH` to the console instead of forwarding it blindly to every child process group. Forward it only to the foreground interactive child.
5. Implement the append-only renderer used for non-TTY output.
6. Implement the bottom-anchored frame for interactive stderr.
7. Add `LiveOutputSink` and connect it to command logging.
8. Drive the console from `RunStateReducer` snapshots.
9. Implement task lifecycle lines, active elapsed timers, task counts, and run elapsed time.
10. Implement download bars, rate, and ETA.
11. Suspend and restore the frame around `.terminal` commands.
12. Add OSC 8 hyperlinks while retaining visible paths.
13. Move all Collider-authored `print()` sites behind the console or typed report renderers.

### Rendering rules

- The alternate screen buffer is never used.
- Cursor control is emitted only to interactive stderr with progress enabled.
- Completed tasks are printed once into scrollback.
- The frame redraws only when content changes and at a capped refresh rate.
- Width truncation preserves task suffixes that distinguish lanes and preserves elapsed values.
- Output received while a task is not visible remains available in its stage log.
- At `-v`, each streamed line is prefixed or framed with its task identity.
- At `-vv`, command and environment-delta lines are emitted once per leaf invocation.

### Verification

- Snapshot tests cover 40-, 80-, and 160-column terminals.
- Resize tests preserve a valid frame.
- Ctrl-C, thrown errors, and normal exit leave no anchored frame behind.
- Piped output is append-only.
- Concurrent task output remains attributable to the correct task.
- Slow renderer tests prove child output cannot block on display.
- Interactive child programs retain correct foreground-terminal behavior.

## Phase 5 — Surface Cache Decisions and Run Summaries

### Implementation

1. Replace the rolled-up-only task state with explicit input fingerprint records.
2. Persist fingerprints for:
    - Named values
    - Environment inputs
    - Files
    - Trees
    - Optional trees and their fallback identities
    - Dependency outputs
    - Resolved tools
    - Dependency task identities
    - The operation declaration
3. Give every fingerprint a stable kind and display label.
4. Compare prior and current fingerprints during assessment.
5. Return structured `TaskAssessment` reasons instead of strings.
6. Render all changed declared inputs with a bounded default list and a count of omitted entries.
7. Distinguish:
    - No prior state
    - Declared input changed
    - Dependency identity changed
    - Tool changed
    - Operation changed
    - Output missing
    - Output validation failed
    - Always-run policy
8. Do not persist per-file manifests for every tree in this phase. The stable unit of explanation is the declared tree input, which avoids unbounded state for Chromium, AOSP, and vendored trees.
9. Aggregate plan, execution, skip, failure, and duration events into a final run summary.
10. Render the cache footer and slow-task list.
11. Include the same structured assessments and summary in JSON reports.

### Example

```text
dirty  core.build
       tree core/swift changed
       tool swift changed
clean  vulkan.build
       identity and outputs are valid
```

### Verification

- Changing one declared file names that file input.
- Changing a declared tree names that tree input.
- Changing a dependency names the dependency task.
- Changing the resolved compiler names the tool.
- Deleting an output reports the exact validation failure.
- Old task-state records decode as a one-time unknown prior identity and are replaced after successful execution.
- Summary counts match the plan and lifecycle events.
- Duration reporting uses monotonic measurements for the current process.

## Phase 6 — Normalize Command Topology and Parser Domains

### Implementation

1. Split `ComponentSelection` into dedicated parser types:
    - `BuildTarget`
    - `BootstrapTarget`
    - `TestTarget`
    - `TestLane`
    - `DoctorScope`
    - `CheckTarget`
    - `GeneratorTarget`
    - `InstallTarget`
    - `StatusTarget`
2. Make verb-first commands canonical.
3. Move browser operations into `doctor`, `bootstrap`, `build`, `test`, and `install`.
4. Move toolchain operations into `build`, `install`, `uninstall`, and `status`.
5. Map `android native` to `build android-native`.
6. Implement a genuine `test android` task selection. Remove the command until that selection exists.
7. Move Android artifact validation to `check android`.
8. Move the AOSP source lock to `check android-runtime-source-lock`.
9. Move Vulkan-layer discovery to `doctor vulkan`.
10. Collapse generator leaf structs into `generate <target>`.
11. Collapse runtime installer leaf structs into `install <target>`.
12. Retain `android-runtime framework-boot` as a specialized control command.
13. Delete removed namespace structs, special-case branches, aliases, and unreachable validation failures.
14. Group `run` options into:
    - `SessionOptions`
    - `InstrumentationOptions`
    - `BuildOptions`
15. Share the applicable session, presentation, build, and diagnostics groups with `qualify android-presentation`.
16. Replace manual `--no-build` inversion state with ArgumentParser inversion.
17. Move shared command context, option, invocation, and report types into `ColliderCommandSupport`.
18. Move console and human report rendering into `ColliderPresentation`.
19. Split workspace, toolchain, browser, Android, and session commands into the domain library targets declared by the executable-boundary architecture.
20. Make `ColliderCLI` the only module that imports every command domain.
21. Extract the privileged Android entry points into minimal private executable targets.
22. Replace the hidden in-process privileged dispatch with absolute versioned-libexec resolution followed by `exec`.
23. Keep ordinary operational commands in the single public `collider` executable.
24. Update setup help and completion generation for the new topology.
25. Add build instrumentation that records per-target compile time, incremental rebuild time, link time, peak linker memory, and installed binary size.

### Parser requirements

- Invalid targets fail during argument parsing.
- A lane is accepted only by `test` and only for a compatible target.
- `gpu-drm`, `gpu-headless`, and `loader` are compositor test lanes, not components.
- Aggregates such as `all` and `runtime` are not components.
- Options appear in help only where they have defined behavior.
- Removed spellings have no compatibility aliases or deprecated wrappers.

### Verification

- Parser tests cover every valid target and lane.
- Parser tests cover invalid cross-domain values.
- `build browser` and `test browser` reach the browser task graph without special cases in the root command.
- `test android` executes test/validation declarations distinct from `build android`.
- `doctor` performs no build-dependent operation.
- Shared run and qualification options resolve identically.
- Generated shell completions contain only the canonical topology.
- Domain command targets depend only on the recipe products they use.
- Changing one command domain does not recompile unrelated command-domain modules.
- Privileged helpers do not link recipe, browser, toolchain, session, presentation, or observability code.
- Public privileged dispatch preserves signals, terminal ownership, and helper exit status.
- Missing or mismatched private helpers produce a precise installation-integrity failure.
- The complete clean-build and incremental-build measurements are retained as Collider build diagnostics.

## Phase 7 — Add Task and Graph Discovery

### Implementation

1. Add a public read-only task catalog from `TaskGraph`.
2. Add `collider tasks` with operation and component filters.
3. Add `collider graph` with text, JSON, and DOT renderers.
4. Include task ID, component, dependencies, cache policy, locks, output paths, and declared input labels.
5. Add repeatable `--task <task-id>` to graph-driving commands.
6. Define `--task` as selecting a root plus its complete dependency closure.
7. Add repeatable `--exclude-task <task-id>`.
8. Reject an exclusion when any selected task transitively requires it.
9. Reject task IDs that are not part of the selected operation graph.
10. Include explicit task selection in task identity-independent invocation metadata and resumption.
11. Do not add a dependency-bypassing `--only`.
12. Do not add `--skip`.
13. Do not add `--since` in this phase.
14. Keep raw post-terminator passthrough only on commands with one documented downstream recipient. Do not add aggregate passthrough.

### Verification

- Task output is stable and sorted.
- DOT output parses with Graphviz.
- Selecting a root includes every transitive dependency exactly once.
- Invalid task IDs fail before run creation.
- Required dependencies cannot be excluded.
- Resume preserves explicit task roots and exclusions.
- Discovery commands do not mutate task state or create run records.

## Phase 8 — Add Dependency-Aware Parallel Scheduling

### Scheduler contract

The scheduler is a deterministic dependency-ready executor. `--jobs <n>` limits concurrently running Collider tasks and defaults to `1`. The conservative default prevents task-level concurrency from oversubscribing SwiftPM, Ninja, Gradle, Chromium, and AOSP build systems that already schedule their own workers.

Tasks transition through:

```text
pending → ready → waitingForResource → running → succeeded
                                            ↘ failed
                                            ↘ cancelled
pending|ready|waitingForResource              → cancelled
```

### Implementation

1. Replace the serial ordered-task loop with dependency counts and reverse dependency edges.
2. Preserve the existing stable graph order as the ready-queue tie breaker.
3. Add an async in-process resource arbiter for `TaskLock` keys.
4. Acquire in-process resources before dispatching a task.
5. Acquire filesystem locks only after the resource arbiter grants the task. Filesystem locks continue to protect separate Collider processes.
6. Never block a cooperative executor thread waiting on `flock`.
7. Release task resources immediately after task validation, persistence, and terminal event emission.
8. Limit active tasks with `--jobs`.
9. Treat `.terminal` tasks as requiring an exclusive terminal resource.
10. Add an actor-owned `TaskCancellationController` that tracks cooperative task cancellation handles and child process groups by task ID.
11. Invalidate the prior task-state record immediately before a dirty task begins mutating outputs. Persist a new record only after successful validation.
12. Add a deterministic graph operation that previews the selected task's incomplete transitive-dependent closure.
13. Serialize cancellation acceptance, task completion, and scheduler transitions through the scheduler actor so a task cannot complete and accept cancellation simultaneously.
14. On accepted task cancellation:
    - Stop dispatching every task in the cancellation closure.
    - Gracefully cancel running tasks in the closure.
    - Mark the selected task `userRequested`.
    - Mark incomplete descendants `dependencyCancelled`.
    - Keep dependencies and independent branches eligible to run.
    - Drain all unaffected work.
    - Finish the run as `cancelled`.
15. On forced task cancellation:
    - Hard-terminate only process groups registered to running tasks in the cancellation closure.
    - Cooperatively cancel non-process operations in the closure.
    - Preserve the same closure and final run status as graceful task cancellation.
16. Reject cancellation of unknown, clean, succeeded, failed, or already-cancelled tasks with a typed state error.
17. Emit queued, resource-wait, start, completion, failure, cancellation-accepted, and cancellation-completed events. Cancellation preview remains a read-only graph query and emits no event.
18. On first task failure:
    - Stop dispatching new tasks.
    - Cancel pending and ready tasks.
    - Gracefully cancel active tasks.
    - Drain active task completion.
    - Persist one primary failure and any secondary teardown failures.
19. Keep failure fail-fast semantics distinct from user-requested branch cancellation.
20. Make task-state writes independent and atomically replace each task record.
21. Keep run-event sequence assignment actor-serialized.
22. Render multiple active tasks without interleaving unattributed output.
23. Include peak concurrency, resource-wait durations, and cancellation summary in the final report.

### Verification

- Independent tasks overlap when `--jobs` exceeds one.
- Dependencies never overlap incorrectly.
- Conflicting task locks serialize within one process.
- Conflicting filesystem locks serialize across Collider processes.
- Ready-task dispatch order is stable across repeated runs.
- One failure stops new dispatch and tears down active children.
- Cancelling a pending task prevents it and its incomplete descendants from starting.
- Cancelling a running task stops its work and incomplete descendants while independent branches finish.
- Dependencies of a cancelled task are not cancelled.
- Forced task cancellation never signals an unrelated task process group.
- The cancellation preview exactly matches the accepted cancellation closure.
- A completion/cancellation race has one actor-serialized terminal result.
- Partial outputs from a cancelled task cannot satisfy a stale task-state record.
- A cancelled run resumes the cancelled branch while retaining reusable completed tasks.
- Concurrent completion cannot corrupt task state, manifests, events, or logs.
- `--jobs 1` retains serial execution semantics.
- Interactive terminal tasks never overlap another terminal-owning task.
- Concurrency tests use bounded synthetic tasks and behavioral assertions.

## Phase 9 — Complete the Headless TUI Foundations

### Implementation

1. Move run discovery and resolution out of `ColliderCommands.RepositoryState` into `ColliderObservability.RunRepository`.
2. Add `RunSnapshotLoader` to combine manifest state with reduced ordered events.
3. Implement `RunEventReader` with:
    - Schema validation
    - Sequence validation
    - `afterSequence` cursors
    - Partial-final-record handling
    - Live follow
    - Finished-run termination
4. Implement `RunRepositoryWatcher` with filesystem wake-ups and periodic reconciliation.
5. Add durable stage-log metadata records at the command-output sink.
6. Add the disposable sparse line-offset index.
7. Implement bounded `StageLogReader` operations:
    - Read tail by line and byte limit
    - Read forward or backward from a byte cursor
    - Follow appended bytes
    - Search literal text without loading the full log
    - Jump to command boundaries
8. Expose log stream and command metadata without adding presentation escape sequences to the text log.
9. Rebuild a missing or corrupt sparse line index from the text log. Preserve readable raw output when durable metadata is missing and report attribution as unavailable.
10. Add the versioned owner-only Unix-domain run-control socket.
11. Route graceful and forced control requests into `RuntimeCancellation`.
12. Add `RunControlClient`.
13. Add the normative JSON Schema protocol documents under `collider/protocol/`.
14. Add Swift request, response, notification, capability, cursor, and typed-error envelopes in `ColliderObservability`.
15. Validate Swift encodings against the schemas and add golden fixtures for every message kind and error.
16. Add the dependency-light `collider-observer` executable target.
17. Implement protocol negotiation, request correlation, ordered notifications, message-size limits, and clean stdin-closure shutdown.
18. Require absolute workspace and public-Collider paths at observer startup.
19. Route observer requests only through `RunRepository`, `RunRepositoryWatcher`, `RunEventReader`, `RunSnapshotLoader`, `StageLogReader`, and `RunControlClient`.
20. Expose task-cancellation preview, graceful branch cancellation, and forced branch cancellation through `RunControlClient` and the observer protocol.
21. Implement resumption by launching the version-matched public Collider command in a new process group without inherited observer or terminal descriptors.
22. Add noninteractive command twins:
    - `collider runs list --format=text|json`
    - `collider runs show <run-id> --format=text|json`
    - `collider runs cancel <run-id> [--task <task-id>] [--force] --format=text|json`
    - `collider runs resume <run-id>`
    - `collider events tail <run-id> [--after-sequence <sequence>]`
    - `collider logs show <run-id> --task <task-id> [--lines <count>]`
    - `collider logs tail <run-id> --task <task-id> [--after-byte <offset>]`
    - `collider logs search <run-id> --task <task-id> <text> --format=text|json`
23. Make `status --watch` a projection of `RunRepositoryWatcher` and `RunStateReducer`; remove direct manifest polling and shelling out to `tail -f`.
24. Include event-sequence and log-byte cursors in JSON and NDJSON responses.
25. Define retention behavior for open readers:
    - Readers retain open descriptors while a run is pruned.
    - New reads of a pruned run return a typed not-found result.
    - Watchers emit run removal.
26. Add an in-memory repository, event source, clock, log source, control transport, and observer transport for deterministic clients and tests.
27. Add a headless dashboard harness that:
    - Lists historical runs.
    - Attaches to an active run.
    - Replays its events.
    - Follows task and download changes.
    - Reads and searches task logs.
    - Previews and requests task-branch cancellation.
    - Requests cancellation.
    - Resumes an interrupted run.
28. Run the same headless dashboard harness through the in-process Swift API and the external observer protocol and require identical snapshots, cursors, and control results.
29. Keep all APIs and protocol messages free of terminal, ANSI, key-binding, layout, and widget concepts.

### AI-agent contract

- JSON snapshots are complete and versioned.
- NDJSON changes have monotonically increasing sequence numbers.
- Reconnecting after a known event sequence does not require replaying the entire run.
- Log readers expose stable byte cursors.
- Every run, task, command, download, artifact, and log has a stable identifier.
- Human text is never required to determine state.
- Every control action returns a typed result and a meaningful exit status.
- Task cancellation preview and execution return the same stable affected-task IDs.
- TUI actions have exact CLI equivalents.
- Control commands work without a TTY.
- Observing a run never mutates it.
- Machine clients never parse the anchored console or future TUI screen.
- External clients never decode private run-directory files or open active run-control sockets directly.
- Protocol stdout never contains diagnostics or human progress.

### Verification

- Historical event replay and live event delivery produce identical snapshots for the same event prefix.
- Event following reconnects from every sequence boundary without duplication or omission.
- An incomplete final NDJSON record is retried rather than treated as corruption.
- New runs become visible without restarting a watcher.
- Pruned runs disappear cleanly while existing open readers remain safe.
- Multi-gigabyte synthetic logs can be tailed, paged, and searched with bounded memory.
- Log byte cursors remain stable as a log grows.
- stdout and stderr ranges remain attributable to the correct command.
- A second process can inspect and gracefully cancel a running invocation.
- A second process can preview and cancel one running task branch without stopping independent work.
- Forced cancellation uses the established hard-termination path.
- Unauthorized control-socket access is rejected by filesystem permissions.
- Stale control sockets are reported without treating the run as live.
- JSON and NDJSON fixtures decode independently of terminal configuration.
- The headless dashboard harness exercises the complete future-TUI data and action flow without a terminal renderer.
- Every observer message validates against the normative schema.
- In-process and external-protocol harness runs produce identical observable results.
- Protocol version mismatch, oversized input, malformed JSON, unknown requests, and observer shutdown return defined outcomes.
- `collider-observer` links no recipe or command-domain module.

## Phase 10 — Complete Operational UX

### Implementation

1. Add `logs path [run-id] [--task <task-id>]`.
2. Include waiting states in `status --watch`, including dependency, jobs-limit, and resource-lock waits.
3. Improve doctor rendering:
    - Group checks by scope.
    - Align status columns.
    - Attach one concrete remediation to every failed check.
    - Include remediation in JSON.
4. Add generated completion scripts for zsh, bash, and fish.
5. Install completion files into conventional user completion directories during explicit Collider setup. Do not edit shell startup files.
6. Keep bare `collider` as concise help. Include examples for the primary verb-first flows and point to `collider status`.
7. Add stable human formatting for cache status and prune reports.
8. Add path hyperlinks to failure, log, profile, qualification, installation, and generated-artifact reports.
9. Document the stdout/stderr, JSON, NDJSON, cursor, control, exit-code, and resumption contracts in command help.

### Verification

- Stage logs are directly discoverable without filesystem inspection.
- Run and event commands expose every state used by the headless dashboard model.
- Every failed doctor check provides a valid remediation string.
- Completion scripts load in their target shells.
- Setup installs completions without changing shell configuration files.
- Help examples parse successfully.
- Human and JSON reports describe the same underlying typed records.

## Deferred Work

### Git-relative selection

`--since <git-ref>` remains deferred until Collider has an explicit path-to-task ownership model. Git changes alone do not cover tool identities, environment inputs, untracked files, generated inputs, optional trees, or submodule state. The feature lands only when it can conservatively select every affected task without bypassing non-Git identity changes.

### Per-file tree explanations

Per-file tree deltas remain deferred. Declared-tree fingerprints provide deterministic explanations without creating unbounded state for Chromium, AOSP, React Native, and vendored source trees. A later content-addressed Merkle snapshot design must establish bounded storage, pruning, and measured hashing overhead before adding file counts or file samples.

### Automatic task concurrency

The default remains `--jobs 1` until repository profiles establish resource weights for nested build systems. Changing the default requires measured CPU, memory, I/O, and wall-time evidence across the complete build and test graphs.

### Ordinary command helper binaries

Ordinary operational commands remain in the public `collider` executable. Module separation lands first and produces retained clean-build, incremental-build, link-memory, and installed-size measurements.

A later split requires evidence that the main executable's dependency closure remains a material iteration bottleneck. If justified, the only accepted topology is a thin `exec` dispatcher plus coarse version-matched domain helpers for workspace, toolchain, browser, and Android commands. One binary per subcommand, PATH-based helper lookup, spawn-and-proxy dispatch, partial helper installation, and independently versioned helpers remain prohibited.

### Full-screen TUI

The actual persistent interactive TUI is deferred. Ordinary build verbs continue to use the anchored frame and never enter the alternate screen.

After this plan, TUI implementation is limited to a new presentation target and `collider ui` command that provide:

- Rust client bindings for the completed observer protocol
- Raw terminal mode and guaranteed restoration
- Alternate-screen lifecycle
- Keyboard decoding and focus management
- Resize-aware layout
- Runs, tasks, graph, downloads, artifacts, and log widgets
- Scrolling, selection, filtering, and search interaction
- Key bindings for the existing typed control actions
- Screen-diff rendering and bounded refresh
- In-memory terminal snapshot tests

The Rust TUI launches `collider-observer` and consumes the completed external protocol without decoding private run files or calling Swift through FFI. It does not change the Swift observation APIs, add a daemon, add a second event schema, add a second log format, introduce TUI-only durable state, or add actions without CLI equivalents.

## Cross-Phase Quality Gates

After each phase that changes Swift:

```sh
source tools/host-env.sh
swift build --package-path collider
swift test --package-path collider
```

Run targeted Collider command tests before the complete package test suite. Exercise terminal behavior through bounded test harnesses; do not launch the compositor or begin interactive product sessions.

Every phase must also preserve these properties:

- No vendored React Native source changes.
- No compatibility aliases for replaced Collider commands.
- No source-shape or declaration-presence tests.
- No full build-cache wipe unless source and build causes are ruled out.
- Existing unrelated workspace changes remain untouched.
- Logs and machine reports remain credential-scrubbed.
- Run state remains durable across interruption and process restart.

## Completion Criteria

This plan is complete when:

- All Collider-authored output follows the stdout/stderr contract.
- Default build output is framed and quiet at the leaf level.
- Interactive rendering is capability-aware, bounded, and terminal-safe.
- Failures identify the exact task and command and provide a working resume command.
- Events are typed, versioned, ordered, durable, and independently streamable.
- Run discovery, event replay/follow, and immutable dashboard snapshots are presentation-independent.
- Indexed stage logs support bounded tailing, paging, following, and searching by stable cursor.
- Active runs expose a versioned, permission-restricted control endpoint.
- Active runs support previewed task-branch cancellation that preserves independent work and resumable completed state.
- Every observation and control operation needed by a future TUI has a JSON, NDJSON, or ordinary CLI equivalent.
- The language-neutral protocol schemas and dependency-light `collider-observer` expose the complete headless dashboard contract to a non-Swift client.
- Cache explanations identify changed declared inputs.
- Run summaries expose clean, executed, duration, and concurrency behavior.
- The CLI is verb-first and invalid domains fail during parsing.
- Command-domain modules have narrow recipe dependencies while ordinary operations remain in one public executable.
- Privileged Android operations execute through minimal version-matched private helpers.
- Task IDs and dependencies are discoverable and safely selectable.
- Parallel scheduling respects dependencies, resources, cancellation, logging, and resumption.
- Doctor, runs, events, logs, status, cache, completions, and exit codes provide a coherent operational interface.
- A headless dashboard harness can observe historical and active runs, inspect task state and logs, cancel live work, and resume interrupted work without terminal-specific code.
- Implementing `collider ui` requires only Rust protocol bindings, terminal lifecycle, input handling, layout, widgets, and rendering.
