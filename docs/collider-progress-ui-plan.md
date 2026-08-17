# Collider progress UI plan

Status: active.

## Invariant

Every `collider` invocation that executes work renders one live progress region
on stderr for as long as that work runs. The region is a rendering of the
recorded run event stream and the frozen execution plan; it is never a second
source of truth. No recipe, action, component command, or workspace helper calls
a progress API, and adding a command or a task grants that work progress
presentation without new instrumentation.

Collider owns the terminal whenever a region is active. Child processes never
write to the terminal directly while a region is live; their complete output
remains in the durable per-run log, and the region reprints attributed lines
above itself. Interactive children take the terminal exclusively and suspend the
region for their lifetime.

Machine output on stdout is unaffected by presentation. Human progress and
diagnostics remain on stderr. One presentation environment is derived once per
invocation from stream attachment, `NO_COLOR`, and the CI environment, and every
renderer consumes the same progress snapshot: an interactive terminal renders
the region, a plain non-terminal stream renders bounded append-only lines
carrying no escape sequence, cursor motion, or carriage return, and a recognized
CI environment additionally renders workflow annotations. A machine progress
stream is newline-delimited JSON on stderr while stdout stays a pure report.

Non-interactive output is bounded and non-repeating. Progress lines are emitted
on state change rather than on repaint, and a liveness line is emitted only when
a run would otherwise be silent past a fixed interval, so an unattended log and
an agent's captured output stay proportional to work performed rather than to
elapsed time. A failing run always ends with its failing task, a bounded tail of
that task's output, and the absolute path to the complete stage log, so the last
lines of captured output are enough to act on a failure without issuing a second
command.

## Current evidence

The presentation surface already exists and is unwired.
`ColliderWorkspaceCommands/CommandConsole.swift` defines `ConsoleProgressPolicy`,
`ConsoleProgressPresentation`, a single-line `progress(_:)` writer, and a
`finishProgress()` that every other write path calls first. Exactly one call site
in the repository drives it, in `RepositoryCache.swift` storage measurement.

The observation model is complete. `ColliderCore/RunRecords.swift` defines task
started, skipped, succeeded, cancelled, and failed events, operation started,
finished, and failed events, download byte counts, lock wait started and
finished events, artifacts, interruption, and terminalization. `RunEventReducer`
already folds that stream into `ReducedRunState` including active waits.
`ColliderPersistence/RunRegistry.swift` is one actor per process, constructed
once in `ColliderCLI/ColliderCommand.swift`, and every event passes through
`record(_:in:)`.

The denominator exists before execution begins. `ExecutionPlan` carries declared
and lowered entries with `isClean`, so the dirty task set is known when planning
completes. `TaskEngine` already measures every task, and those durations are
persisted per task in each run manifest, so a cost-weighted bar needs no new
measurement.

The unattended consumers already have the primitives and no contract binding
them. `ColliderCommand.execute` exports `NUCLEUS_RUN_DIR` and `NUCLEUS_RUN_LOG`
for every recorded run. `ExecutionFailure` carries the failing task, invocation,
status, and stage log path, and `CommandConsole.failure` already renders them.
`CommandConsole` already derives color and progress policy from `NO_COLOR` and
from stdout and stderr terminal attachment independently. `logs tail`,
`logs path`, `runs`, and `status` already read durable records, so observing an
in-flight run from another process needs a snapshot view rather than a new
mechanism. What is missing is any bound on non-interactive volume: a
non-terminal stderr receives the complete mirrored output of every task, which
is the same unbounded transcript whether it lands in a CI log or in an agent's
captured command output.

Child output already flows through Collider. `CommandOutputSink.write(_:mirror:)`
receives every chunk, appends it to the run log, and writes it to a mirror
`FileDescriptor`. Three consequences follow. Mirroring is chunk-granular, so
concurrent tasks in the lightweight and OCI lanes interleave partial lines with
no attribution. Mirrored bytes bypass the `CredentialScrubber` pass that the log
and file writes apply. And terminal ownership is a change at one seam rather
than a subprocess I/O rework. Only `.terminal` commands hold real inherited
descriptors, through `.currentStandardOutput` and `.currentStandardError`.

## Phase 1: Own a terminal region

Replace the single-line progress writer in `CommandConsole` with a renderer that
owns a bounded region of trailing terminal lines. The renderer reserves lines,
repaints in place with cursor movement and line erasure, and never uses the
alternate screen buffer or a full-screen clear, so scrollback is preserved.
Terminal geometry comes from `TIOCGWINSZ` through a new `ColliderPlatformC`
entry point, refreshed on `SIGWINCH`. Every rendered line is truncated to the
current width; wrapped lines break the cursor arithmetic and are never emitted.

