# Collider Ratatui TUI plan

Status: deferred.

## Invariant

The ordinary `collider` CLI remains the complete build, automation, inspection,
and machine-output interface. A future Rust/Ratatui client is presentation only:
it launches a Collider operation or invokes Collider's JSON inspection commands,
reduces the resulting public machine data, and renders terminal UI. It does not
read private task-engine state, execute actions, control locks, schedule tasks,
implement caching, or introduce a daemon and independently versioned protocol.

The TUI is not part of the current execution sequence. It begins only after the
CLI plan is complete and real use demonstrates that the ordinary progress and
inspection commands are insufficient.

## Activation gate

Before implementation, record the concrete workflows that require persistent
interactive presentation and cannot be handled by normal CLI output, JSON
reports, logs, or a terminal multiplexer. Use those workflows to select the
smallest screen and input surface.

Gate: every proposed TUI feature maps to an existing Collider command or to one
new general-purpose CLI machine output that remains independently useful.

## Phase 1 — Establish the presentation client

Add one pinned Rust workspace and one `collider-ui` executable. Resolve the
version-matched binary from Collider's installed cohort and require a controlling
TTY. Centralize terminal entry, restoration, panic handling, resize, color, and
key bindings.

Gate: startup, normal exit, error exit, panic, SIGINT, SIGTERM, suspend/resume,
and resize always restore the terminal.

## Phase 2 — Render launched operations

Launch Collider as a child with its public streaming machine output and preserve
stderr/log paths for diagnostics. Reduce run/task/progress/failure state in the
TUI without interpreting compiler text. Forward graceful and forced termination
to the child process group.

Gate: successful, failed, cancelled, and interrupted native/container runs show
the same final outcomes and logs as the ordinary CLI.

## Phase 3 — Inspect historical state

Use Collider's public JSON commands for run, task, graph, cache, and log
inspection. Page and search logs with bounded memory. Do not decode private
run-directory files or open engine-owned state stores.

Gate: historical screens remain correct after internal record-layout changes as
long as the same installed Collider CLI can read those records.

## Phase 4 — Integrate installation and qualification

Install Collider and `collider-ui` atomically as one version-matched cohort.
Add PTY snapshot, input, terminal-restoration, subprocess, large-log, and
accessibility tests.

This is distribution of the developer tool itself. It does not install the
Nucleus Linux product and is outside the
[Linux package distribution and update plan](linux-package-distribution-and-update-plan.md).

Gate: a partial installation cannot expose mismatched binaries, and removing the
TUI leaves every Collider workflow available through the ordinary CLI.
