# Collider Ratatui TUI Plan

## Invariant

`collider-ui` is a Rust/Ratatui presentation client for the completed Collider observation and control protocol. It does not execute task graphs, decode private run-directory files, open active run-control sockets directly, implement resumption semantics, or introduce state that is unavailable through the ordinary Collider CLI.

The Swift `collider-observer` process remains the single external authority for run discovery, snapshot reduction, event following, indexed logs, and live control. The TUI owns only terminal lifecycle, input, transient view state, protocol requests, and rendering.

The ordinary `collider` CLI remains the complete machine and automation interface. `collider ui` is explicitly interactive, requires a controlling TTY, uses the alternate screen, and never activates implicitly for build, test, bootstrap, install, doctor, status, logs, or other commands.

Status: active

## Prerequisite Contract

This plan starts only after `docs/collider-cli-ux-plan.md` is complete.

The completed foundation provides:

- Versioned language-neutral JSON Schemas under `collider/protocol/`
- Golden request, response, notification, snapshot, log, cursor, and error fixtures
- A dependency-light `collider-observer` Swift executable
- Exact protocol negotiation
- Workspace and run snapshots
- Incremental run discovery
- Event subscriptions with sequence cursors
- Indexed log reads, follow, and search with byte cursors
- Graceful and forced run cancellation
- Typed run resumption
- Stable machine-readable CLI equivalents for every observation and action

The TUI does not change those contracts. A missing capability blocks this plan and is fixed in the foundation before TUI code consumes it.

## Final Product Contract

### Invocation

```text
collider ui
collider ui <run-id>
```

`collider ui` uses the current workspace. An optional run ID opens that run directly. The Swift dispatcher resolves the version-matched private `collider-ui` executable from the installed libexec cohort and replaces itself with `exec`.

The dispatcher passes:

- Absolute workspace path
- Absolute `collider-observer` path from the same installed cohort
- Absolute public `collider` path from the same installed cohort
- Optional initial run ID
- Resolved color policy

The Rust binary never resolves an observer from `PATH`.

If stdin or stdout is not a controlling TTY, the command exits with a usage error and names the corresponding noninteractive commands:

```text
collider runs list --format=json
collider runs show <run-id> --format=json
collider events tail <run-id>
collider logs tail <run-id> --task <task-id>
```

### Primary layout

The default wide layout contains:

```text
┌ Nucleus · /workspace ──────────────────────────────────────────────────────┐
│ runs                 │ tasks                         │ details              │
│ ● build all          │ ✓ tracy.build       clean    │ task: core.build     │
│ ✓ test core          │ ✓ vulkan.build      12.4s    │ state: running       │
│ ✗ build browser      │ ● core.build        01:13    │ command: swift build │
│                      │ ◌ linux.build       blocked   │ cwd: /workspace/core │
├──────────────────────┴───────────────────────────────┴──────────────────────┤
│ logs: core.build · follow                                                   │
│ [stdout] Building for debugging...                                          │
│ [stderr] warning: ...                                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ j/k move  enter inspect  / search  f follow  c cancel  r resume  ? help     │
└─────────────────────────────────────────────────────────────────────────────┘
```

The layout collapses deterministically:

- At 120 columns or wider, show runs, tasks, details, and logs.
- From 80 through 119 columns, show runs/tasks plus a tabbed details/log pane.
- From 50 through 79 columns, show one primary pane and a tab bar.
- Below 50 columns, show a compact unsupported-width notice while retaining quit and help input.

### Views

The TUI provides:

1. Runs
    - Current and historical runs
    - Status, canonical command, start time, elapsed time, and task counts
    - Filters for running, failed, interrupted, succeeded, component, and command family
    - Stable text search
2. Tasks
    - Dependency-order, component-grouped, and state-grouped modes
    - State, cache assessment, elapsed duration, progress, and wait reason
    - Active operation and command
    - Dependencies and dependents
3. Logs
    - Bounded initial tail
    - Forward and backward paging
    - Follow mode
    - Literal search with next and previous match
    - Jump to command boundary, first failure, and end
    - stdout/stderr attribution
    - Raw-text and safe-display modes
4. Graph
    - Dependency graph with selected, active, blocked, failed, clean, and completed states
    - Keyboard navigation between adjacent dependencies and dependents
    - A list fallback when the terminal cannot represent the graph legibly