A repaint ticker drives the region so elapsed times advance without new events,
and repaints coalesce behind a dirty flag so a chatty event stream cannot thrash
the terminal. `human`, `report`, and `rawReport` become erase, write, repaint,
so ordinary output always lands above a live region instead of terminating it.
Region teardown covers success, failure, `CleanExit`, and interruption through
the existing deferred `finishProgress()` and `RuntimeSignalHandlers`.

Gate: normal exit, error exit, `CleanExit`, SIGINT during a live region, and a
resize during a live region all leave the cursor visible and the terminal clean.
Recorded-writer tests assert that a log line written during an active region
appears above the repainted region, and that narrow widths truncate rather than
wrap.

## Phase 2: Publish run events in process

Add an observation seam to `RunRegistry` so recorded events are published to an
in-process observer as well as appended durably, and so a frozen plan is handed
to observers when `recordPlan` accepts it. The plan is not duplicated into the
event log; the manifest remains its durable home. The composition root in
`ColliderCommand.execute` installs the observer.

Every existing `record(_:in:)` call site now feeds presentation with no new
instrumentation, including the download progress already reported from
`ColliderRuntime`'s download callback and the wait events already recorded
around lock acquisition.

Gate: a test observer installed against a registry receives the frozen plan and
then every recorded event in sequence, and durable event files remain
byte-identical to the same run recorded without an observer.

## Phase 3: Reduce events into a progress snapshot

Extend the existing run event reduction to produce a render-ready snapshot
rather than adding a parallel reducer over the same stream. The snapshot carries
the current phase, completion fraction, completed and total dirty task counts,
elapsed time, and an ordered set of active rows. Each row names its task, lane,
start time, and current detail: the running operation, the awaited lock
resource, or download bytes against expected bytes.

The snapshot type is a pure value, so its transitions are covered by synthetic
event sequences rather than by a live run. Rows are ordered by start time and
bounded, with a residual count for the remainder.

Gate: synthetic sequences covering clean-only plans, mixed clean and dirty
plans, concurrent lanes, lock contention, download progress, task failure,
cancellation, and resumption each produce the expected snapshot, and the
completion fraction never decreases.

## Phase 4: Weight completion by measured cost

Task-count completion misrepresents a plan where one container task dominates
several lightweight tasks. Persist a per-task-identity duration estimate under
the task state root, updated at run finalization from the timings already
carried in `TaskExecutionReport`. Completion becomes finished cost over total
dirty cost. An identity with no recorded history takes a lane-specific default,
and an empty history degrades to count weighting.

The estimate store is task state, not a run record: it is derived, safe to
delete, and rebuilt by ordinary execution.

Gate: deleting the estimate store leaves every command correct and produces
count-weighted completion; a second identical run weights its bar by the first
run's measured costs; and a plan whose costs are dominated by one container task
advances proportionally to that task rather than to task count.

## Phase 5: Route child output through the console

Replace `TaskOutputPresentation` with the presentation set the region requires,
and delete the two-case enum rather than preserving it. The default presentation
sends complete child output to the durable log and shows the most recent line of
each active task inside its region row. Verbose presentation reprints every
child line above the region, prefixed with its task whenever more than one task
is running. Quiet presentation renders the region alone. Raw presentation
suspends the region and yields the terminal to the child, and is what
`.terminal` commands and interactive stdin use.

`CommandOutputSink` stops writing to a mirror descriptor and instead delivers
chunks to a console-owned line assembler, which buffers partial chunks until a
newline so concurrent tasks can no longer interleave fragments. Terminal-bound
bytes pass through the same `CredentialScrubber` path as log and file writes,
closing the asymmetry recorded in the evidence above. Best-effort recognition of
sub-tool progress in a tail line, such as a ninja counter, refines a row detail
and never affects task outcome, ordering, or exit status.

Presentation is independent of the region. Where no region exists, default
presentation still sends complete child output to the durable log and prints no
per-line output, verbose presentation still prints every attributed line, and a
failing task still prints a bounded tail of its output followed by its stage log
path. A non-interactive default therefore produces console output proportional
to failures rather than to total compilation, and a workflow or agent that wants
the complete transcript in its own log requests verbose presentation or reads
the exported run directory.

Gate: a failing parallel build shows every failing task's output attributed to
its task, the durable log for each stage remains complete under all four
presentations, a credential-shaped value emitted by a child is scrubbed on the
terminal as well as in the log, and an interactive child receives an unmodified
terminal. A succeeding build with stderr redirected to a file writes console
output proportional to its task count rather than to its child output, and the
same build with a failing task writes that task's bounded tail and stage log
path.

