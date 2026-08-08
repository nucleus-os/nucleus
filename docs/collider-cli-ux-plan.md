# Collider CLI and terminal UX plan

Status: active.

## Invariant

Collider has one executable, one command grammar, one structured internal event
model, and one output policy. The task graph remains the source of truth for
selection, dependency order, resource scheduling, artifact reuse, execution,
cancellation, and records. The CLI observes that model; it does not reproduce a
second scheduler, cache, or resumability engine.

Requested machine output goes to stdout. Human progress and diagnostics go to
stderr. Complete task output remains in durable per-run logs. Interactive child
processes retain direct terminal ownership. Same-installation observation data
has no protocol version; an independently deployed observer is not part of this
plan.

Typed planning, resource-aware scheduling, records, cancellation-aware process
teardown, artifact reuse, and cache diagnostics already exist.

Phases 1 through 5 are complete. `ColliderCLI` resolves one output policy from every
leaf and injects one console into the workspace context. Command implementations
return typed reports to that console instead of writing process-global output.
Machine reports use stdout; human diagnostics and task summaries use stderr;
terminal-owned children retain their descriptors. The former leaf-specific
`--json` flags are replaced by uniform `--format`, `--color`, and `--progress`
options. Task and graph inventory, run records, logs, cache state, and active-run
status are read-only inspection commands that do not create run records of their
own.

## Phase 1 — Centralize output policy (complete)

Add one injected console in `ColliderCLI` for human stdout/stderr,
terminal-capability detection, color, append-only CI output, progress rendering,
failure blocks, and safe command/path rendering. Move command-side printing
behind typed report renderers. Preserve direct descriptors for terminal-owned
children.

Support `--format text|json`, `--color auto|always|never`, and `--progress
auto|always|never`. JSON commands emit one value and no human text on stdout.

Gate: descriptor fixtures prove stdout/stderr separation, no cursor control in
redirected output, terminal restoration after signals, and credential scrubbing.

Complete. The console owns terminal capability detection, `NO_COLOR`, dynamic
terminal progress restoration, append-only redirected progress, sorted JSON,
credential scrubbing, and shell-safe command/path rendering. Execution failure
blocks pass through the same console before Collider exits with a bare status.

## Phase 2 — Type execution events and failures (complete)

Replace string-only progress messages with an internal `RunEvent` payload for
run, task, operation, download, wait, artifact, interruption, and terminal
result state. Preserve monotonically ordered sequence identity within one run.
Keep compiler output in stage logs and a bounded live-output channel rather than
duplicating it into the event record.

Carry task, operation, command, status/signal, scrubbed invocation, working
directory, and log path in structured execution failures.

Gate: one reducer reconstructs final run/task state from recorded events, and
failure rendering requires no parsing of display strings.

Complete. `RunEvent` records typed run, task, child-operation, download, lock-wait,
artifact, interruption, and terminal payloads under one monotonically sequenced
stream. The reducer reconstructs terminal run and task state and rejects sequence
gaps or mixed runs. Complete child output remains in the streaming stage-log path;
events contain lifecycle state, never compiler output. `ExecutionFailure` carries
scrubbed task, operation, command, status, signal, invocation, working directory,
and log-path fields, and the console renders those fields directly.

## Phase 3 — Expose graph and record inspection (complete)

Implement stable text and JSON reports for task inventory, planned graphs, run
list/show, log list/path/tail, cache status, and the active run summary. Read the
existing task graph, run registry, event record, and stage logs incrementally;
do not add a daemon or external observer protocol.

Gate: commands inspect active and historical runs with bounded memory while a
concurrent build continues writing its records.

Complete. `tasks` and `graph` render the canonical component catalog and planned
task graph. `runs list/show`, `logs list/path/tail`, `cache status`, and `status`
render canonical run manifests, typed reduced event state, and stage-log
inventory without creating inspection runs. Event reduction streams JSONL with
a per-event memory bound, tolerates an incomplete concurrently written tail, and
never loads compiler logs into structured reports. Log tailing is the explicit
raw-text boundary; JSON mode reports paths and metadata instead of embedding log
contents.

## Phase 4 — Normalize command grammar (complete)

Use repository-wide verbs for shared operations:

```text
collider doctor [scope]
collider bootstrap [target]
collider build [target]
collider test [target]
collider check <target>
collider generate <target>
collider install <target>
collider benchmark
collider clean <target>
collider runs <list|show>
collider tasks [filters]
collider graph <operation> [target]
collider logs <list|path|tail>
collider cache <status|prune>
collider status [repository|swift-sdk]
collider run [session options]
```

Keep genuinely domain-specific runtime control beneath its domain. Delete old
aliases and single-child namespaces in the same change as their callers.

Complete. Shared operations now use only the repository-wide root verbs. Browser
doctor, bootstrap, build, and test operations; Android build, native build, test,
source bootstrap, source-lock check, and image build operations; Swift SDK build
and status operations; sanitizer checks; and Vulkan and Wayland generation all
resolve through that grammar. The former `browser`, `android`, `swift-sdk`, and
`sanitize` command namespaces were deleted rather than retained as aliases. There
is no synthetic qualification command. The Linux-only
`android-runtime package-addon` command remains nested because its signing and
packaging controls are specific to that deployment boundary.

Gate: parser enums advertise only valid combinations, usage failures return one
consistent status, and command-equivalence tests cover every replaced spelling.

## Phase 5 — Finish signal handling and summaries (complete)

Route graceful and forced whole-run signal handling through the existing runtime
teardown path. Do not add a cross-process control socket, branch cancellation,
or resumability until a real user workflow demonstrates that artifact reuse,
rerunning the command, and ordinary process signals are insufficient.

Render one final summary from actual task outcomes: clean, executed, failed,
cancelled, and elapsed time. Show slow tasks without inventing
percent completion for opaque build tools.

Complete. The first interruption forwards its signal to every active native
process group and invokes the existing cancellation registrations used by native
and container actions. A subsequent interruption escalates active native process
groups to `SIGKILL` while invoking the same idempotent cleanup path. Signaled runs
return `128 + signal`, persist the interruption and terminal status, and retain
the failed task only for genuine failures. Cancellation is a distinct task event,
not a synthetic failure.

Executed commands render one terminal summary derived from the finalized run
manifest and reduced event stream. The summary reports clean, executed, failed,
and cancelled task counts, wall-clock duration, planning and execution metrics,
slow tasks, and slow container executions. Dry runs retain their resolved-plan
report and do not emit a second summary. There is no restored-task category
because artifact reuse is represented by a clean task.

Gate: signals, explicit cancellation, child process groups, records, terminal
state, and exit statuses agree for native and container actions.

## Phase 6 — Verify the noninteractive contract

Run parser, console, reducer, record, log, JSON, signal, and CI-redirection tests
across successful, failed, cancelled, and interrupted operations.

Gate: every supported operation is scriptable without terminal control, every
human failure names its durable log, and no TUI-specific persistence or protocol
surface exists in Collider.