5. Downloads
    - Received and expected bytes
    - Rate and ETA derived from local monotonic samples
    - Digest and destination
6. Artifacts
    - Digest, validation state, publication state, and output path
7. Run comparison
    - Two historical runs
    - Task additions and removals
    - Clean/dirty changes
    - Input-assessment changes
    - Duration deltas
    - Critical-path delta when scheduler data is available
8. Help
    - Context-specific key bindings
    - Exact ordinary CLI equivalent for every action

### Progress rules

The TUI never invents progress:

- Overall run progress is completed tasks over planned tasks and is labeled `tasks`.
- Downloads use received bytes over expected bytes.
- Structured operations use authoritative completed and total units from the protocol.
- Opaque external commands show state, elapsed time, active command, and recent activity without a percentage.
- Historical remaining-time estimates are labeled `estimate` and never replace actual elapsed time.

### Actions

The initial action set is:

- Inspect a run or task
- Follow or search a log
- Copy a run ID, task ID, path, or exact CLI command
- Preview and request graceful cancellation of one task's incomplete dependent branch
- Request forced cancellation of one task branch after a separate confirmation
- Request graceful cancellation of an entire run
- Request forced cancellation of an entire run after a separate confirmation
- Resume a failed or interrupted run
- Open a log in `$PAGER`
- Open a path in `$EDITOR`

Task-cancellation impact, cancellation, and resumption use observer protocol requests. The TUI renders the returned affected-task IDs and does not reproduce graph or scheduler logic.

Mouse input is not required. Every action is reachable by keyboard.

## Rust Workspace

Add one Cargo workspace:

```text
collider/ui/
  Cargo.toml
  Cargo.lock
  rust-toolchain.toml
  crates/
    collider-protocol/
    collider-client/
    collider-ui-model/
    collider-ui/
```

The workspace uses Rust 1.94 with the minimal profile, `rustfmt`, and `clippy`, matching the repository's existing first-party Rust toolchain.

The initial dependency contract is:

- `ratatui` 0.30.2 with the Crossterm backend
- `crossterm` 0.29.0
- `serde` 1.0.229 with derive support
- `serde_json` 1.0
- `signal-hook` 0.4.4

`Cargo.lock` pins the complete transitive graph. Builds use `--locked`. The application has one opinionated backend and no product feature flags.

Do not add Tokio. Terminal input and observer I/O use bounded standard-library channels and dedicated blocking threads, keeping the runtime and shutdown model explicit.

### Crate responsibilities

#### `collider-protocol`

- Rust representations of protocol envelopes and payloads
- Exact protocol-version constant
- Serde encoding and decoding
- Cursor and stable-ID value types
- Golden fixture conformance
- Message-size validation
- No Ratatui or Crossterm dependency

#### `collider-client`

- Spawn and supervise `collider-observer`
- Protocol negotiation
- Request-ID allocation and response correlation
- Notification delivery
- Subscription management
- Bounded request and event queues
- Observer stderr capture
- Clean shutdown and crash classification
- No Ratatui dependency

#### `collider-ui-model`

- Complete transient application model
- Actions
- Effects
- Selection and focus
- Filters and search state
- Pane and tab state
- Log windows and cursors
- Derived display progress
- Pure update function
- No terminal backend dependency

#### `collider-ui`

- Executable entry point
- TTY validation
- Ratatui/Crossterm lifecycle
- Input decoding
- Effect execution
- Layout and widgets
- External pager/editor suspension
- Fatal-error and panic restoration

## Application Architecture

Use a model-update-view architecture:

```text
terminal input ─┐
observer event ─┼─▶ Action ─▶ update(Model, Action) ─▶ Model + Effects
clock tick ─────┘                                      │
                                                       ├─▶ observer request
                                                       ├─▶ clipboard/output
                                                       └─▶ pager/editor

Model ─▶ render(Frame)
```

`update` is pure. It does not perform I/O, read a clock, spawn a process, or access terminal state. Effects contain all external work.

The main thread owns:

- Ratatui terminal
- Application model
- Rendering
- Effect dispatch

One input thread owns all Crossterm event reads. One signal thread owns `signal-hook` delivery. One observer-reader thread owns observer stdout. One observer-writer thread owns observer stdin. Producers send bounded actions to the main thread. No other thread writes to the terminal.

