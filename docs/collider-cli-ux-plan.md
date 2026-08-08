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

Phase 1 is complete. `ColliderCLI` resolves one output policy from every leaf and
injects one console into the workspace context. Command implementations return
typed reports to that console instead of writing process-global output. Machine
reports use stdout; human diagnostics and task summaries use stderr; terminal-owned
children retain their descriptors. The former leaf-specific `--json` flags are
replaced by uniform `--format`, `--color`, and `--progress` options.

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

## Phase 2 — Type execution events and failures

Replace string-only progress messages with an internal `RunEvent` payload for
run, task, operation, download, wait, artifact, interruption, and terminal
result state. Preserve monotonically ordered sequence identity within one run.
Keep compiler output in stage logs and a bounded live-output channel rather than
duplicating it into the event record.

Carry task, operation, command, status/signal, scrubbed invocation, working
directory, and log path in structured execution failures.

Gate: one reducer reconstructs final run/task state from recorded events, and
failure rendering requires no parsing of display strings.

## Phase 3 — Expose graph and record inspection

Implement stable text and JSON reports for task inventory, planned graphs, run
list/show, log list/path/tail, cache status, and the active run summary. Read the
existing task graph, run registry, event record, and stage logs incrementally;
do not add a daemon or external observer protocol.

Gate: commands inspect active and historical runs with bounded memory while a
concurrent build continues writing its records.

## Phase 4 — Normalize command grammar

Use repository-wide verbs for shared operations:

```text
collider doctor [scope]
collider bootstrap [target]
collider build [target]
collider test [target] [--lane lane]
collider check <target>
collider generate <target>
collider install <target>
collider runs <list|show>
collider tasks [filters]
collider graph <operation> [target]
collider logs <list|path|tail>
collider cache <status|prune>
collider run [session options]
collider qualify <target>
```

Keep genuinely domain-specific runtime control beneath its domain. Delete old
aliases and single-child namespaces in the same change as their callers.

Gate: parser enums advertise only valid combinations, usage failures return one
consistent status, and command-equivalence tests cover every replaced spelling.

## Phase 5 — Finish signal handling and summaries

Route graceful and forced whole-run signal handling through the existing runtime
teardown path. Do not add a cross-process control socket, branch cancellation,
or resumability until a real user workflow demonstrates that artifact reuse,
rerunning the command, and ordinary process signals are insufficient.

Render one final summary from actual task outcomes: clean, restored, executed,
failed, cancelled, and elapsed time. Show slow executed tasks without inventing
percent completion for opaque build tools.

Gate: signals, explicit cancellation, child process groups, records, terminal
state, and exit statuses agree for native and container actions.

## Phase 6 — Qualify the noninteractive contract

Run parser, console, reducer, record, log, JSON, signal, and CI-redirection tests
across successful, failed, cancelled, and interrupted operations.

Gate: every supported operation is scriptable without terminal control, every
human failure names its durable log, and no TUI-specific persistence or protocol
surface exists in Collider.