## Phase 6: Apply presentation by command class

Give the command protocols a presentation kind with defaults by class, so
presentation follows from what a command is rather than from per-command opt-in.
Task-controlled commands render the full region. Inspection commands render
nothing. Long host-side commands that execute no task graph render a phase
region with item counters and no completion fraction.

Wire the reporter into `ColliderCommand.execute` between run admission and
command execution, and make `RunTerminalSummary` the region's final frame rather
than separate trailing output. Derive the presentation environment once at that
point rather than testing stream attachment at each write site. Suppress the
region for dry runs, for JSON reports on stdout, and for a non-terminal stderr,
which instead emits append-only lines. Under an explicit progress policy, emit
newline-delimited JSON progress objects on stderr while stdout remains a pure
report.

Bind the append-only contract here. A line is emitted when the phase, the
completed count, or the set of active tasks changes, never for an unchanged
snapshot, and never more often than a fixed minimum interval. A liveness line
naming the longest-running active task is emitted only after a fixed silent
interval, so a container build that prints nothing for minutes is distinguishable
from a hang without producing periodic noise. Terminal output ordering is fixed
regardless of exit path: the failing task with its bounded tail and stage log
path, then the run summary, then the process exit status.

Gate: adding a command to a command class gives it the class's presentation with
no progress-specific code; JSON reports on stdout are byte-identical with the
region enabled and disabled; a non-terminal stderr contains no escape sequence,
cursor motion, or carriage return; the terminal summary appears once; a run whose
snapshot does not change emits one liveness line per silent interval and nothing
else; and the final lines of captured stderr identify the failing task and its
stage log under failure, cancellation, and interruption alike.

## Phase 7: Report host phases outside the task graph

The silent intervals that remain are host-side work that precedes or surrounds
execution: planning and input hashing, host SwiftPM dependency resolution and
package graph materialization, host Bun installation, Git fetch and checkout,
container image preparation, and storage measurement. Record these as phase
events on the same stream so they render through the same model and renderer,
with item counters where a count exists and an indeterminate phase where none
does.

This makes `doctor`, `bootstrap`, and `cache` present the same interface as
`build` and `test` without a second presentation path, and removes the last
intervals in which Collider appears to have stopped.

Gate: `collider build` on a fully clean tree shows a named phase for every
interval longer than a repaint period, and `doctor`, `bootstrap`, and `cache`
render phase progress through the same renderer with no command-specific
presentation code.

## Phase 8: Render for unattended and supervising consumers

Add the CI renderer as a third consumer of the same snapshot rather than as
conditional formatting inside the append-only renderer. In a recognized GitHub
Actions environment, each executed task's attributed output is wrapped in one
collapsible log group, each failing task emits one annotation carrying its task,
reason, and stage log path, and the run summary is appended as markdown to the
step summary file when that file is present. The plain append-only rendering
remains exactly what an unrecognized non-terminal environment receives, so no
behavior depends on a CI provider being detected.

Collider exposes the run directory it already exports; uploading it as the
diagnostic artifact belongs to the workflow and to the
[GitHub Actions self-hosted CI plan](github-actions-self-hosted-runner-plan.md).
Collider does not learn to upload artifacts.

A supervising process — an agent that started a long build in the background, or
a second terminal — reads the current progress snapshot for an in-flight run
through the existing inspection commands, rendered from the durable event stream
and manifest without disturbing the run or its lease. This is the same snapshot
the region renders, so a poller and a watcher never disagree, and it needs no
daemon, socket, or observer protocol.

Gate: an unrecognized non-terminal environment produces byte-identical output
before and after this phase; a GitHub Actions run collapses per-task output,
annotates every failing task with a resolvable stage log path, and records one
step summary; a snapshot query against a run owned by another process reports
that run's live phase, completion, and active tasks and leaves its lease, event
stream, and manifest unmodified; and a snapshot query against a finished run
reports its terminal state.

## Relationship to the deferred presentation client

Phase 6's machine progress stream is the public streaming output that Phase 2 of
the [Collider Ratatui TUI plan](collider-ratatui-tui-plan.md) consumes. That plan
remains deferred and begins only if the region and inspection commands prove
insufficient in real use. Because every event reaching the region is already
durable, replaying a recorded run through the same renderer, including a run
owned by another process, requires no additional engine surface.

On completion, the terminal ownership, presentation classes, and machine
progress contract move into the CLI and observation contract in
[Collider architecture](collider-architecture.md), and this plan is deleted.