The main loop blocks for actions with a bounded timeout used for elapsed-time refresh. It redraws only when model-visible state changes or the elapsed display crosses its next display boundary. Event bursts are reduced before one render pass.

Observer backpressure rules are:

- Control responses are never dropped.
- Run-state notifications coalesce by run ID and highest sequence.
- Log-append notifications coalesce by task and highest byte cursor.
- Bounded log contents are requested only for the visible task.
- Falling behind causes a fresh snapshot request from the last accepted cursor.

## Terminal Lifecycle

Use Ratatui's Crossterm backend and full-screen viewport.

Terminal setup occurs after:

- Argument validation
- TTY validation
- Observer path validation
- Observer protocol negotiation
- Panic-hook installation

Terminal restoration occurs before:

- Returning success
- Returning an error
- Printing a fatal diagnostic
- Invoking a pager or editor
- Propagating a panic

After a pager or editor exits, re-enter raw mode and the alternate screen, clear Ratatui's previous buffer, and perform a full redraw.

The TUI handles:

- Key press, repeat, and release distinctions
- Resize events
- Focus gained and lost
- Bracketed paste only in search input
- Ctrl-C as a TUI action, not an unhandled process signal
- SIGTERM and SIGHUP as immediate UI shutdown followed by terminal restoration
- Suspend and continue with terminal restoration around suspension

Direct writes to stdout are prohibited after Ratatui initialization. Protocol traffic uses child pipes; diagnostics are retained in the model until after terminal restoration.

## Key Map

Global bindings:

| Key | Action |
| --- | --- |
| `q` | Quit |
| `?` | Context help |
| `tab` / `shift-tab` | Move pane focus |
| `j` / `k` or arrows | Move selection |
| `g` / `G` | First / last item |
| `/` | Search or filter |
| `esc` | Close modal or clear transient mode |
| `1`–`7` | Select primary view |
| `y` | Copy selected stable ID, path, or command |

Run and task bindings:

| Key | Action |
| --- | --- |
| `enter` | Inspect selection |
| `f` | Toggle log follow |
| `d` | Show dependencies |
| `D` | Show dependents |
| `e` | Show cache explanation |
| `c` | Preview and cancel selected task branch |
| `C` | Preview and force-cancel selected task branch |
| `x` | Cancel entire run |
| `X` | Force-cancel entire run |
| `r` | Resume failed or interrupted run |
| `p` | Open selected log in `$PAGER` |
| `o` | Open selected path in `$EDITOR` |

Bindings are centralized in one typed map used by input dispatch and help rendering.

## Phase 1 — Establish the Rust Workspace and Protocol Types

### Implementation

1. Add `collider/ui/` with the declared Cargo workspace and Rust 1.94 toolchain.
2. Set `collider-ui` as the workspace default member.
3. Add the exact direct dependencies and commit the resolved `Cargo.lock`.
4. Add workspace-wide lint policy:
    - Deny warnings
    - Deny unsafe code
    - Deny missing `Debug` on protocol and model types
    - Require Clippy's correctness and suspicious groups
5. Implement `collider-protocol` types for every foundation schema.
6. Centralize the exact protocol-version constant.
7. Reject messages over the foundation's declared size limit before deserialization.
8. Decode every Swift golden fixture.
9. Re-encode canonical Rust fixtures and validate them with the foundation schema validator.
10. Add malformed, unknown-kind, unknown-field, oversized, and version-mismatch fixtures.
11. Keep protocol types free of display strings and Ratatui types.

