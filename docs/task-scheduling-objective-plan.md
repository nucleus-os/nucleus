# Task scheduling objective

Status: active

## Invariant

A run reports what it can disprove as early as the graph allows. Scheduling
serves two objectives: total duration for a run that succeeds, and time to
first verdict for one that fails. Neither is served by discarding the other,
and a scheduler that represents only the first reports its cheapest evidence
last.

## Established state

`estimatedCriticalPathPriorities` assigns every task the longest remaining
path through it:

    priorities[task] = duration(task) + max(priorities[successors])

The ready queue is sorted on that value alone, descending, with the task
identifier breaking ties. Estimates come from `TaskDurationEstimateStore`,
which keeps up to eight samples per workload and answers with their median; a
workload with no samples of its own takes the median of its lane, and a lane
with no records at all takes a fixed default.

This is correct for its stated purpose. The
[throughput optimization plan](collider-throughput-optimization-plan.md)
is complete, and nothing below asks for the makespan it established to be
given up.

## The defect

A leaf's priority is its own estimated duration, because it has no successors
to add. Cheap work therefore sorts last precisely because it is cheap, and the
tasks that are cheapest to run are frequently the ones that resolve the most
uncertainty per second.

Protected-main run 34061148632 verified `9858a62c` in 1,025.2 s of execution
across 133 tasks. The two Collider self-tests are the only `hostExclusive`
test work in the graph, they own no downstream tasks, and their
`swift.package.dependencies` prerequisites were all clean at planning time,
so nothing but priority ordered them:

| task | estimate | actual | started |
| --- | --- | --- | --- |
| `swift.package.test…c15ea713` (`collider.test.cli`) | 62.6 s | 134.3 s | +748.8 s |
| `swift.package.test…54dc1ff6` (`collider.test.engine`) | 16.6 s | 80.4 s | +930.5 s |

Both passed. Both were reachable from the first scheduling boundary. The
engine suite -- 276 tests over the package that implements the scheduler
itself -- returned its verdict at 1,011.4 s of a 1,025.2 s run, and it was
broken: it had not compiled for the length of the preceding fourteen
consecutive non-green runs, each of which stopped before reaching it.

Two properties of the estimate compound this.

An estimate that is too low lowers priority, which delays execution. The
engine suite's estimate was the median of its three retained samples,
16.6 s, against an actual 80.4 s. Two of those samples predate the target
compiling at all. A median over eight samples corrects slowly, and it corrects
downward-biased work more slowly than it delays it.

Samples are recorded only by runs that finish. `durationStore.record` is
reached after `runtime.execute` returns, and a failed task propagates out of
the task group instead, so a failing run records nothing -- not even for the
tasks within it that succeeded. Estimates are refreshed only by the runs that
had the least to teach, and stay frozen across exactly the streaks where the
graph is changing most.

## What this plan does not claim

`linux.package-storage-retention` also started at +1,011.7 s, and its lateness
is not a scheduling artifact. It claims exclusive access to both Linux package
roots and to the product store, and it collects what publication leaves
behind, so ordering it after publication is a correctness requirement. Phase 3
addresses the question it answers, not the position it holds.

## Phase 1: Record the ordering the sweep already produces

Status: implemented; gate pending the first sweep that carries it.

Retain each executed task's ready-to-start delay beside its duration in the
run manifest, and report the tasks whose delay exceeded their own duration,
longest delay first. The engine already computed this value per task and
summed it into a run total, which is a number that cannot answer the question
for any single task; keeping it is the whole of the measurement.

The delay is recorded when the task starts rather than when it finishes, so a
run that dies mid-task still carries what it knew about the ordering. Deferral
is not by itself a defect -- a run with more ready work than lanes must defer
something -- so the report names only the tasks whose deferral cost more than
their work did.

Gate: a run report names the tasks whose ready-to-start delay exceeded their
own duration, ordered by that delay. Run 34061148632 predates the measurement
and cannot satisfy this retroactively; the first protected-main sweep carrying
it must name both Collider self-tests.

Behavior tests cover both halves of the distinction the measurement exists to
draw: a task the scheduler deferred records a wait exceeding its own duration,
and a task the graph blocked records a shorter one, because it was not ready
until its dependency finished.

## Phase 2: Give the ready order a second key

Status: pending

Sort the ready queue on longest remaining path as now, and admit work that is
ready, cheap, and terminal ahead of it up to a bounded share of the available
lanes. The bound is what keeps this from becoming a second makespan policy
competing with the first: the reservation may not exceed lanes that would
otherwise sit idle, which run 34061148632 had in quantity -- 1,025.2 s of
execution against a 467.8 s critical path and 7,068.2 s of accumulated
scheduling wait.

Cheapness is read from the estimate the scheduler already computes, and
terminality from the successor map it already builds. No task declares its own
priority: a declaration that names its urgency is a second scheduling policy
maintained by hand, and it would drift from the graph it describes.

Gate: replaying run 34061148632's plan schedules both Collider self-tests
within the first 250 s, and its total execution does not regress beyond
measurement noise. A run whose only failure is a cheap terminal task reports
that failure before it begins any container work.

## Phase 3: Separate the invariant a task checks from the state it changes

Status: pending

Retention answers a question and then acts on it. The question -- whether
every generation the store must serve is one the store can serve -- is
read-only and answerable at any point in the run. The action must follow
publication. Splitting them lets the check run under Phase 2's reservation
while collection stays where correctness requires, which is the same
separation the
[build store retention plan](build-store-retention-plan.md) already made
between collection and deletion in its Phase 5.

Gate: the corruption that failed run 34053908633 -- an active cohort naming
products the store does not hold -- is reported by a task that runs before
any packaging work, and collection still runs after publication.

## Phase 4: Record what a failing run measured

Status: pending

Persist duration samples for the tasks that completed, whether or not the run
did. A task that ran to completion produced a measurement, and discarding it
because a different task failed is what freezes the estimates during the
streaks that most need them current.

Gate: a run whose last task fails records samples for every task that
succeeded before it, and a subsequent run's priorities reflect them.

## Non-goals

- Do not replace longest-remaining-path with a different single objective.
  Failure latency is a second key, not a substitute; a scheduler ordered only
  by cost would defer the work the critical path depends on.
- Do not let a task declare its own priority. Urgency that is written by hand
  is not derived from the graph and will contradict it.
- Do not reorder work whose position is a correctness constraint. Exclusive
  claims, publication order, and declared dependencies bound this plan
  absolutely.

## Risk surface

The load-bearing assumption is that early lanes are genuinely idle rather
than merely appearing so in a warm run. Run 34061148632 was 80 clean and 77
executed; a cold run's early lanes are occupied by the source and toolchain
work everything else waits on, and a reservation that preempts it would cost
makespan for evidence that arrives no sooner. Phase 1 exists to measure this
before Phase 2 changes anything, and the Phase 2 gate is stated against a
replay rather than against a live sweep so a regression is visible before it
is spent.

Phase 4 widens what a failing run writes to durable state. Samples are an
estimate rather than a contract, and no artifact identity or qualification
evidence derives from them, but a run recording state after a failure is
worth naming as a change in what a failure is permitted to do.