### Verification

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --locked`
- Every Swift golden fixture decodes in Rust.
- Every Rust fixture validates against the normative schema.
- Unknown fields do not break known messages.
- Unknown kinds and version mismatches return typed protocol errors.
- No crate uses unsafe Rust.

## Phase 2 — Implement the Observer Client

### Implementation

1. Spawn the observer from the absolute dispatcher-provided path.
2. Pass the absolute workspace path explicitly.
3. Pass the absolute version-matched public Collider path explicitly for observer-owned resumption launch.
4. Pipe observer stdin, stdout, and stderr separately.
5. Complete protocol negotiation before exposing a connected client.
6. Allocate monotonically increasing request IDs.
7. Correlate responses exactly once.
8. Deliver notifications in observer order.
9. Implement bounded action and request queues.
10. Implement list, watch, snapshot, subscribe, log, run cancellation, task-cancellation preview, task-branch cancellation, and resumption requests.
11. Preserve event and log cursors across reconnectable subscriptions.
12. Capture a bounded observer stderr tail for diagnostics.
13. Classify clean exit, protocol rejection, malformed output, unexpected EOF, and process failure.
14. On UI shutdown, close observer stdin, drain its final response, and terminate it only if it does not exit cleanly.
15. Add a scripted fake observer for deterministic tests.

### Verification

- Requests remain correctly correlated when responses and notifications interleave.
- Queue bounds cannot deadlock the observer or UI.
- Observer stdout accepts protocol messages only.
- Unexpected observer termination becomes a typed client action.
- Cursor state survives subscription restart.
- Shutdown leaves no observer process.
- Tests cover partial reads and multiple messages in one read.

## Phase 3 — Implement the Pure UI Model

### Implementation

1. Define `Model`, `Action`, and `Effect`.
2. Add run collection, selected run, selected task, and focus state.
3. Add view routing for runs, tasks, logs, graph, downloads, artifacts, comparison, and help.
4. Add immutable snapshot replacement by run ID and sequence.
5. Ignore duplicate or stale notifications by cursor.
6. Detect a cursor gap and emit a snapshot-refresh effect.
7. Add deterministic filtering, grouping, and sorting.
8. Add bounded log-window state and follow mode.
9. Add search query, match locations, and navigation.
10. Add distinct confirmation state for task-branch cancellation, whole-run cancellation, forced variants, and resumption.
11. Add observer-disconnected and protocol-mismatch states.
12. Derive truthful progress displays from typed data.
13. Derive elapsed displays from an injected monotonic tick.
14. Keep all I/O in effects.

### Verification

- Pure update tests cover every action.
- Replaying the same actions produces the same model and effects.
- Duplicate events do not duplicate tasks, logs, or progress.
- Cursor gaps request recovery.
- Selection remains stable across sorting and updates by stable ID.
- Pruned selected runs transition to a defined missing state.
- No model test requires a terminal or observer process.

## Phase 4 — Build the Terminal Shell

### Implementation

1. Validate controlling TTYs before terminal setup.
2. Install crash diagnostics before Ratatui's restoration hook.
3. Initialize the Crossterm full-screen backend.
4. Add RAII terminal restoration for every return path.
5. Start the terminal-input, signal, observer-reader, and observer-writer threads.
6. Implement the bounded main action loop.
7. Coalesce updates before redraw.
8. Handle resize by redrawing from the actual frame area.
9. Add focus, suspension, continuation, SIGTERM, and SIGHUP handling.
10. Render fatal diagnostics only after restoring the terminal.
11. Add a `TestBackend` harness.
12. Add PTY integration harnesses for normal exit, error exit, panic, resize, and suspension.

### Verification

- Normal exit restores canonical input mode, cursor visibility, and the primary screen.
- Error and panic paths restore the same state.
- Resize never panics or indexes outside the frame.
- No background thread writes to the terminal.
- A disconnected observer leaves the UI usable for inspecting retained snapshots and quitting.
- PTY output after exit contains no residual alternate-screen or hidden-cursor state.

## Phase 5 — Implement Runs and Task Overview

### Implementation

1. Implement the responsive root layout.
2. Add workspace header, observer status, active-run count, and selected-run summary.
3. Implement the run list and filters.
4. Implement the task list with dependency, component, and state groupings.
5. Render clean, queued, waiting, running, succeeded, failed, cancelled, and interrupted states.
6. Render wait reasons for dependencies, jobs limits, and resource locks.
7. Render overall task progress and authoritative task progress.
8. Add active command and working-directory detail.
9. Add cache-assessment detail.
10. Add keyboard navigation and stable selection.
11. Add context help generated from the typed key map.

### Verification

- Golden screens cover 50, 80, 120, and 160 columns.
- Running updates do not move selection to a different stable ID.
- Long task IDs and paths truncate predictably.
- Color is never the only state indicator.
- Opaque tasks never display fabricated percentages.
- Empty, idle, loading, disconnected, failed, and pruned states all have explicit screens.

## Phase 6 — Implement Indexed Log Interaction

### Implementation

1. Request only the selected task's bounded log window.
2. Implement forward and backward paging by byte cursor.
3. Implement follow mode from the highest accepted cursor.
4. Pause follow mode when the user scrolls away from the end.
5. Resume follow mode explicitly with `f`.
6. Render stdout, stderr, command boundaries, truncation, and missing attribution.
7. Strip terminal control behavior in safe-display mode while preserving visible text.
8. Provide raw-text mode without executing escape sequences.
9. Implement literal search through observer search requests.
10. Implement next and previous match navigation.
11. Jump to first failure, command boundaries, and end.
12. Preserve per-task log position while switching tasks.
13. Add `$PAGER` suspension and restoration.

### Verification

- Multi-gigabyte synthetic logs remain bounded in UI memory.
- Paging has no duplicate or missing byte ranges.
- Follow mode catches up after coalesced append notifications.
- Invalid UTF-8 is represented without crashing.
- Control sequences never alter the TUI outside Ratatui rendering.
- Search results navigate to the correct byte window.
- Pager exit returns to a complete full redraw.

## Phase 7 — Implement Graph, Downloads, Artifacts, and Comparison

### Implementation

1. Implement the dependency graph view from snapshot edges.
2. Add dependency and dependent navigation.
3. Add the narrow-terminal list fallback.
4. Implement download progress, rate, ETA, digest, and destination.
5. Implement artifact validation, publication, digest, and path views.
6. Add two-run comparison selection.
7. Compare task presence, state, cache assessment, inputs, and duration.
8. Show critical-path differences only when both snapshots provide scheduler data.
9. Add stable sorting and filters in every view.
10. Add `$EDITOR` suspension for selected paths.

### Verification

- Cycles or missing graph nodes become protocol-data errors rather than renderer failures.
- Graph navigation follows declared edges.
- Unknown download totals use an indeterminate display.
- Rate and ETA use monotonic samples and reset after stalled or restarted transfers.
- Comparison distinguishes absent data from zero.
- Editor exit restores the terminal and selected view.

## Phase 8 — Implement Control Actions

### Implementation

1. Add task-cancellation preview from the observer.
2. Render the selected task, every incomplete transitive dependent that will be cancelled, and the count of unaffected active or pending tasks.
3. Add graceful task-branch cancellation confirmation.
4. Add a separate forced task-branch cancellation confirmation requiring the selected task ID suffix.
5. Add graceful whole-run cancellation confirmation.
6. Add a separate forced whole-run cancellation confirmation requiring the run ID suffix.
7. Keep task and run cancellation actions on distinct key bindings and distinct dialogs.
8. Disable task cancellation for clean, succeeded, failed, and already-cancelled tasks.
9. Disable all cancellation actions for terminal runs.
10. Add resumption for failed, interrupted, and cancelled runs only.
11. Show the exact equivalent CLI command before confirmation.
12. Display pending request state and prevent duplicate submission.
13. Apply only observer-confirmed action results.
14. Retain the run view while cancellation or resumption updates arrive.
15. Render `userRequested` and `dependencyCancelled` task reasons distinctly.
16. Continue displaying independent branch progress after task cancellation.
17. Surface typed authorization, stale-run, invalid-state, closure-changed, and process errors.
18. If the closure changes between preview and acceptance, discard the confirmation and display the new preview before allowing another request.
19. Keep quitting the TUI independent from cancelling a task or run.

### Verification

- Closing the TUI never cancels a run.
- One key press cannot submit a destructive action without confirmation.
- A task-cancellation dialog shows the exact affected closure returned by the observer.
- Task cancellation leaves independent branch progress active and visible.
- Forced task cancellation cannot target an unrelated task.
- Duplicate responses do not repeat actions.
- Stale state is refreshed before retry.
- CLI and TUI control paths produce identical typed results.
- Forced task or run cancellation cannot be selected accidentally through a graceful dialog.

## Phase 9 — Integrate Installation and Dispatch

### Implementation

1. Add the Rust UI build to Collider's staged bootstrap after the observer protocol is built and validated.
2. Build with `cargo build --release --locked`.
3. Keep Rust outputs under `collider/ui/target`.
4. Install `collider-ui` and `collider-observer` into the same absolute versioned libexec cohort.
5. Add `collider ui` to the Swift parser and completion metadata.
6. Make `collider ui` resolve the installed cohort and use `exec`.
7. Pass explicit observer, public Collider, and workspace paths.
8. Add developer-checkout resolution for Collider's own staged build outputs.
9. Make `collider doctor` validate:
    - UI executable presence
    - Observer executable presence
    - Executable permissions
    - Exact protocol-version match
    - Rust UI build identity
10. Switch installed cohorts atomically so dispatcher, observer, and UI cannot be partially updated.
11. Add concise help pointing noninteractive users to machine commands.

### Verification

- `collider ui` starts the version-matched private binary.
- `PATH` cannot substitute a different UI or observer.
- Partial or mismatched installation fails before terminal raw mode.
- An atomic cohort switch never exposes mixed versions.
- Shell completions include `ui` and its initial run argument.
- Ordinary Collider commands do not build or launch the TUI at runtime.

## Phase 10 — Harden Performance, Accessibility, and Failure Recovery

### Implementation

1. Profile CPU, memory, redraw count, observer traffic, and log-window retention.
2. Enforce bounded model collections for notifications, diagnostics, searches, and log windows.
3. Add render invalidation so unchanged frames are not drawn.
4. Add configurable color themes selected from a fixed built-in set.
5. Ensure every state has a non-color marker.
6. Add high-contrast theme coverage.
7. Add Unicode, combining-character, wide-character, and ASCII-only fixture coverage.
8. Add malformed-protocol and observer-crash recovery screens.
9. Add crash report output after terminal restoration with observer stderr tail and exact reproduction command.
10. Add key-map conflict validation.
11. Add an end-to-end fake-workspace scenario covering:
    - Idle workspace
    - New run discovery
    - Planning
    - Parallel task execution
    - Download
    - Indexed log follow
    - Failure
    - Cancellation
    - Resumption
    - Completion
    - Pruning
12. Verify that every visible fact and action has a machine-readable CLI equivalent.

### Verification

- Idle UI consumes negligible CPU and performs no continuous redraw.
- Burst traffic remains responsive and bounded.
- A one-hour synthetic run does not grow UI memory without bound.
- Every screen remains understandable without color.
- Unicode input cannot corrupt layout state.
- Protocol corruption cannot leave the terminal in raw mode.
- End-to-end tests never launch the compositor or another interactive product.

## Quality Gates

After every phase:

```sh
cd collider/ui
cargo fmt --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

After phases that change Swift dispatch, setup, doctor, observer fixtures, or installation:

```sh
source tools/host-env.sh
swift build --package-path collider
swift test --package-path collider
```

The complete UI build gate is:

```sh
cd collider/ui
cargo build --release --locked
```

Tests use the observer fake, schema fixtures, Ratatui `TestBackend`, and bounded PTYs. They do not launch the compositor, Android runtime, or another long-lived interactive product.

## Explicit Non-Goals

- Reimplementing the task engine in Rust
- Swift–Rust FFI
- Direct Rust decoding of private `.nucleus` files
- A persistent background daemon
- TUI-only run state or actions
- Automatic TUI activation
- Parsing human Collider output
- Scraping external build logs into fabricated progress
- Mouse-required interaction
- One binary per Collider subcommand
- Runtime-selectable terminal backends
- Product feature flags

## Completion Criteria

This plan is complete when:

- `collider ui` opens the Rust/Ratatui dashboard through the versioned installed cohort.
- The UI negotiates with `collider-observer` before touching terminal state.
- Current and historical runs are discoverable and navigable.
- Task state, dependencies, cache decisions, progress, waits, commands, and durations are visible.
- Ongoing and historical logs support bounded paging, follow, attribution, and search.
- Graph, downloads, artifacts, and run comparison views operate from protocol snapshots.
- Whole-run cancellation, previewed task-branch cancellation, forced variants, and resumption use the same typed behavior as CLI commands.
- Cancelling one task branch keeps independent work visible and running.
- Closing or crashing the UI never stops an active run.
- Terminal state is restored on success, failure, panic, suspension, and observer loss.
- Every screen is usable by keyboard and understandable without color.
- Every visible fact and action has a stable noninteractive equivalent.
- Rust and Swift agree on every protocol fixture and exact protocol version.
- Installation cannot expose mismatched dispatcher, observer, or UI binaries.
- CPU, memory, rendering, and protocol queues remain bounded during long runs.
